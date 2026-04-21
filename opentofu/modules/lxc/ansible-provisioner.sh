#!/bin/bash
# ansible-provisioner.sh — called by the LXC module after the container is
# reachable. Differs from the VM provisioner: LXCs self-register DNS via
# BIND9 (set up in the Ansible playbook), so after Ansible runs we *restore*
# the original inventory — the IP injection was only for the initial
# provisioning handoff.
#
# Usage: ansible-provisioner.sh <lxc-name> <ip> <playbook> [group1] [group2] ...

set -e

LXC_NAME="$1"
LXC_IP="$2"
ANSIBLE_PLAYBOOK="$3"
shift 3
ANSIBLE_GROUPS=("$@")

echo "=================================================="
echo "Provisioning ${LXC_NAME} with Ansible"
echo "  IP:     ${LXC_IP}"
echo "  Groups: ${ANSIBLE_GROUPS[*]}"
echo "=================================================="

ANSIBLE_DIR="$(cd "$(dirname "${ANSIBLE_PLAYBOOK}")/.." && pwd)"
PLAYBOOK_NAME="$(basename "${ANSIBLE_PLAYBOOK}")"

cd "${ANSIBLE_DIR}"

cp inventory.yml inventory.yml.backup

if grep -q "^        ${LXC_NAME}:" inventory.yml; then
    echo "Updating inventory: ${LXC_NAME}.ansible_host -> ${LXC_IP}"
    sed -i.tmp "/^        ${LXC_NAME}:/,/^        [a-z-]/ s|ansible_host:.*|ansible_host: ${LXC_IP}|" inventory.yml
    rm -f inventory.yml.tmp
else
    echo "Adding ${LXC_NAME} to inventory groups: ${ANSIBLE_GROUPS[*]}"
    for GROUP in "${ANSIBLE_GROUPS[@]}"; do
        if grep -q "^    ${GROUP}:" inventory.yml; then
            awk -v group="${GROUP}" -v host="${LXC_NAME}" -v ip="${LXC_IP}" '
                /^    '"${GROUP}"':/ { in_group=1 }
                in_group && /^      hosts:/ {
                    print
                    print "        " host ":"
                    print "          ansible_host: " ip
                    in_group=0
                    next
                }
                { print }
            ' inventory.yml > inventory.yml.new
            mv inventory.yml.new inventory.yml
        else
            echo "  WARNING: group ${GROUP} not found in inventory"
        fi
    done
fi

echo ""
echo "Running: ansible-playbook playbook.yml --limit ${LXC_NAME}"
if ansible-playbook "playbook.yml" --inventory inventory.yml --limit "${LXC_NAME}" 2>/dev/null \
        || ansible-playbook "playbooks/${PLAYBOOK_NAME}" --inventory inventory.yml --limit "${LXC_NAME}"; then

    echo ""
    echo "Ansible finished. Restoring original inventory."
    echo "(LXCs self-register DNS during the playbook run, so the hostname"
    echo " resolves without a static inventory entry.)"
    mv inventory.yml.backup inventory.yml

    echo "=================================================="
    echo "  ${LXC_NAME}: provisioning complete"
    echo "=================================================="
else
    echo ""
    echo "ERROR: Ansible failed. Restoring inventory backup."
    mv inventory.yml.backup inventory.yml
    exit 1
fi
