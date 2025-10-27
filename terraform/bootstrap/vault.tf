# Vault Installation with Raft Storage
resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  version    = "0.31.0"
  
  values = [
    yamlencode({
      injector = {
        enabled = false
      }
      
      server = {
        ha = {
          enabled = true
          replicas = 1
          raft = {
            enabled = true
            config = <<-EOT
              ui = true
              
              listener "tcp" {
                tls_disable = 1
                address = "[::]:8200"
                cluster_address = "[::]:8201"
              }
              
              storage "raft" {
                path = "/vault/data"
              }
              
              service_registration "kubernetes" {}
              
              disable_mlock = true
              api_addr = "http://vault.vault.svc.cluster.local:8200"
              cluster_addr = "http://vault.vault.svc.cluster.local:8201"
            EOT
          }
        }
        
        dataStorage = {
          enabled = true
          size = "10Gi"
          storageClass = "local-path"
        }
        
        auditStorage = {
          enabled = true
          size = "10Gi"
          storageClass = "local-path"
        }
        
        service = {
          type = "LoadBalancer"
          loadBalancerIP = var.vault_loadbalancer_ip
        }
        
        resources = {
          requests = {
            memory = "256Mi"
            cpu = "250m"
          }
          limits = {
            memory = "512Mi"
            cpu = "500m"
          }
        }
      }
      
      ui = {
        enabled = true
        serviceType = "LoadBalancer"
        loadBalancerIP = var.vault_loadbalancer_ip
      }
    })
  ]
  
  depends_on = [kubernetes_namespace.vault]
}