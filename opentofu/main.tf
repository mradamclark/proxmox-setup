# Shared data + locals used by vm-example.tf and lxc-example.tf.

data "local_file" "ssh_key" {
  filename = "${path.module}/${var.ssh_key_file}"
}

locals {
  ssh_key = trimspace(data.local_file.ssh_key.content)
}
