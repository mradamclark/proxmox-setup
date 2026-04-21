# ssh-keys/

Drop your admin user's SSH **public** key here as `admin.pub`. It gets baked
into every new VM via cloud-init and every new LXC via the module's
`ssh_keys` input.

```bash
cp ~/.ssh/id_ed25519.pub ssh-keys/admin.pub
```

This directory should only ever contain `*.pub` files. Never private keys.
