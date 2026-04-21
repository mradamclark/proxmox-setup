#!/bin/bash
# wait-for-vm.sh — wait for a new VM to be SSH-reachable and for cloud-init
# to finish. Invoked by the VM module's local-exec provisioner after the
# QEMU guest agent has reported an IP.

set -e

VM_NAME="$1"
VM_IP="$2"
CLOUD_INIT_USER="${3:-ubuntu}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "=================================================="
echo "Waiting for VM to be ready: ${VM_NAME} (${VM_IP})"
echo "=================================================="

[ -n "$VM_IP" ] && [ "$VM_IP" != "null" ] || {
    echo "ERROR: no IP provided for ${VM_NAME}"
    exit 1
}

echo "Waiting for SSH on ${CLOUD_INIT_USER}@${VM_IP}..."
RETRY=0
MAX=60
until ssh $SSH_OPTS -o ConnectTimeout=5 "${CLOUD_INIT_USER}@${VM_IP}" 'echo SSH ready' 2>&1 | grep -q "SSH ready"; do
    RETRY=$((RETRY + 1))
    if [ $RETRY -ge $MAX ]; then
        echo "ERROR: SSH connection timeout after $MAX attempts"
        exit 1
    fi
    echo "  SSH not ready (attempt ${RETRY}/${MAX})"
    sleep 5
done
echo "  SSH up."

echo "Waiting for cloud-init to complete..."
if ssh $SSH_OPTS "${CLOUD_INIT_USER}@${VM_IP}" 'cloud-init status --wait' 2>&1; then
    echo "  cloud-init finished."
else
    echo "  (cloud-init status check failed — continuing anyway)"
fi

echo "VM ${VM_NAME} is ready for Ansible."
