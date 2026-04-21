#!/bin/bash
# ansible-provisioner.sh — called by the VM module after the VM is reachable.
#
# Workflow:
#   1. Back up inventory.yml
#   2. Edit inventory.yml so ansible_host = <IP> (so Ansible can connect)
#   3. Run ansible-playbook --limit <vm-name>
#   4. On success: flip inventory back to ansible_host = <hostname>
#                  (relies on DNS or /etc/hosts resolving hostname → IP)
#   5. On failure: restore the backup and exit non-zero
#
# Usage: ansible-provisioner.sh <vm-name> <ip> <playbook> [group1] [group2] ...

set -e

VM_NAME="$1"
VM_IP="$2"
ANSIBLE_PLAYBOOK="$3"
shift 3
ANSIBLE_GROUPS=("$@")

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "=================================================="
echo "Provisioning ${VM_NAME} with Ansible"
echo "  IP:     ${VM_IP}"
echo "  Groups: ${ANSIBLE_GROUPS[*]}"
echo "=================================================="

# Resolve ansible/ directory — provisioner runs from whatever cwd Terraform
# invokes it with, so anchor on the playbook path we were handed.
ANSIBLE_DIR="$(cd "$(dirname "${ANSIBLE_PLAYBOOK}")/.." && pwd)"
PLAYBOOK_NAME="$(basename "${ANSIBLE_PLAYBOOK}")"

cd "${ANSIBLE_DIR}"

echo "Backing up inventory..."
cp inventory.yml inventory.yml.backup

# Update or insert the host, with ansible_host set to the IP.
if grep -q "^        ${VM_NAME}:" inventory.yml; then
    echo "Updating inventory: ${VM_NAME}.ansible_host -> ${VM_IP}"
    sed -i.tmp "/^        ${VM_NAME}:/,/^        [a-z-]/ s|ansible_host:.*|ansible_host: ${VM_IP}|" inventory.yml
    rm -f inventory.yml.tmp
else
    echo "Adding ${VM_NAME} to inventory groups: ${ANSIBLE_GROUPS[*]}"
    for GROUP in "${ANSIBLE_GROUPS[@]}"; do
        if grep -q "^    ${GROUP}:" inventory.yml; then
            awk -v group="${GROUP}" -v host="${VM_NAME}" -v ip="${VM_IP}" '
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
echo "Running Ansible playbook: playbooks/${PLAYBOOK_NAME} --limit ${VM_NAME}"
if ansible-playbook "playbooks/${PLAYBOOK_NAME}" --inventory inventory.yml --limit "${VM_NAME}"; then

    echo ""
    echo "Ansible finished. Switching inventory back to hostname."
    sed -i.tmp "/^        ${VM_NAME}:/,/^        [a-z-]/ s|ansible_host:.*|ansible_host: ${VM_NAME}|" inventory.yml
    rm -f inventory.yml.tmp inventory.yml.backup

    echo "=================================================="
    echo "  ${VM_NAME}: provisioning complete"
    echo "=================================================="
else
    echo ""
    echo "ERROR: Ansible failed. Restoring inventory backup."
    mv inventory.yml.backup inventory.yml
    exit 1
fi
