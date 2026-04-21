# LXC module variables

# --- Identity -----------------------------------------------------------------

variable "lxc_name" {
  description = "Container hostname"
  type        = string
}

variable "description" {
  description = "Free-text description shown in the Proxmox UI"
  type        = string
  default     = "LXC container managed by OpenTofu"
}

# --- Sizing -------------------------------------------------------------------

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
  default     = 2048
}

variable "swap_mb" {
  description = "Swap in MB"
  type        = number
  default     = 512
}

variable "disk_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 16
}

# --- Template / clone ---------------------------------------------------------

variable "ostemplate" {
  description = "LXC OS template (e.g. local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "clone_vm_id" {
  description = "VMID of an existing LXC template to clone from (set non-zero to override ostemplate). The source must have been turned into a template with `pct template <vmid>`."
  type        = number
  default     = 0
}

variable "unprivileged" {
  description = "Run as an unprivileged container (recommended)"
  type        = bool
  default     = true
}

# --- Network ------------------------------------------------------------------

variable "ip_address" {
  description = "Static IP in CIDR notation, or empty for DHCP"
  type        = string
  default     = ""
}

variable "gateway" {
  description = "Gateway IP (required if using a static IP)"
  type        = string
  default     = ""
}

variable "nameserver" {
  description = "DNS nameserver(s), space-separated"
  type        = string
  default     = ""
}

variable "searchdomain" {
  description = "DNS search domain for the container"
  type        = string
  default     = "lan"
}

# --- Auth ---------------------------------------------------------------------

variable "ssh_keys" {
  description = "SSH public key(s), newline-separated"
  type        = string
  default     = ""
}

# --- Storage ------------------------------------------------------------------

variable "proxmox_node" {
  description = "Proxmox node to create the container on"
  type        = string
}

variable "proxmox_ssh_host" {
  description = "SSH hostname for the Proxmox node (e.g. pve1.lan). Needed for (a) ensuring the LXC is started after create, and (b) querying its DHCP-assigned IP before the Ansible handoff."
  type        = string
  default     = ""
}

variable "proxmox_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "mountpoints" {
  description = "Bind mounts from Proxmox host into the container. `volume` is the host path, `mp` is the path inside the container."
  type = list(object({
    mp     = string
    volume = string
  }))
  default = []
}

# --- Lifecycle ----------------------------------------------------------------

variable "started" {
  description = "Whether the container should be running after creation"
  type        = bool
  default     = true
}

variable "auto_start" {
  description = "Start automatically when the Proxmox host boots"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags shown in the Proxmox UI"
  type        = list(string)
  default     = ["terraform"]
}

# --- Ansible handoff ----------------------------------------------------------

variable "run_ansible" {
  description = "Run Ansible against the container after creation. With DHCP, proxmox_ssh_host must be set so the provisioner can discover the IP."
  type        = bool
  default     = false
}

variable "ansible_playbook" {
  description = "Path to the Ansible playbook to run (relative to this module)"
  type        = string
  default     = ""
}

variable "ansible_groups" {
  description = "Inventory group(s) to insert the container into if not already listed"
  type        = list(string)
  default     = ["lxc_hosts"]
}
