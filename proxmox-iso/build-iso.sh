#!/bin/bash
# build-iso.sh — Build a Proxmox VE headless auto-install ISO for any node.
#
# What this does:
#   1. Reads the node-specific answer file (answer-<node>.toml)
#   2. Prompts for root password
#   3. Auto-discovers cluster node IPs via sibling ansible/ inventory
#   4. Generates an ephemeral SSH key pair for automated cluster join
#   5. Pushes the public key to cluster nodes' root authorized_keys
#   6. Substitutes all placeholders into answer.toml + post-install.sh
#   7. Runs proxmox-auto-install-assistant on a cluster node to build the ISO
#   8. Downloads the finished ISO back to this directory
#
# Usage:
#   ./build-iso.sh <node-name> [auto|/path/to/proxmox-ve_9.iso]
#
# Examples:
#   ./build-iso.sh pve2 auto             # build for pve2, let the script pick a base ISO
#   ./build-iso.sh pve2 /tmp/pve9.iso    # build for pve2, upload a local base ISO
#
# Assumes this directory is a sibling of `ansible/` (see the project layout
# in the top-level README). If you're not using the sibling Ansible setup,
# invoke it with BUILD_SSH_USER + CLUSTER_IPS set manually.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
BUILD_DIR="${SCRIPT_DIR}/.build-$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[build-iso] $*"; }
err()  { echo "[build-iso] ERROR: $*" >&2; exit 1; }
warn() { echo "[build-iso] WARNING: $*" >&2; }

