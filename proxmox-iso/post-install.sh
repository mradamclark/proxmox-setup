#!/bin/bash
# Post-install script — runs on first boot after Proxmox installation.
# Placeholders (__NAME__) are substituted by build-iso.sh before being
# embedded in the ISO. This script runs as root on the freshly installed
# Proxmox node, once, via the `[first-boot]` section of answer.toml.
#
# Actions:
#   1. Disable wifi (prevent dual-homing surprises)
#   2. Wait for the network
#   3. Register the node in DNS (optional; skipped if no TSIG key was set)
#   4. Set up the ephemeral SSH key that build-iso.sh pushed to peers
#   5. Join the existing Proxmox cluster via `pvecm add`
#   6. Bootstrap the `admin` user so Ansible can connect as a non-root user
#   7. Clean up the ephemeral key on peer nodes

set -euo pipefail

NODE_NAME="__NODE_NAME__"
KEY_TAG="__KEY_TAG__"

LOG=/var/log/pve-post-install.log
exec > >(tee -a "$LOG") 2>&1
echo "=== ${NODE_NAME} post-install started at $(date) ==="

CLUSTER_NODE1_IP="__CLUSTER_NODE1_IP__"
CLUSTER_NODE2_IP="__CLUSTER_NODE2_IP__"

# First non-loopback IPv4 address.
MY_LAN_IP=$(hostname -I | awk '{print $1}')
echo "Detected LAN IP: ${MY_LAN_IP}"

# ---------------------------------------------------------------------------
# 1. Disable wifi interfaces (no-op on servers without wifi)
# ---------------------------------------------------------------------------
echo "Disabling wifi interfaces..."
for wlan in $(ls /sys/class/net/ | grep -E '^wl' || true); do
    ip link set "$wlan" down 2>/dev/null && echo "  Disabled $wlan" || true
done
if ls /sys/class/net/ 2>/dev/null | grep -qE '^wl'; then
    echo "blacklist iwlwifi" >  /etc/modprobe.d/disable-wifi.conf
    echo "blacklist iwlmvm"  >> /etc/modprobe.d/disable-wifi.conf
fi

# ---------------------------------------------------------------------------
# 2. Wait for network
# ---------------------------------------------------------------------------
echo "Waiting for network..."
for i in $(seq 1 60); do
    if ping -c1 -W2 "${CLUSTER_NODE1_IP}" &>/dev/null || ping -c1 -W2 "${CLUSTER_NODE2_IP}" &>/dev/null; then
        echo "Network up (${i}s)"
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 3. Register in DNS (optional — skipped if no TSIG key)
# ---------------------------------------------------------------------------
DNS_SERVER="__DNS_SERVER__"
DNS_ZONE="__DNS_ZONE__"
TSIG_KEY="__TSIG_UPDATE_KEY__"

if [[ -n "${TSIG_KEY}" ]]; then
    echo "Registering ${NODE_NAME}.${DNS_ZONE} -> ${MY_LAN_IP}..."
    if command -v nsupdate &>/dev/null || apt-get install -y -qq dnsutils; then
        nsupdate -y "hmac-sha256:dns-update-key:${TSIG_KEY}" <<DNSEOF || echo "  WARNING: DNS registration failed (non-fatal)"
server ${DNS_SERVER}
zone ${DNS_ZONE}
update delete ${NODE_NAME}.${DNS_ZONE}. A
update add ${NODE_NAME}.${DNS_ZONE}. 300 A ${MY_LAN_IP}
send
DNSEOF
        echo "  Registered ${NODE_NAME}.${DNS_ZONE}"
    fi
else
    echo "No TSIG key configured, skipping DNS registration."
fi

# ---------------------------------------------------------------------------
# 4. Write the ephemeral SSH key for cluster join
# ---------------------------------------------------------------------------
echo "Setting up cluster join SSH key..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

cat > /root/.ssh/cluster_join_key << 'EOF_JOIN_KEY'
__EPHEMERAL_PRIVATE_KEY__
EOF_JOIN_KEY
chmod 600 /root/.ssh/cluster_join_key

ssh-keyscan -H "${CLUSTER_NODE1_IP}" "${CLUSTER_NODE2_IP}" >> /root/.ssh/known_hosts 2>/dev/null

cat >> /root/.ssh/config << EOF_SSHCFG
Host ${CLUSTER_NODE1_IP} ${CLUSTER_NODE2_IP}
    IdentityFile /root/.ssh/cluster_join_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF_SSHCFG
chmod 600 /root/.ssh/config

# ---------------------------------------------------------------------------
# 5. Pick a reachable peer and join the cluster
# ---------------------------------------------------------------------------
JOIN_HOST=""
for candidate in "${CLUSTER_NODE1_IP}" "${CLUSTER_NODE2_IP}"; do
    echo "Testing SSH to ${candidate}..."
    if ssh -o ConnectTimeout=10 root@"${candidate}" "echo 'SSH OK'" 2>/dev/null; then
        JOIN_HOST="${candidate}"
        break
    fi
done
[[ -n "${JOIN_HOST}" ]] || { echo "ERROR: no cluster node reachable"; exit 1; }

echo "Waiting for pve-cluster service..."
for i in $(seq 1 30); do
    systemctl is-active --quiet pve-cluster && break
    sleep 2
done

echo "Joining cluster via ${JOIN_HOST}..."
pvecm add "${JOIN_HOST}" --use_ssh --link0 "address=${MY_LAN_IP}"
pvecm status || true

# ---------------------------------------------------------------------------
# 6. Bootstrap `admin` user (for Ansible to use as ansible_user)
# ---------------------------------------------------------------------------
echo "Bootstrapping admin user..."
ADMIN_PUBKEY="__ADMIN_PUBKEY__"

command -v sudo &>/dev/null || apt-get install -y -qq sudo
id admin &>/dev/null || useradd -m -s /bin/bash admin
usermod -aG sudo admin

mkdir -p /home/admin/.ssh
chmod 700 /home/admin/.ssh
echo "${ADMIN_PUBKEY}" > /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh

echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 440 /etc/sudoers.d/admin

# ---------------------------------------------------------------------------
# 7. Clean up ephemeral key on peers
# ---------------------------------------------------------------------------
cleanup_node() {
    local host="$1"
    ssh -o ConnectTimeout=5 root@"${host}" "bash -s" << 'NODE_CLEANUP' 2>/dev/null || true
set -euo pipefail
chattr -i /root/.ssh/authorized_keys 2>/dev/null || true
sed -i '/__KEY_TAG__/d' /root/.ssh/authorized_keys
chattr +i /root/.ssh/authorized_keys 2>/dev/null || true
for conf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$conf" ] || continue
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/g' "$conf" 2>/dev/null || true
done
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
NODE_CLEANUP
}

cleanup_node "${CLUSTER_NODE1_IP}"
cleanup_node "${CLUSTER_NODE2_IP}"

rm -f /root/.ssh/cluster_join_key
sed -i "/^Host ${CLUSTER_NODE1_IP}/,/^$/d" /root/.ssh/config

echo ""
echo "=== ${NODE_NAME} post-install complete at $(date) ==="
echo ""
echo "Next: finish configuration with Ansible:"
echo "  ansible-playbook playbooks/proxmox.yml --limit ${NODE_NAME}"
