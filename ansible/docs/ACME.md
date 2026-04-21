# Let's Encrypt certs on Proxmox (Cloudflare DNS-01)

This playbook can put a publicly-trusted Let's Encrypt certificate on
each node's Proxmox web UI (port 8006), using Proxmox's built-in
`pvenode acme` tooling with the **DNS-01** challenge. That means:

- No inbound port 80 or 443 required. Nodes only need outbound HTTPS
  to Let's Encrypt and to Cloudflare's API.
- Works fine for nodes that aren't exposed to the internet at all.
- Wildcard-capable if you want it (though this playbook issues a
  per-node cert by default, which is simpler).

## What you need

1. A domain you own, hosted on Cloudflare (free plan is fine).
2. A Cloudflare API **token** (not a global key) with:
   - Permissions: `Zone → DNS → Edit`
   - Zone Resources: `Include → Specific zone → <your zone>`

   Create it at <https://dash.cloudflare.com/profile/api-tokens>.
3. DNS records (A or AAAA) for each node inside that zone, e.g.
   `pve1.pve.example.com → 192.168.1.11`. If the node isn't reachable
   from the public internet, point the record at the LAN IP and keep
   the zone's Cloudflare proxy OFF (gray cloud) — DNS-01 doesn't care
   about reachability.

## Enable it

In `group_vars/proxmox_hosts/main.yml`:

```yaml
proxmox_acme_enabled: true
proxmox_acme_account: "default"                # label only, any string
proxmox_acme_email: "you@example.com"          # LE registration + expiry notices
proxmox_acme_domain: "pve.example.com"         # parent zone
```

Put the Cloudflare API token somewhere outside the repo — ideally in an
ansible-vault-encrypted file. For example:

```bash
ansible-vault create group_vars/proxmox_hosts/vault.yml
```

With this content:

```yaml
proxmox_acme_cloudflare_token: "cf_your_real_token_here"
```

Then run just the ACME phase:

```bash
ansible-playbook playbooks/proxmox.yml --tags acme
```

## What actually happens

1. Register an ACME account with Let's Encrypt (once per node).
2. Add the Cloudflare DNS-01 plugin to `pvenode` with your API token.
3. Configure each node to request a cert for
   `<inventory_hostname>.<proxmox_acme_domain>`.
4. Order the cert. Proxmox creates a TXT record via the Cloudflare API,
   LE validates it, Proxmox downloads and installs the cert, and
   `pveproxy` restarts.

## Renewals

**You don't re-run the playbook to renew.** Proxmox ships with a
`pve-daily-update.timer` (systemd) that already handles ACME renewals
— it's enabled out of the box. Certs renew ~30 days before expiry.

To verify the timer is active on a node:

```bash
systemctl status pve-daily-update.timer
```

To force-renew now (useful for testing):

```bash
pvenode acme cert renew --force 1
```

## Troubleshooting

- `pvenode acme cert order` hangs on "Pending": your Cloudflare token
  is missing the DNS:Edit permission, or the zone it's scoped to
  doesn't match `proxmox_acme_domain`.
- `Custom certificate exists but 'force' is not set`: the task
  auto-adds `--force 1` when it detects an existing cert at
  `/etc/pve/local/pveproxy-ssl.pem`. If you see this, the stat check
  is failing — rerun with `-vvv` and check permissions.
- Browser still shows the old self-signed cert: you may need to
  fully close the browser tab — Proxmox's web UI uses a long-lived
  websocket that won't re-TLS on reload alone.
