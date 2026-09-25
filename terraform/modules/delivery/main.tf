variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_id" { type = string }
variable "executor_sa" { type = string }
variable "artifact_bucket" { type = string }

locals {
  targets = {
    staging = { approval = false }
    prod    = { approval = true } # a human gates production
  }
}

resource "google_clouddeploy_target" "this" {
  for_each         = local.targets
  project          = var.project_id
  location         = var.region
  name             = each.key
  description      = "shop ${each.key} (namespace shop-${each.key})"
  require_approval = each.value.approval

  gke { cluster = var.cluster_id }

  execution_configs {
    usages            = ["RENDER", "DEPLOY"]
    service_account   = var.executor_sa
    artifact_storage  = "gs://${var.artifact_bucket}"
    execution_timeout = "1800s"
  }
}

resource "google_clouddeploy_delivery_pipeline" "shop" {
  project     = var.project_id
  location    = var.region
  name        = "shop"
  description = "staging (immediate) -> prod (approval + 25% -> 50% -> 100% canary)"

  serial_pipeline {
    stages {
      target_id = google_clouddeploy_target.this["staging"].name
      profiles  = ["staging"]
    }
    stages {
      target_id = google_clouddeploy_target.this["prod"].name
      profiles  = ["prod"]
      strategy {
        canary {
          runtime_config {
            kubernetes {
              service_networking {
                service                      = "shop"
                deployment                   = "shop"
                disable_pod_overprovisioning = true
              }
            }
          }
          canary_deployment {
            percentages = [25, 50]
            verify      = false
          }
        }
      }
    }
  }
}

# Canary phases advance on their own after a soak period, so a healthy release needs no human.
# A human (or the alert on the 5xx ratio) can still cancel during the soak, which is the point.
resource "google_clouddeploy_automation" "advance_canary" {
  project           = var.project_id
  location          = var.region
  name              = "advance-canary"
  delivery_pipeline = google_clouddeploy_delivery_pipeline.shop.name
  service_account   = var.executor_sa
  description       = "Advance prod canary phases after a 90s soak"

  selector {
    targets { id = google_clouddeploy_target.this["prod"].name }
  }

  rules {
    advance_rollout_rule {
      id            = "advance-after-soak"
      wait          = "90s"
      source_phases = ["canary-25", "canary-50"]
    }
  }
}

output "pipeline" { value = google_clouddeploy_delivery_pipeline.shop.name }
