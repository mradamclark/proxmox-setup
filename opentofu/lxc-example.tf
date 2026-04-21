# Example LXC — a Plex media server. Kept deliberately simple so this file
# works against a plain Proxmox install (no base-lxc template, no NFS
# export, no GPU passthrough required). The extra stanzas for a real
# production Plex LXC are shown as commented blocks further down.
#
# After `tofu apply`:
#   1. bpg creates the container from the Ubuntu ostemplate
#   2. local-exec SSHs to pve1 to confirm it started
#   3. local-exec polls `pct exec` for the DHCP-assigned IP
#   4. ansible-provisioner.sh runs the playbook against the container
#   5. Inventory is *restored* after Ansible — LXCs are expected to
#      self-register DNS during the playbook, so no persistent inventory
#      entry is needed.

module "plex_lxc" {
  source = "./modules/lxc"

  # --- Identity + sizing --------------------------------------------------
  lxc_name    = "plex"
  description = "Plex Media Server (managed by OpenTofu + Ansible)"

  cpu_cores = 4
  memory_mb = 4096
  swap_mb   = 1024
  disk_gb   = 16

  # --- Template -----------------------------------------------------------
  ostemplate   = var.default_lxc_template
  unprivileged = true

  # --- Network ------------------------------------------------------------
  # DHCP for the example. Set ip_address = "192.168.1.50/24" + gateway to
  # pin a static IP instead. With DHCP, proxmox_ssh_host must be set so
  # the provisioner can discover the IP via pct exec.
  nameserver   = "192.168.1.1"
  searchdomain = "example.lan"

  # --- Proxmox placement --------------------------------------------------
  proxmox_node           = "pve1"
  proxmox_ssh_host       = var.pve1_ssh_host
  proxmox_storage        = var.pve1_storage
  proxmox_network_bridge = var.proxmox_network_bridge

  ssh_keys = local.ssh_key
  tags     = ["terraform", "media", "plex"]

  # --- Ansible handoff ----------------------------------------------------
  run_ansible      = true
  ansible_playbook = "../ansible/playbooks/lxc.yml"
  ansible_groups   = ["lxc_hosts"]
}

# ============================================================================
# Production-lean extras — enable as needed
# ============================================================================
#
# 1) Clone from a custom base LXC template (base-lxc) instead of the stock
#    Ubuntu ostemplate. Useful when you've pre-baked users, SSH hardening,
#    and DNS self-registration into a template with `pct template <vmid>`.
#
#    clone_vm_id = 999   # VMID of your base-lxc template on pve1
#
# ----------------------------------------------------------------------------
#
# 2) NFS bind mount for a shared media library. `volume` is the path on
#    the Proxmox host (the NFS mount must already be set up there).
#
#    mountpoints = [
#      {
#        mp     = "/mnt/media"
#        volume = "/mnt/pve/media-nfs"
#      },
#    ]
#
# ----------------------------------------------------------------------------
#
# 3) GPU passthrough for Plex hardware transcoding. LXC GPU passthrough
#    needs /dev/dri exposed + the right cgroup rules. bpg/proxmox can't
#    express this natively today — the usual approach is a post-create
#    local-exec (or a small Ansible role) that edits the LXC config:
#
#        # Append to /etc/pve/lxc/<vmid>.conf on the Proxmox node:
#        lxc.cgroup2.devices.allow: c 226:0 rwm
#        lxc.cgroup2.devices.allow: c 226:128 rwm
#        lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
#
#    ...then restart the container. Keep that logic *outside* this module
#    so it stays transparent and doesn't fight the provider on every plan.
