# Customizing the playbooks

A starting point, not a finished product. Here's how to extend without
fighting the existing structure.

## Directory layout

```text
ansible/
├── ansible.cfg                            # inventory + vault pw wired up
├── inventory.example.yml                  # copy to inventory.yml
├── playbooks/
│   ├── proxmox.yml                        # Proxmox node config
│   ├── docker.yml                         # Docker VM install + backups
│   ├── lxc.yml                            # LXC config + backups
│   └── deploy.yml                         # deploy docker-compose services
├── group_vars/
│   ├── all/
│   │   ├── backups.yml                    # restic defaults (disabled)
│   │   └── vault.yml                      # encrypted — you create this
│   └── proxmox_hosts/main.yml             # tunables for every node
├── host_vars/
│   ├── <hostname>.yml                     # per-host overrides
│   └── docker-vm1.yml                     # example: opted-in backups
├── tasks/
│   ├── common/                            # generic Linux tasks
│   ├── docker/                            # install, check, deploy-container
│   └── proxmox/                           # Proxmox-specific tasks
├── templates/common/                      # restic wrapper + systemd units
├── hosts/<hostname>/<service>/            # per-host docker-compose stacks
└── ssh-keys/                              # <username>.pub files
```

## Running a subset

Every task file has tags. The big ones:

| Tag                           | What it runs                                                               |
|-------------------------------|----------------------------------------------------------------------------|
| `hostname`                    | Set hostname + update `/etc/hosts`                                         |
| `repos`                       | Swap enterprise APT repo for no-subscription                               |
| `packages`                    | `apt upgrade` + install baseline + Proxmox packages                        |
| `ssh`                         | Harden sshd (disable password auth, etc.)                                  |
| `users`                       | Create admin users + install SSH keys + sudoers                            |
| `network`                     | IP forwarding + e1000e NIC workaround                                      |
| `tuning`                      | swappiness + inotify limits                                                |
| `nfs`                         | NFS shared storage (only if `pve_shared_nfs_enabled`)                      |
| `acme`                        | LE certs (only if `proxmox_acme_enabled`)                                  |
| `node-exporter`, `monitoring` | Install prometheus-node-exporter (only if `proxmox_node_exporter_enabled`) |
| `docker`, `install`           | Install Docker CE + Compose plugin on VMs                                  |
| `backups`                     | Install + schedule restic backups on guests                                |
| `containers`, `<service>`     | Deploy one docker-compose stack (deploy.yml)                               |

Examples:

```bash
ansible-playbook playbooks/proxmox.yml                           # full Proxmox-node run
ansible-playbook playbooks/proxmox.yml --limit pve1              # one node
ansible-playbook playbooks/proxmox.yml --tags acme               # renew/issue certs
ansible-playbook playbooks/proxmox.yml --tags users,ssh          # just accounts + ssh
ansible-playbook playbooks/proxmox.yml --check --diff            # dry run

ansible-playbook playbooks/docker.yml --limit docker-vm1         # Docker VM: install + backups
ansible-playbook playbooks/docker.yml --tags backups             # just restic config

ansible-playbook playbooks/deploy.yml --limit docker-vm1 --tags traefik   # deploy one service
```

## Adding a new Proxmox-host task

Drop a new file in `tasks/common/` or `tasks/proxmox/`, then import it
from `playbooks/proxmox.yml`. For example, to add a postfix null-client so
nodes can email you on cert expiry:

```yaml
# tasks/common/mail-relay.yml
---
- name: Install postfix as a null client
  tags: ["mail"]
  ansible.builtin.apt:
    name: [postfix, mailutils]
    state: present
  # ...
```

Then in `playbooks/proxmox.yml`:

```yaml
- import_tasks: ../tasks/common/mail-relay.yml
  when: mail_relay_enabled | default(false)
```

...and add the default to `group_vars/proxmox_hosts/main.yml`:

```yaml
mail_relay_enabled: false
```

## Adding a Proxmox node

1. Add it to `inventory.yml` under `proxmox_hosts.hosts:`.
2. Optionally create `host_vars/<hostname>.yml` for any per-node overrides.
3. Run the playbook: `ansible-playbook playbooks/proxmox.yml --limit <hostname>`.

## Adding a Docker VM or LXC

The typical flow is OpenTofu-provisioned — see `../opentofu/vm-example.tf`
or `lxc-example.tf`. The opentofu module hands off to the right playbook
(`playbooks/docker.yml` or `playbooks/lxc.yml`) automatically after create.

To add a host by hand:

1. Add it to `inventory.yml` under `docker_hosts.hosts:` or `lxc_hosts.hosts:`.
2. Create `host_vars/<name>.yml` to opt into backups and list the paths
   you care about (see `host_vars/docker-vm1.yml` as a template).
3. Run the matching playbook with `--limit <name>`.

## Adding a service to deploy

Services live at `hosts/<vm-name>/<service-name>/`:

```text
ansible/hosts/docker-vm1/my-service/
├── docker-compose.yml   (required)
├── .env.j2              (optional — rendered with ansible vars/vault)
├── tasks.yml            (optional — pre-deploy hook)
└── README.md            (optional — not copied to host)
```

Deploy with:

```bash
ansible-playbook playbooks/deploy.yml --limit docker-vm1 --tags my-service
```

The tag matches the directory name. See
`hosts/docker-vm1/traefik/` as a worked example.

## Adding a user

1. Add the username to the `users` list in `inventory.yml`.
2. Drop their public key at `ssh-keys/<username>.pub`.
3. Re-run with `--tags users`.

## Secrets

Anything sensitive (Cloudflare tokens, subscription keys, SMTP creds,
BorgBase credentials) belongs in an ansible-vault-encrypted file. The
convention in this project is `group_vars/all/vault.yml`:

```bash
ansible-vault create group_vars/all/vault.yml
# editor opens, write secrets as plain YAML, save
```

Contents typically include:

```yaml
---
vault_cloudflare_dns_token: "..."    # for traefik, ACME
vault_borgbase_username:   "..."     # for guest backups
vault_borgbase_password:   "..."
vault_restic_password:     "..."
```

Regular task files and `.env.j2` templates reference these variables
directly — Ansible transparently decrypts the file when it runs.
