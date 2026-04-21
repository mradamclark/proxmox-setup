# VM module variables

# --- Identity -----------------------------------------------------------------

variable "vm_name" {
  description = "VM hostname / display name in Proxmox"
  type        = string
}

variable "vm_description" {
  description = "Free-text description shown in the Proxmox UI"
  type        = string
  default     = "VM managed by OpenTofu"
}

# --- Sizing -------------------------------------------------------------------

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_gb" {
  description = "Memory in GB"
  type        = number
  default     = 2
}

variable "balloon_min_gb" {
  description = "Minimum balloon memory in GB (0 = ballooning disabled)"
  type        = number
  default     = 0
}

variable "disk_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 32
}

variable "data_disk_gb" {
  description = "Size of optional second data disk in GB (0 = no data disk)"
  type        = number
  default     = 0
}

variable "data_disk_storage" {
  description = "Storage pool for the data disk. Defaults to proxmox_storage if empty."
  type        = string
  default     = ""
}

# --- Template + cloud-init ----------------------------------------------------

variable "template_name" {
  description = "Cloud-init template name to clone from"
  type        = string
  default     = "ubuntu-24.04-cloudinit"
}

variable "cloud_init_user" {
  description = "Cloud-init username"
  type        = string
  default     = "ubuntu"
}

variable "ssh_keys" {
  description = "SSH public key(s) — newline-separated"
  type        = string
  default     = ""
}

variable "cloud_init_user_data" {
  description = "Custom cloud-init user-data YAML content. If empty, uses the default template at ../templates/cloud-init-default.yaml.tftpl."
  type        = string
  default     = ""
}

# --- Network ------------------------------------------------------------------

variable "ip_address" {
  description = "Static IP in CIDR notation (e.g. 192.168.1.100/24) or empty for DHCP"
  type        = string
  default     = ""
}

variable "gateway" {
  description = "Gateway IP (required if using a static IP)"
  type        = string
  default     = ""
}

variable "nameserver" {
  description = "DNS nameserver for cloud-init (optional)"
  type        = string
  default     = ""
}

# --- Lifecycle ----------------------------------------------------------------

variable "started" {
  description = "Whether the VM should be running after creation"
  type        = bool
  default     = true
}

variable "auto_start" {
  description = "Start the VM automatically when the Proxmox host boots"
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
  description = "Run Ansible against the VM after creation"
  type        = bool
  default     = false
}

variable "ansible_playbook" {
  description = "Path to the Ansible playbook to run (relative to this module)"
  type        = string
  default     = ""
}

variable "ansible_groups" {
  description = "Inventory group(s) to insert the new VM into if it isn't already listed"
  type        = list(string)
  default     = ["docker_hosts"]
}

# --- Proxmox ------------------------------------------------------------------

variable "proxmox_node" {
  description = "Proxmox node to create the VM on"
  type        = string
}

variable "template_node" {
  description = "Proxmox node where the cloud-init template lives. Defaults to proxmox_node when empty."
  type        = string
  default     = ""
}

variable "proxmox_storage" {
  description = "Proxmox storage pool for disks"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "proxmox_cpu_sockets" {
  description = "Number of CPU sockets"
  type        = number
  default     = 1
}

variable "proxmox_disk_iothread" {
  description = "Enable iothreads on the boot disk"
  type        = bool
  default     = false
}

variable "proxmox_disk_discard" {
  description = "Enable discard/TRIM on disks"
  type        = bool
  default     = true
}

variable "cloud_init_datastore" {
  description = "Datastore for cloud-init snippets (usually a shared one like pve-shared). Defaults to proxmox_storage when empty."
  type        = string
  default     = ""
}
