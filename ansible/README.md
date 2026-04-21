# proxmox-setup

An Ansible playbook that takes a fresh Proxmox VE install from
"iso-just-booted" to "running the way I like it" — idempotently, so you
can re-run it whenever you add a node or change config.

Works on Proxmox VE 8 and 9.

## What it does

Per node, in order:

1. **Hostname** — set from inventory, update `/etc/hosts`.
2. **Repos** — remove the enterprise APT repo, enable no-subscription.
3. **Packages** — full system update + baseline tools + Proxmox packages.
4. **SSH** — disable password auth, restrict root to key-only.
5. **Users** — create admin accounts, install SSH public keys, grant
   passwordless sudo.
6. **Configure** — enable IP forwarding, apply the Intel e1000e NIC
   hardware-hang workaround (no-op on other NICs), tune swappiness and
   inotify limits.
7. **Shared NFS storage** *(optional, off by default)* — register a
   `pve-shared` NFS pool on every node so VMs/CTs, ISOs, templates, and
   backups can migrate between nodes without re-downloading.
8. **ACME** *(optional, off by default)* — issue a Let's Encrypt cert
   for each node's web UI via Cloudflare DNS-01. Proxmox's built-in
   daily timer handles renewals.
9. **node_exporter** *(optional, off by default)* — install
   `prometheus-node-exporter` on every node so host metrics (CPU,
   memory, disk, network, hwmon temps) are exposed on :9100 for
   scraping. No Prometheus scrape config is managed — point your own
   Prometheus at the nodes.

Every task uses tags, so you can run subsets like `--tags acme` or
`--tags users,ssh`.

## Prerequisites

- Ansible 2.15+ on your workstation.
- SSH access to each node as `root` (or a user with passwordless sudo).
- An SSH public key for every account you list under `users`.

Install the collections the playbook uses:

```bash
ansible-galaxy collection install ansible.posix community.general
```

## Quick start

```bash
# 1. Copy and edit the inventory
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml

# 2. Drop public keys for every user listed in inventory.yml
cp ~/.ssh/id_ed25519.pub ssh-keys/admin.pub

# 3. (Optional) Set up a vault password
cp vault.pwd.example vault.pwd
$EDITOR vault.pwd

# 4. Review the defaults
$EDITOR group_vars/proxmox_hosts/main.yml

# 5. Run it
ansible-playbook playbook.yml
```

Useful subsets:

```bash
ansible-playbook playbook.yml --limit pve1        # one node
ansible-playbook playbook.yml --tags users        # just users + keys
ansible-playbook playbook.yml --tags acme         # issue/renew certs
ansible-playbook playbook.yml --check --diff      # dry-run preview
```

## Configuration

All tunables live in `group_vars/proxmox_hosts/main.yml`. The big
feature toggles:

```yaml
pve_shared_nfs_enabled: false         # register a shared NFS pool
proxmox_acme_enabled: false           # issue LE certs via Cloudflare DNS-01
proxmox_node_exporter_enabled: false  # install prometheus-node-exporter on :9100
```

Most people will want to leave the rest alone until they have a reason
to change them. Per-host overrides go in `host_vars/<hostname>.yml`.

## Optional features in more detail

- **Let's Encrypt certs** — see [docs/ACME.md](docs/ACME.md) for the
  full walkthrough, including how to scope a Cloudflare API token.
- **Customizing / adding new tasks** — see [docs/CUSTOMIZING.md](docs/CUSTOMIZING.md).

## A note on what's *not* here

- **No subscription bypass.** The playbook swaps to the no-subscription
  repo so `apt update` works, but it does not suppress the "no valid
  subscription" dialog. If that bothers you, buy a subscription or look
  up the half-dozen community patches separately.
- **No backup configuration.** Backups depend a lot on what you're
  actually running, where you want them going, and how you want them
  rotated. Configure Proxmox Backup Server or `vzdump` jobs directly.
- **No cluster bootstrap.** Creating a PVE cluster (`pvecm create` /
  `pvecm add`) is a one-time, state-sensitive operation that's easier
  to do by hand. This playbook configures nodes but doesn't form the
  cluster for you.
- **No Prometheus server or scrape config.** The optional
  `proxmox_node_exporter_enabled` toggle installs node_exporter on the
  nodes themselves, but you bring your own Prometheus to scrape
  `<host>:9100`. There's no dashboard or alerting shipped either.

## License

MIT — see [LICENSE](LICENSE).
