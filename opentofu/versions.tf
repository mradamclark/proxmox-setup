terraform {
  required_version = ">= 1.8"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}
