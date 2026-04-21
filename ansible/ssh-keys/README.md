# SSH public keys

Drop one `<username>.pub` file here for every entry in the `users` list in
your inventory. The `users.yml` task installs each file into the matching
user's `~/.ssh/authorized_keys` on every Proxmox node.

Example:

```
ssh-keys/
├── admin.pub       # public key for the "admin" user
└── alice.pub       # public key for the "alice" user
```

**Only public keys go here.** Private keys (`id_ed25519`, `id_rsa`, etc.)
are excluded by `.gitignore` as a safety net — never commit them.
