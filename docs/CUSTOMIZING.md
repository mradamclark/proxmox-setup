# Customizing the playbook

This is meant as a starting point, not a finished product. Here's how to
extend it without fighting the existing structure.

## Directory layout

```
proxmox-setup/
├── playbook.yml                           # entry point
├── inventory.example.yml                  # copy to inventory.yml
├── ansible.cfg                            # inventory + vault pw wired up
├── group_vars/
│   └── proxmox_hosts/main.yml             # tunables for every node
├── host_vars/
│   └── <hostname>.yml                     # per-node overrides
├── tasks/
│   ├── common/                            # generic Linux tasks
│   │   ├── hostname.yml
│   │   ├── update-packages.yml
│   │   ├── required-packages.yml
│   │   ├── secure-ssh.yml
│   │   └── users.yml
│   └── proxmox/                           # Proxmox-specific tasks
│       ├── repos.yml
│       ├── configure.yml
│       ├── shared-storage.yml
│       └── acme.yml
├── ssh-keys/                              # <username>.pub files
└── docs/
```

## Running a subset

Every task file has tags. The big ones:

| Tag            | What it runs                                           |
|----------------|--------------------------------------------------------|
| `hostname`     | Set hostname + update `/etc/hosts`                     |
| `repos`        | Swap enterprise APT repo for no-subscription           |
| `packages`     | `apt upgrade` + install baseline + Proxmox packages    |
| `ssh`          | Harden sshd (disable password auth, etc.)              |
| `users`        | Create admin users + install SSH keys + sudoers        |
| `network`      | IP forwarding + e1000e NIC workaround                  |
| `tuning`       | swappiness + inotify limits                            |
| `nfs`          | NFS shared storage (only if `pve_shared_nfs_enabled`)  |
| `acme`         | LE certs (only if `proxmox_acme_enabled`)              |

Examples:

```bash
ansible-playbook playbook.yml                      # full run
ansible-playbook playbook.yml --limit pve1         # one node
ansible-playbook playbook.yml --tags acme          # renew/issue certs
ansible-playbook playbook.yml --tags users,ssh     # just accounts + ssh
ansible-playbook playbook.yml --check --diff       # dry run
```

## Adding a new task

Drop a new file in `tasks/common/` or `tasks/proxmox/`, then import it
from `playbook.yml`. For example, to add a postfix null-client so nodes
can email you on cert expiry:

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

Then in `playbook.yml`:

```yaml
- import_tasks: tasks/common/mail-relay.yml
  when: mail_relay_enabled | default(false)
```

...and add the default to `group_vars/proxmox_hosts/main.yml`:

```yaml
mail_relay_enabled: false
```

## Adding a host

1. Add it to `inventory.yml` under `proxmox_hosts.hosts:`.
2. Optionally create `host_vars/<hostname>.yml` for any per-node overrides.
3. Run the playbook: `ansible-playbook playbook.yml --limit <hostname>`.

## Adding a user

1. Add the username to the `users` list in `inventory.yml`.
2. Drop their public key at `ssh-keys/<username>.pub`.
3. Re-run with `--tags users`.

## Secrets

Anything sensitive (Cloudflare tokens, subscription keys, SMTP creds)
belongs in an ansible-vault-encrypted file, not in `host_vars/pve1.yml`
as plain text. The setup already wires `ansible-vault` into `ansible.cfg`
via `vault.pwd` (which is gitignored — copy `vault.pwd.example` and put
your real password in `vault.pwd`).

Typical pattern:

```bash
ansible-vault create group_vars/proxmox_hosts/vault.yml
# editor opens, write secrets as plain YAML, save
```

Then reference those variables from regular task files — Ansible loads
encrypted group_vars transparently.
