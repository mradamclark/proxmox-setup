# Guest-side backups with restic → BorgBase

Each Docker VM and LXC gets its own [restic](https://restic.readthedocs.io/)
repository at [BorgBase](https://www.borgbase.com/), deduplicated and
encrypted, driven by a systemd timer inside the guest. The Ansible role
(`tasks/common/restic-backups.yml`) installs restic, drops the repo + password
under `/etc/restic/`, and schedules a nightly `restic backup` + `restic forget
--prune`.

## Why this shape

- **Per-guest repos.** Each host writes to its own BorgBase repo. Losing
  credentials for one host doesn't expose anyone else's data, and per-repo
  retention makes rotation obvious.
- **REST + encryption at rest.** BorgBase speaks restic's REST protocol over
  HTTPS; data is encrypted client-side before it leaves the host.
- **No agent on the Proxmox host.** The Proxmox nodes don't run restic —
  they don't need to. If you destroy a VM, you restore it from BorgBase *to
  a fresh VM*, not from a vzdump snapshot.
- **systemd timers, not cron.** Jitter (`RandomizedDelaySec`) prevents a
  thundering herd when many guests share a backup window, and
  `Persistent=true` means missed runs are caught up after downtime.

## Flow

```mermaid
sequenceDiagram
    participant T as systemd timer
    participant S as restic-backup.service
    participant W as /usr/local/sbin/restic-backup
    participant R as restic
    participant B as BorgBase REST

    Note over T: fires nightly (OnCalendar + jitter)
    T->>S: start oneshot
    S->>W: ExecStart=/usr/local/sbin/restic-backup
    W->>W: export RESTIC_REPOSITORY from /etc/restic/repo
    W->>W: export RESTIC_PASSWORD_FILE=/etc/restic/password
    W->>R: restic backup <paths> --tag automated
    R->>B: HTTPS: PUT chunks + index
    B-->>R: 200 OK
    W->>R: restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
    R->>B: HTTPS: DELETE expired snapshots + orphan packs
    B-->>R: 200 OK
    R-->>W: exit 0
    W->>W: logger -t restic-backup
    W-->>S: exit 0
    S-->>T: service done
```

## One-time setup

### 1. Create the BorgBase repo

Sign in at <https://www.borgbase.com/>, go to **Repositories → New Repo**, pick
**Restic** as the type. You get:

- A REST URL like `https://eu.borgbase.com:443/`
- A repo user + password (save both)
- A region suffix you can ignore for now

### 2. Put credentials in your vault

Create `group_vars/all/vault.yml` and encrypt it:

```bash
cd ansible
ansible-vault create group_vars/all/vault.yml
```

Contents:

```yaml
---
vault_borgbase_username: "xxxx-xxxx-xxxx"
vault_borgbase_password: "the-repo-password-borgbase-gave-you"
vault_restic_password:   "SEPARATE-key-used-for-client-side-encryption"
```

The `vault_restic_password` is what encrypts your data *client-side*, before
it ever leaves the host. Generate one with:

```bash
openssl rand -base64 32
```

**Save it somewhere safe outside of BorgBase.** If BorgBase loses your repo
access password, you can reset it. If you lose the restic password, your data
is unrecoverable — that's the point of client-side encryption.

### 3. Configure defaults

Defaults live in [`group_vars/all/backups.yml`](../group_vars/all/backups.yml).
The only thing most people need to change there is `borgbase_restic_host` to
match the region suffix BorgBase gave them.

### 4. Opt a host in

Per-host config goes in `host_vars/<name>.yml`. See
[`host_vars/docker-vm1.yml`](../host_vars/docker-vm1.yml) as a starting point:

```yaml
restic_backups_enabled: true
restic_paths:
  - /etc
  - /root
  - /var/lib/docker/volumes
```

### 5. Run the playbook

```bash
ansible-playbook playbooks/docker.yml --limit docker-vm1 --tags backups
```

On first run the role initializes the restic repo; subsequent runs detect the
existing repo and skip init.

### 6. Verify

From the host:

```bash
# The timer is scheduled and enabled
systemctl list-timers restic-backup.timer

# Trigger a one-off backup right now
systemctl start restic-backup.service
journalctl -u restic-backup.service -f

# List snapshots you have at BorgBase
RESTIC_REPOSITORY=$(cat /etc/restic/repo) \
RESTIC_PASSWORD_FILE=/etc/restic/password \
    restic snapshots
```

## Restore

All restore operations happen on a host that has the repo URL and the restic
password available. That can be the original VM (recovering a deleted file)
or a fresh replacement VM (full disaster recovery).

### Restore specific files

```bash
# Find the snapshot you want
export RESTIC_REPOSITORY=$(cat /etc/restic/repo)
export RESTIC_PASSWORD_FILE=/etc/restic/password
restic snapshots

# Restore /opt/myapp/config.yml from a specific snapshot to /tmp
restic restore <snapshot-id> --target /tmp --include /opt/myapp/config.yml
```

### Restore everything (disaster recovery)

```bash
# On a freshly provisioned replacement VM, after installing restic + copying
# the credentials file from your password manager:
export RESTIC_REPOSITORY="rest:https://USER:PASS@eu.borgbase.com:443/"
export RESTIC_PASSWORD="<your-client-side-encryption-key>"

# Restore to / — be careful with --target
restic restore latest --target /

# or restore by hostname if multiple hosts share a repo
restic restore latest --host <old-vm-name> --target /
```

### Mount a snapshot read-only

Handy for hunting through old versions of a file without extracting anything:

```bash
mkdir /mnt/restic
restic mount /mnt/restic
# another terminal:
ls /mnt/restic/snapshots/latest/
umount /mnt/restic      # clean up when done
```

## Operational notes

- **Repo lock stuck after an interrupted run**: `restic unlock` on the host.
- **Repo integrity check**: `restic check` — slow but thorough. Worth running
  monthly; schedule it separately with another systemd timer if you want it
  automated.
- **Cost control at BorgBase**: keep `restic_retention.keep_*` conservative;
  dedupe + forget --prune together mean only unique chunks stay billable.
- **Multiple restore environments**: restic is happy to target multiple
  repos — set up a second `restic_repository` in host_vars for off-site
  redundancy (e.g. Backblaze B2, S3, a second BorgBase region) and it'll
  back up to both in sequence by wrapping the service.
- **Testing restores.** The only backup that counts is one you've restored
  from. Pick a recurring day — first of the month — and restore one
  random file to `/tmp` as a sanity check.
