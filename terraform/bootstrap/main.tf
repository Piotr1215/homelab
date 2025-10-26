terraform {
  required_version = ">= 1.0"
  
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "/home/decoder/dev/homelab/kubeconfig"
}

variable "vault_backup_s3_bucket" {
  description = "S3 bucket for Vault backups"
  type        = string
  default     = "vault-snapshots"
}

variable "vault_loadbalancer_ip" {
  description = "LoadBalancer IP for Vault"
  type        = string
  default     = "192.168.178.92"
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "kubectl" {
  config_path = var.kubeconfig_path
}