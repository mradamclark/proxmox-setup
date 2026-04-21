# Proxmox VM resource (bpg/proxmox provider).
#
# End-to-end flow when this resource is created:
#   1. Terraform renders the cloud-init snippet and uploads it to PVE.
#   2. bpg/proxmox clones the template VM, applies config, boots it.
#   3. bpg blocks until the QEMU guest agent reports an IP.
#   4. The `local-exec` provisioner calls ../../modules/vm/wait-for-vm.sh
#      (SSH + cloud-init status check).
#   5. It then calls ansible-provisioner.sh, which edits the sibling
#      ansible/inventory.yml with the VM's IP, runs the playbook, then
#      flips inventory back to the VM's hostname.

data "proxmox_virtual_environment_vms" "template" {
  node_name = var.template_node != "" ? var.template_node : var.proxmox_node
  filter {
    name   = "name"
    values = [var.template_name]
  }
}

# Render + upload cloud-init user-data snippet to PVE
resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.cloud_init_datastore != "" ? var.cloud_init_datastore : var.proxmox_storage
  node_name    = var.proxmox_node

  source_raw {
    data = var.cloud_init_user_data != "" ? var.cloud_init_user_data : templatefile(
      "${path.module}/../../templates/cloud-init-default.yaml.tftpl",
      {
        username = var.cloud_init_user
        ssh_key  = var.ssh_keys
      }
    )
    file_name = "cloud-init-${var.vm_name}.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  name        = var.vm_name
  description = var.vm_description
  node_name   = var.proxmox_node
  started     = var.started
  on_boot     = var.auto_start
  tags        = var.tags

  clone {
    vm_id     = data.proxmox_virtual_environment_vms.template.vms[0].vm_id
    node_name = var.template_node != "" ? var.template_node : var.proxmox_node
    full      = true
  }

  cpu {
    cores   = var.cpu_cores
    sockets = var.proxmox_cpu_sockets
    type    = "host"
  }

  memory {
    dedicated = var.memory_gb * 1024
    floating  = var.balloon_min_gb > 0 ? var.balloon_min_gb * 1024 : 0
  }

  disk {
    datastore_id = var.proxmox_storage
    interface    = "scsi0"
    size         = var.disk_gb
    iothread     = var.proxmox_disk_iothread
    discard      = var.proxmox_disk_discard ? "on" : "ignore"
  }

  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      datastore_id = var.data_disk_storage != "" ? var.data_disk_storage : var.proxmox_storage
      interface    = "scsi1"
      size         = var.data_disk_gb
      iothread     = var.proxmox_disk_iothread
      discard      = var.proxmox_disk_discard ? "on" : "ignore"
    }
  }

  network_device {
    bridge = var.proxmox_network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.proxmox_storage

    ip_config {
      ipv4 {
        address = var.ip_address != "" ? var.ip_address : "dhcp"
        gateway = var.ip_address != "" ? var.gateway : null
      }
    }

    dns {
      servers = var.nameserver != "" ? [var.nameserver] : []
      domain  = "lan"
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
  }

  agent {
    enabled = true
  }

  # Enable the Proxmox serial console (`qm terminal <vmid>`) as an
  # out-of-band recovery path. Needs a guest-side getty on ttyS0
  # (handled by the Ansible role that configures the VM).
  serial_device {
    device = "socket"
  }

  scsi_hardware = "virtio-scsi-pci"

  lifecycle {
    ignore_changes = [
      clone,          # clone source is one-time; don't re-clone on template changes
      disk[0],        # boot disk resizes are done outside OpenTofu
      network_device, # MAC addresses are assigned by PVE
      initialization, # cloud-init is seeded once
    ]
  }

  # Wait for QEMU guest agent → wait for SSH + cloud-init → hand off to Ansible.
  provisioner "local-exec" {
    when    = create
    command = <<-EOT
if [ "${var.run_ansible}" = "true" ]; then
  echo "Waiting for QEMU guest agent..."
  RETRY=0
  MAX=36
  VM_IP=""
  while [ $RETRY -lt $MAX ]; do
    VM_IP="${self.ipv4_addresses[1][0]}"
    if [ -n "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
      echo "  Got IP: $VM_IP"
      break
    fi
    RETRY=$((RETRY + 1))
    echo "  (attempt $RETRY/$MAX)"
    sleep 5
  done
  if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
    echo "ERROR: Could not get IP address from QEMU guest agent"
    exit 1
  fi

  ${path.module}/wait-for-vm.sh "${var.vm_name}" "$VM_IP" "${var.cloud_init_user}"
  ${path.module}/ansible-provisioner.sh "${var.vm_name}" "$VM_IP" "${var.ansible_playbook}" ${join(" ", var.ansible_groups)}
else
  echo "run_ansible=false — skipping Ansible handoff for ${var.vm_name}"
fi
EOT
  }
}
