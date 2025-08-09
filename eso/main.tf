terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "/home/decoder/dev/homelab/kubeconfig"
  }
}

provider "kubernetes" {
  config_path = "/home/decoder/dev/homelab/kubeconfig"
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = "0.30.1"

  set {
    name  = "server.dev.enabled"
    value = "true"
  }

  set {
    name  = "injector.enabled"
    value = "false"
  }

  set {
    name  = "ui.enabled"
    value = "true"
  }

  set {
    name  = "ui.serviceType"
    value = "LoadBalancer"
  }

  set {
    name  = "ui.serviceNodePort"
    value = "null"
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name
  version    = "0.19.1"

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "webhook.port"
    value = "9443"
  }
}