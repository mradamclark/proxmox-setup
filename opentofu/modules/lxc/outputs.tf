output "lxc_name" {
  description = "Container hostname"
  value       = var.lxc_name
}

output "ip_address" {
  description = "Configured IP address or 'dhcp'"
  value       = var.ip_address != "" ? var.ip_address : "dhcp"
}

output "proxmox_node" {
  description = "Proxmox node"
  value       = var.proxmox_node
}
