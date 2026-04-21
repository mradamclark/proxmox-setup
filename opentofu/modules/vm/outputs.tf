output "vm_name" {
  description = "VM hostname"
  value       = var.vm_name
}

output "vm_id" {
  description = "Proxmox VMID"
  value       = proxmox_virtual_environment_vm.vm.id
}

output "ip_address" {
  description = "Primary IP reported by the QEMU guest agent (empty until the VM boots)"
  value       = try(proxmox_virtual_environment_vm.vm.ipv4_addresses[1][0], null)
}

output "proxmox_node" {
  description = "Proxmox node the VM runs on"
  value       = var.proxmox_node
}