cleanup() {
    if [[ -d "${BUILD_DIR}" ]]; then
        log "Cleaning up build dir..."
        rm -rf "${BUILD_DIR}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Arguments + prerequisites
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <node-name> [auto|/path/to/proxmox-ve_9.iso]"
    echo ""
    echo "Available answer files:"
    ls -1 "${SCRIPT_DIR}"/answer-*.toml 2>/dev/null | sed 's|.*/answer-||;s|\.toml||' | sed 's/^/  /'
    exit 1
fi

NODE_NAME="$1"
LOCAL_ISO="${2:-auto}"
ANSWER_FILE="${SCRIPT_DIR}/answer-${NODE_NAME}.toml"

[[ -f "${ANSWER_FILE}" ]] || err "Answer file not found: ${ANSWER_FILE}
Create one first:  cp answer.example.toml answer-${NODE_NAME}.toml"

BUILD_SSH_USER="${BUILD_SSH_USER:-admin}"
OUTPUT_ISO="${SCRIPT_DIR}/proxmox-${NODE_NAME}-autoinstall.iso"

USE_REMOTE_ISO=false
if [[ "${LOCAL_ISO}" == "auto" ]]; then
    USE_REMOTE_ISO=true
    log "Will locate Proxmox ISO on a cluster node automatically."
elif [[ ! -f "${LOCAL_ISO}" ]]; then
    err "ISO file not found: ${LOCAL_ISO}"
fi

for cmd in ssh ssh-keygen ansible python3; do
    command -v "$cmd" &>/dev/null || err "Required command not found: ${cmd}"
done

log "Building auto-install ISO for: ${NODE_NAME}"
log "Answer file: ${ANSWER_FILE}"

# ---------------------------------------------------------------------------
# 2. Root password
# ---------------------------------------------------------------------------
if [[ -z "${PVE_ROOT_PASSWORD:-}" ]]; then
    read -s -p "Enter root password for ${NODE_NAME}: " PVE_ROOT_PASSWORD; echo
    read -s -p "Confirm root password:              " PVE_ROOT_PASSWORD2; echo
    [[ "${PVE_ROOT_PASSWORD}" == "${PVE_ROOT_PASSWORD2}" ]] || err "Passwords don't match."
fi
[[ -n "${PVE_ROOT_PASSWORD}" ]] || err "Root password cannot be empty."

# ---------------------------------------------------------------------------
# 3. Discover cluster node IPs from Ansible inventory
# ---------------------------------------------------------------------------
log "Discovering cluster node IPs from Ansible inventory..."

CLUSTER_NODES=()
CLUSTER_IPS=()

VAULT_ARGS=()
[[ -f "${ANSIBLE_DIR}/vault.pwd" ]] && VAULT_ARGS+=(--vault-password-file "${ANSIBLE_DIR}/vault.pwd")

while IFS= read -r line; do
    host=$(echo "$line" | awk '{print $1}')
    ip=$(echo "$line" | awk '{print $2}')
    if [[ "${host}" != "${NODE_NAME}" && -n "${ip}" ]]; then
        CLUSTER_NODES+=("${host}")
        CLUSTER_IPS+=("${ip}")
        log "  Cluster node: ${host} (${ip})"
    fi
done < <(cd "${ANSIBLE_DIR}" && ansible proxmox_hosts \
    -i inventory.yml \
    "${VAULT_ARGS[@]}" \
    --list-hosts 2>/dev/null \
    | tail -n+2 \
    | while read -r host; do
        host=$(echo "$host" | xargs)
        ip=$(grep -A1 "^        ${host}:" "${ANSIBLE_DIR}/inventory.yml" | grep ansible_host | awk '{print $2}')
        echo "${host} ${ip}"
    done)

if [[ ${#CLUSTER_IPS[@]} -lt 1 ]]; then
    warn "Could not auto-discover cluster nodes."
    read -p "Enter IP of a cluster node to join: " MANUAL_IP
    CLUSTER_NODES+=("manual")
    CLUSTER_IPS+=("${MANUAL_IP}")
fi

CLUSTER_NODE1_IP="${CLUSTER_IPS[0]}"
CLUSTER_NODE2_IP="${CLUSTER_IPS[1]:-${CLUSTER_IPS[0]}}"
CLUSTER_NODE1_NAME="${CLUSTER_NODES[0]}"

log "  Primary join target:  ${CLUSTER_NODE1_NAME} (${CLUSTER_NODE1_IP})"
log "  Fallback join target: ${CLUSTER_NODE2_IP}"

BUILD_HOST=""
BUILD_HOST_IP=""
for i in "${!CLUSTER_IPS[@]}"; do
    if ping -c1 -W2 "${CLUSTER_IPS[$i]}" &>/dev/null; then
        BUILD_HOST="${CLUSTER_NODES[$i]}"
        BUILD_HOST_IP="${CLUSTER_IPS[$i]}"
        break
    fi
done
[[ -n "${BUILD_HOST}" ]] || err "No cluster nodes reachable. Cannot build ISO."
log "  ISO will be built on: ${BUILD_HOST} (${BUILD_HOST_IP})"

# ---------------------------------------------------------------------------
# 4. Generate ephemeral SSH key pair for cluster join
# ---------------------------------------------------------------------------
log "Generating ephemeral SSH key pair..."
mkdir -p "${BUILD_DIR}"
EPHEMERAL_KEY="${BUILD_DIR}/${NODE_NAME}_cluster_join"
ssh-keygen -t ed25519 -N "" -C "${NODE_NAME}-cluster-join-temp-$(date +%Y%m%d)" \
    -f "${EPHEMERAL_KEY}" -q
EPHEMERAL_PUBKEY="$(cat "${EPHEMERAL_KEY}.pub")"
log "  Ephemeral key generated."

# ---------------------------------------------------------------------------
# 5. Push ephemeral pubkey to cluster nodes' root account
# ---------------------------------------------------------------------------
KEY_TAG="${NODE_NAME}-cluster-join-temp"

add_key_to_host() {
    local host_ip="$1"
    local host_name="$2"
    log "  Configuring root SSH on ${host_name} (${host_ip})..."

    ssh "${BUILD_SSH_USER}@${host_ip}" "sudo bash -s" << ENDSSH
set -euo pipefail
for path in /root/.ssh /root/.ssh/authorized_keys; do
    [ -e "\$path" ] || continue
    if lsattr "\$path" 2>/dev/null | awk '{print \$1}' | grep -q 'i'; then
        chattr -i "\$path"
    fi
done
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
sed -i '/${KEY_TAG}/d' /root/.ssh/authorized_keys
printf '%s\n' '${EPHEMERAL_PUBKEY}' >> /root/.ssh/authorized_keys
for conf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "\$conf" ] || continue
    if grep -q 'PermitRootLogin' "\$conf"; then
        sed -i 's/PermitRootLogin no/PermitRootLogin prohibit-password/g' "\$conf"
    fi
done
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
ENDSSH
}

log "Preparing cluster nodes for ephemeral SSH..."
for i in "${!CLUSTER_IPS[@]}"; do
    add_key_to_host "${CLUSTER_IPS[$i]}" "${CLUSTER_NODES[$i]}" \
        || err "Failed to prepare ${CLUSTER_NODES[$i]} — cannot continue."
    log "  ${CLUSTER_NODES[$i]} ready."
done

# ---------------------------------------------------------------------------
# 6. Substitute placeholders
# ---------------------------------------------------------------------------
log "Preparing answer.toml and post-install.sh..."

ADMIN_PUBKEY_FILE="${ANSIBLE_DIR}/ssh-keys/admin.pub"
[[ -f "${ADMIN_PUBKEY_FILE}" ]] || err "Admin public key not found at ${ADMIN_PUBKEY_FILE}
Drop it in ansible/ssh-keys/admin.pub first."
ADMIN_PUBKEY="$(cat "${ADMIN_PUBKEY_FILE}")"

# Optional: extract DNS TSIG key from vault for nsupdate.
# Variable name in vault: vault_bind_update_tsig_secret (leave unset to skip).
TSIG_UPDATE_KEY=""
if [[ -f "${ANSIBLE_DIR}/vault.pwd" ]]; then
    TSIG_UPDATE_KEY=$(cd "${ANSIBLE_DIR}" && ansible localhost \
        -i inventory.yml \
        --vault-password-file vault.pwd \
        -m debug \
        -a "msg={{ vault_bind_update_tsig_secret | default('') }}" \
        2>/dev/null | grep -oP 'msg": "\K[^"]+' || true)
    [[ -z "${TSIG_UPDATE_KEY}" ]] && warn "No TSIG key in vault — DNS registration will be skipped on first boot."
fi

DNS_ZONE="${DNS_ZONE:-example.lan}"
DNS_SERVER="${DNS_SERVER:-192.168.1.1}"

export PVE_ROOT_PASSWORD CLUSTER_NODE1_IP CLUSTER_NODE2_IP NODE_NAME KEY_TAG
export EPHEMERAL_KEY ADMIN_PUBKEY TSIG_UPDATE_KEY DNS_ZONE DNS_SERVER
export BUILD_DIR SCRIPT_DIR ANSWER_FILE

python3 - << 'PYEOF'
import os

root_password    = os.environ['PVE_ROOT_PASSWORD']
node1_ip         = os.environ['CLUSTER_NODE1_IP']
node2_ip         = os.environ['CLUSTER_NODE2_IP']
node_name        = os.environ['NODE_NAME']
key_tag          = os.environ['KEY_TAG']
privkey          = open(os.environ['EPHEMERAL_KEY']).read().rstrip()
admin_pubkey     = os.environ['ADMIN_PUBKEY']
tsig_key         = os.environ.get('TSIG_UPDATE_KEY', '')
dns_zone         = os.environ.get('DNS_ZONE', 'example.lan')
dns_server       = os.environ.get('DNS_SERVER', '192.168.1.1')
build_dir        = os.environ['BUILD_DIR']
script_dir       = os.environ['SCRIPT_DIR']
answer_file      = os.environ['ANSWER_FILE']

with open(answer_file) as f:
    content = f.read()
content = content.replace('__ROOT_PASSWORD__', root_password)
with open(os.path.join(build_dir, 'answer.toml'), 'w') as f:
    f.write(content)

with open(os.path.join(script_dir, 'post-install.sh')) as f:
    content = f.read()
content = content.replace('__NODE_NAME__',              node_name)
content = content.replace('__KEY_TAG__',                key_tag)
content = content.replace('__CLUSTER_NODE1_IP__',       node1_ip)
content = content.replace('__CLUSTER_NODE2_IP__',       node2_ip)
content = content.replace('__EPHEMERAL_PRIVATE_KEY__',  privkey)
content = content.replace('__ADMIN_PUBKEY__',           admin_pubkey)
content = content.replace('__TSIG_UPDATE_KEY__',        tsig_key)
content = content.replace('__DNS_ZONE__',               dns_zone)
content = content.replace('__DNS_SERVER__',             dns_server)
with open(os.path.join(build_dir, 'post-install.sh'), 'w') as f:
    f.write(content)
os.chmod(os.path.join(build_dir, 'post-install.sh'), 0o755)

print("  answer.toml and post-install.sh prepared.")
PYEOF

# ---------------------------------------------------------------------------
# 7. Ensure proxmox-auto-install-assistant is available on build host
# ---------------------------------------------------------------------------
log "Ensuring proxmox-auto-install-assistant is installed on ${BUILD_HOST}..."
ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" \
    "sudo apt-get install -y proxmox-auto-install-assistant -qq 2>/dev/null" \
    || err "Could not install proxmox-auto-install-assistant on ${BUILD_HOST}."

# ---------------------------------------------------------------------------
# 8. Build the ISO on the cluster node
# ---------------------------------------------------------------------------
REMOTE_WORK="/tmp/${NODE_NAME}-iso-build-$$"
PVE_ISO_BASE_URL="http://download.proxmox.com/iso"

if [[ "${USE_REMOTE_ISO}" == "true" ]]; then
    log "Fetching available Proxmox VE ISOs..."
    AVAILABLE_ISOS=$(wget -qO- "${PVE_ISO_BASE_URL}/" \
        | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' \
        | sort -Vu | tail -3)
    [[ -n "${AVAILABLE_ISOS}" ]] || err "Could not fetch ISO list from Proxmox mirror."

    echo ""
    echo "Available Proxmox VE versions:"
    i=1
    declare -a ISO_CHOICES=()
    while IFS= read -r iso; do
        ISO_CHOICES+=("${iso}")
        if [[ $i -eq $(echo "${AVAILABLE_ISOS}" | wc -l) ]]; then
            echo "  ${i}) ${iso}  (latest)"
        else
            echo "  ${i}) ${iso}"
        fi
        ((i++))
    done <<< "${AVAILABLE_ISOS}"

    LATEST_IDX=${#ISO_CHOICES[@]}
    read -p "Select version [${LATEST_IDX}]: " CHOICE
    CHOICE="${CHOICE:-${LATEST_IDX}}"

    if [[ "${CHOICE}" -lt 1 || "${CHOICE}" -gt ${#ISO_CHOICES[@]} ]] 2>/dev/null; then
        err "Invalid selection: ${CHOICE}"
    fi
    SELECTED_ISO="${ISO_CHOICES[$((CHOICE-1))]}"
    log "Selected: ${SELECTED_ISO}"
else
    SELECTED_ISO=$(basename "${LOCAL_ISO}")
    log "Using local ISO: ${SELECTED_ISO}"
fi

log "Fetching SHA256 checksums..."
SHA256SUMS=$(wget -qO- "${PVE_ISO_BASE_URL}/SHA256SUMS" 2>/dev/null || true)
EXPECTED_SHA=$(echo "${SHA256SUMS}" | grep "${SELECTED_ISO}" | awk '{print $1}')
[[ -n "${EXPECTED_SHA}" ]] && log "  Expected SHA256: ${EXPECTED_SHA:0:16}..." \
    || warn "No checksum found for ${SELECTED_ISO}"

ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" "sudo mkdir -p /var/lib/vz/template/iso && mkdir -p ${REMOTE_WORK}"

if [[ "${USE_REMOTE_ISO}" == "false" ]]; then
    if [[ -n "${EXPECTED_SHA}" ]]; then
        log "Validating local ISO..."
        ACTUAL_SHA=$(sha256sum "${LOCAL_ISO}" | awk '{print $1}')
        [[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] || err "Local ISO checksum mismatch!"
    fi
    log "Uploading ISO to ${BUILD_HOST}..."
    scp "${LOCAL_ISO}" "${BUILD_SSH_USER}@${BUILD_HOST_IP}:/var/lib/vz/template/iso/"
fi

ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" \
    "command -v pv >/dev/null 2>&1 || sudo apt-get install -y -qq pv 2>/dev/null" || true

log "Ensuring valid ISO on ${BUILD_HOST}..."
REMOTE_INPUT_ISO=$(ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" "sudo bash -s" \
    "${SELECTED_ISO}" "${EXPECTED_SHA}" "${PVE_ISO_BASE_URL}" << 'REMOTE_EOF'
set -euo pipefail
SELECTED_ISO="$1"
EXPECTED_SHA="$2"
BASE_URL="$3"
ISO_DIR="/var/lib/vz/template/iso"
ISO_PATH="${ISO_DIR}/${SELECTED_ISO}"

verify_iso() {
    local file="$1"
    [[ -z "${EXPECTED_SHA}" ]] && { rm -f "$file"; return 1; }
    local actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "${actual}" == "${EXPECTED_SHA}" ]] && return 0 || return 1
}

if [[ -f "${ISO_PATH}" ]] && verify_iso "${ISO_PATH}"; then
    echo "${ISO_PATH}"
    exit 0
fi

for old in "${ISO_DIR}"/proxmox-ve_*.iso; do
    [[ -f "$old" ]] || continue
    [[ "$old" == "${ISO_PATH}" ]] && continue
    rm -f "$old"
done

if command -v pv >/dev/null 2>&1; then
    wget -qO- "${BASE_URL}/${SELECTED_ISO}" | pv -petrab > "${ISO_PATH}"
else
    wget -q --show-progress -O "${ISO_PATH}" "${BASE_URL}/${SELECTED_ISO}"
fi

verify_iso "${ISO_PATH}" || { echo "download failed" >&2; exit 1; }
echo "${ISO_PATH}"
REMOTE_EOF
)
[[ -n "${REMOTE_INPUT_ISO}" ]] || err "Failed to obtain valid ISO on ${BUILD_HOST}."
log "  ISO ready: ${REMOTE_INPUT_ISO}"

log "Uploading build files to ${BUILD_HOST}..."
scp "${BUILD_DIR}/answer.toml" "${BUILD_DIR}/post-install.sh" \
    "${BUILD_SSH_USER}@${BUILD_HOST_IP}:${REMOTE_WORK}/"

log "Building auto-install ISO on ${BUILD_HOST}..."
REMOTE_OUTPUT_ISO="${REMOTE_WORK}/${NODE_NAME}-autoinstall.iso"
ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" "
    sudo proxmox-auto-install-assistant prepare-iso '${REMOTE_INPUT_ISO}' \
        --fetch-from iso \
        --answer-file '${REMOTE_WORK}/answer.toml' \
        --on-first-boot '${REMOTE_WORK}/post-install.sh' \
        --output '${REMOTE_OUTPUT_ISO}'
"

# ---------------------------------------------------------------------------
# 9. Download the finished ISO
# ---------------------------------------------------------------------------
log "Downloading ISO..."
scp "${BUILD_SSH_USER}@${BUILD_HOST_IP}:${REMOTE_OUTPUT_ISO}" "${OUTPUT_ISO}"

ssh "${BUILD_SSH_USER}@${BUILD_HOST_IP}" "rm -rf ${REMOTE_WORK}" || true

echo ""
echo "============================================================"
echo "  ISO ready: ${OUTPUT_ISO}"
echo "============================================================"
echo ""
echo "Flash to USB and boot ${NODE_NAME}. Install is fully automatic"
echo "(~5-10 min). ${NODE_NAME} will join the cluster on first boot."
echo ""
echo "After install:"
echo "  1. Confirm ${NODE_NAME}'s IP in your DHCP server"
echo "  2. Run Ansible:"
echo "     cd ${ANSIBLE_DIR}"
echo "     ansible-playbook playbook.yml --limit ${NODE_NAME}"
echo ""
