# ServiceAccount for Vault snapshots
resource "kubernetes_service_account" "vault_snapshot" {
  metadata {
    name      = "vault-snapshot"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  depends_on = [helm_release.vault]
}

# Role for accessing Vault pods
resource "kubernetes_role" "vault_snapshot" {
  metadata {
    name      = "vault-snapshot"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create", "get"]
  }
  
  depends_on = [helm_release.vault]
}

# RoleBinding
resource "kubernetes_role_binding" "vault_snapshot" {
  metadata {
    name      = "vault-snapshot"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.vault_snapshot.metadata[0].name
  }
  
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault_snapshot.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  depends_on = [helm_release.vault]
}

# ConfigMap for snapshot script
resource "kubernetes_config_map" "vault_snapshot_script" {
  metadata {
    name      = "vault-snapshot-script"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  data = {
    "backup.sh" = <<-EOT
      #!/bin/sh
      set -e
      
      echo "Starting Vault backup at $(date)"
      
      # Set variables
      VAULT_POD="vault-0"
      BACKUP_DIR="/backup"
      TIMESTAMP=$(date +%Y%m%d-%H%M%S)
      SNAPSHOT_FILE="vault-snapshot-$${TIMESTAMP}.snap"
      
      # Check if Vault is initialized and unsealed
      STATUS=$(kubectl -n vault exec $${VAULT_POD} -- vault status -format=json || echo '{}')
      INITIALIZED=$(echo "$${STATUS}" | grep -o '"initialized":[^,]*' | cut -d: -f2)
      SEALED=$(echo "$${STATUS}" | grep -o '"sealed":[^,]*' | cut -d: -f2)
      
      if [ "$${INITIALIZED}" != "true" ]; then
        echo "Error: Vault is not initialized"
        exit 1
      fi
      
      if [ "$${SEALED}" != "false" ]; then
        echo "Error: Vault is sealed"
        exit 1
      fi
      
      # Take snapshot (requires VAULT_TOKEN to be set as env var)
      echo "Taking Vault snapshot..."
      kubectl -n vault exec $${VAULT_POD} -- sh -c "
        export VAULT_TOKEN='$${VAULT_TOKEN}'
        vault operator raft snapshot save /tmp/$${SNAPSHOT_FILE}
      "
      
      # Copy snapshot to backup volume
      echo "Copying snapshot to backup volume..."
      kubectl -n vault cp $${VAULT_POD}:/tmp/$${SNAPSHOT_FILE} $${BACKUP_DIR}/$${SNAPSHOT_FILE}
      
      # Clean up old snapshots (keep last 30 days)
      echo "Cleaning up old snapshots..."
      find $${BACKUP_DIR} -name "vault-snapshot-*.snap" -mtime +30 -delete
      
      # List current backups
      echo "Current backups:"
      ls -lh $${BACKUP_DIR}/vault-snapshot-*.snap | tail -10
      
      echo "Backup completed successfully: $${SNAPSHOT_FILE}"
    EOT
  }
  
  depends_on = [helm_release.vault]
}

# PersistentVolumeClaim for storing snapshots
resource "kubernetes_persistent_volume_claim" "vault_snapshots" {
  metadata {
    name      = "vault-snapshots"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  spec {
    access_modes = ["ReadWriteOnce"]
    
    resources {
      requests = {
        storage = "20Gi"
      }
    }
    
    storage_class_name = "local-path"
  }
  
  depends_on = [helm_release.vault]
}

# CronJob for automated snapshots
resource "kubernetes_cron_job" "vault_snapshot" {
  metadata {
    name      = "vault-snapshot"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  
  spec {
    schedule                      = "0 2 * * *"  # Daily at 2 AM
    concurrency_policy           = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit    = 3
    
    job_template {
      metadata {
        labels = {
          app = "vault-snapshot"
        }
      }
      
      spec {
        backoff_limit = 3
        
        template {
          metadata {
            labels = {
              app = "vault-snapshot"
            }
          }
          
          spec {
            service_account_name = kubernetes_service_account.vault_snapshot.metadata[0].name
            restart_policy      = "OnFailure"
            
            container {
              name  = "snapshot"
              image = "bitnami/kubectl:latest"
              
              command = ["/scripts/backup.sh"]
              
              env {
                name = "VAULT_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "vault-snapshot-token"
                    key  = "token"
                  }
                }
              }
              
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.vault_snapshot_script.metadata[0].name
                default_mode = "0755"
              }
            }
            
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.vault_snapshots.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  
  depends_on = [
    helm_release.vault,
    kubernetes_config_map.vault_snapshot_script,
    kubernetes_persistent_volume_claim.vault_snapshots
  ]
}