# Proxmox provider configuration.
#
# Credentials can come from terraform.tfvars OR env vars:
#   PROXMOX_VE_ENDPOINT   (e.g. https://pve1.example.lan:8006/)
#   PROXMOX_VE_API_TOKEN  (combined: user@realm!tokenid=secret)
#   PROXMOX_VE_INSECURE   (true/false — skip TLS verification)

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_tls_insecure

  # Normal operations use an API token. If you need LXC bind mounts, you
  # have to fall back to root@pam password auth because Proxmox hard-codes
  # certain LXC operations to that specific user (see docs).
  api_token = var.proxmox_root_password != "" ? null : var.proxmox_api_token
  username  = var.proxmox_root_password != "" ? "root@pam" : null
  password  = var.proxmox_root_password != "" ? var.proxmox_root_password : null

  # The bpg/proxmox provider needs SSH access for a handful of operations
  # (notably uploading cloud-init snippets). `agent = true` uses whatever
  # is running ssh-agent on the box you invoke `tofu apply` from.
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
