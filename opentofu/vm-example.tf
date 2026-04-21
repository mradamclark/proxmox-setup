# Example VM — a Docker host wired up for Ansible provisioning.
#
# After `tofu apply`, the local-exec provisioner chain will:
#   1. Wait for the QEMU guest agent to report an IP
#   2. Wait for SSH + cloud-init to finish
#   3. Edit ../ansible/inventory.yml so ansible_host = <IP>
#   4. Run  ansible-playbook ../ansible/playbooks/docker.yml --limit docker-vm1
#   5. On success, flip the inventory entry back to ansible_host = docker-vm1
#
# Flip `run_ansible = false` to create the VM without the handoff — useful
# the first time you're testing the Proxmox provider on its own.

module "docker_vm1" {
  source = "./modules/vm"

  # --- Identity + sizing --------------------------------------------------
  vm_name        = "docker-vm1"
  vm_description = "Docker Compose host (managed by OpenTofu + Ansible)"

  cpu_cores      = 2
  memory_gb      = 4
  balloon_min_gb = 1
  disk_gb        = 32

  # --- Cloud-init ---------------------------------------------------------
  template_name   = var.default_vm_template
  cloud_init_user = var.cloud_init_user
  ssh_keys        = local.ssh_key

  # --- Proxmox placement --------------------------------------------------
  proxmox_node           = "pve1"
  proxmox_storage        = var.pve1_storage
  proxmox_network_bridge = var.proxmox_network_bridge
  cloud_init_datastore   = var.cloud_init_datastore

  # --- Tags (for Proxmox UI) ----------------------------------------------
  tags = ["terraform", "docker"]

  # --- Ansible handoff ----------------------------------------------------
  # After the VM is SSH-reachable, hand off to Ansible. playbooks/docker.yml
  # installs Docker + Compose + restic backups. To deploy services, run
  # playbooks/deploy.yml afterwards — see
  # ../ansible/hosts/docker-vm1/traefik/ for the Traefik + Cloudflare DNS-01
  # pattern picked up automatically by deploy.yml.
  run_ansible      = true
  ansible_playbook = "../ansible/playbooks/docker.yml"
  ansible_groups   = ["docker_hosts"]
}
