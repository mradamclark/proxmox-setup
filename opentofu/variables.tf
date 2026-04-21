# Top-level variables for the example. Values come from terraform.tfvars.

# --- Proxmox provider ---------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve1.example.lan:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Combined API token: user@realm!tokenid=secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_root_password" {
  description = "root@pam password. Only needed if you want LXC bind mounts — Proxmox blocks API tokens from that one API."
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for the Proxmox API"
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "SSH user the provider uses for snippet uploads etc."
  type        = string
  default     = "admin"
}

# --- Defaults shared across resources -----------------------------------------

variable "proxmox_network_bridge" {
  description = "Default Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "default_vm_template" {
  description = "Cloud-init VM template to clone from"
  type        = string
  default     = "ubuntu-24.04-cloudinit"
}

variable "default_lxc_template" {
  description = "LXC OS template"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "cloud_init_user" {
  description = "Username cloud-init creates on new VMs"
  type        = string
  default     = "admin"
}

variable "ssh_key_file" {
  description = "Path (relative to this directory) of the public key dropped into new hosts"
  type        = string
  default     = "ssh-keys/admin.pub"
}

variable "cloud_init_datastore" {
  description = "Datastore for cloud-init snippets. A shared datastore (e.g. NFS) lets you clone templates between nodes."
  type        = string
  default     = "local"
}

# --- Per-node knobs -----------------------------------------------------------
# Add more entries as you add nodes to the cluster.

variable "pve1_storage" {
  description = "Storage pool on pve1 for VM/LXC disks"
  type        = string
  default     = "local-lvm"
}

variable "pve1_ssh_host" {
  description = "SSH hostname for pve1 (needed for LXC DHCP discovery + container start checks)"
  type        = string
  default     = "pve1.example.lan"
}
