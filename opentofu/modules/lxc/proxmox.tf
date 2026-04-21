# Proxmox LXC container (bpg/proxmox provider).
#
# End-to-end flow when this resource is created:
#   1. bpg/proxmox creates the container from ostemplate or by cloning a
#      template VMID, then (normally) starts it.
#   2. A local-exec provisioner SSHs to the Proxmox node and polls
#      `pct status` to make sure the LXC actually came up.
#   3. If run_ansible=true, another local-exec polls `pct exec` to learn
#      the DHCP-assigned IP, waits for SSH, then invokes
#      ansible-provisioner.sh.
#   4. ansible-provisioner.sh temporarily edits inventory.yml with the IP,
#      runs the playbook, then *restores* the original inventory (LXCs
#      self-register DNS via your BIND9 setup, so the persistent entry is
#      hostname-based).

resource "proxmox_virtual_environment_container" "container" {
  node_name      = var.proxmox_node
  tags           = var.tags
  started        = var.started
  start_on_boot  = var.auto_start
  unprivileged   = var.unprivileged

  initialization {
    hostname = var.lxc_name

    dns {
      servers = var.nameserver != "" ? split(" ", var.nameserver) : []
      domain  = var.searchdomain
    }

    ip_config {
      ipv4 {
        address = var.ip_address != "" ? var.ip_address : "dhcp"
        gateway = var.ip_address != "" ? var.gateway : null
      }
    }

    user_account {
      keys = var.ssh_keys != "" ? [var.ssh_keys] : []
    }
  }

  dynamic "clone" {
    for_each = var.clone_vm_id != 0 ? [1] : []
    content {
      vm_id     = var.clone_vm_id
      node_name = var.proxmox_node
    }
  }

  dynamic "operating_system" {
    for_each = var.clone_vm_id == 0 ? [1] : []
    content {
      template_file_id = var.ostemplate
      type             = "ubuntu"
    }
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.proxmox_storage
    size         = var.disk_gb
  }

  network_interface {
    name   = "eth0"
    bridge = var.proxmox_network_bridge
  }

  dynamic "mount_point" {
    for_each = var.mountpoints
    content {
      volume        = mount_point.value.volume
      path          = mount_point.value.mp
      mount_options = []
    }
  }

  features {
    nesting = true
  }

  lifecycle {
    ignore_changes = [
      clone,
      operating_system,
      disk,
      initialization[0].user_account,
      features,
    ]
  }

  # Belt-and-braces: the provider's started=true doesn't always stick.
  # When proxmox_ssh_host is set, poll pct status and start if needed.
  provisioner "local-exec" {
    when    = create
    command = <<-EOT
if [ -n "${var.proxmox_ssh_host}" ]; then
  VMID=$(echo "${self.id}" | awk -F'/' '{print $NF}')
  echo "Ensuring LXC $VMID (${var.lxc_name}) is running on ${var.proxmox_ssh_host}..."
  for i in $(seq 1 12); do
    STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${var.proxmox_ssh_host}" "sudo pct status $VMID 2>/dev/null" | awk '{print $2}')
    if [ "$STATUS" = "running" ]; then
      echo "  running."
      break
    fi
    echo "  status: $${STATUS:-unknown} — starting (attempt $i/12)"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${var.proxmox_ssh_host}" "sudo pct start $VMID 2>/dev/null || true"
    sleep 5
  done
fi
EOT
  }

  # Hand off to Ansible if requested. Supports both static IPs and DHCP.
  provisioner "local-exec" {
    when    = create
    command = <<-EOT
if [ "${var.run_ansible}" = "true" ]; then
  if [ -n "${var.ip_address}" ]; then
    IP=$(echo "${var.ip_address}" | cut -d'/' -f1)
  elif [ -n "${var.proxmox_ssh_host}" ]; then
    VMID=$(echo "${self.id}" | awk -F'/' '{print $NF}')
    echo "Discovering DHCP IP for ${var.lxc_name} via ${var.proxmox_ssh_host}..."
    for i in $(seq 1 12); do
      IP=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${var.proxmox_ssh_host}" \
        "sudo pct exec $VMID -- ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1" 2>/dev/null)
      if [ -n "$IP" ]; then
        echo "  Got: $IP"
        break
      fi
      echo "  waiting for DHCP... (attempt $i/12)"
      sleep 5
    done
  fi

  if [ -z "$IP" ]; then
    echo "ERROR: Could not determine IP for ${var.lxc_name}."
    echo "Either set ip_address or ensure proxmox_ssh_host is set so we can query pct."
    exit 1
  fi

  echo "Waiting for SSH to root@$IP..."
  RETRY=0
  MAX=30
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes root@$IP echo ok 2>/dev/null; do
    RETRY=$((RETRY+1))
    [ $RETRY -ge $MAX ] && { echo "ERROR: no SSH after $((MAX * 5))s"; exit 1; }
    echo "  (attempt $RETRY/$MAX)"
    sleep 5
  done

  ${path.module}/ansible-provisioner.sh "${var.lxc_name}" "$IP" "${var.ansible_playbook}" ${join(" ", var.ansible_groups)}
else
  echo "run_ansible=false — skipping Ansible handoff for ${var.lxc_name}"
fi
EOT
  }
}
