variable "project_id" { type = string }
variable "region" { type = string }
variable "name" { type = string }
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "authorized_cidr" { type = string }
variable "node_service_account" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name
  location = var.region

  # Autopilot: Google manages nodes, bin-packing, upgrades, hardening. We pay per pod request,
  # not per node, and inherit Workload Identity, Shielded Nodes, Dataplane V2 (NetworkPolicy) by default.
  enable_autopilot    = true
  deletion_protection = false
  resource_labels     = var.labels

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Control plane reachable only from the operator's IP and Google Cloud public IPs (Cloud Deploy,
  # Cloud Build). Still IAM + RBAC gated. See docs/adr/0003 for the private-pool alternative.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = true
    cidr_blocks {
      cidr_block   = var.authorized_cidr
      display_name = "operator"
    }
  }

  release_channel { channel = "REGULAR" }

  gateway_api_config { channel = "CHANNEL_STANDARD" }

  secret_manager_config { enabled = true }

  binary_authorization { evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE" }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_DISABLED"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "POD", "DEPLOYMENT", "HPA", "KUBELET", "CADVISOR"]
    managed_prometheus { enabled = true }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Cost allocation: spend by namespace and label in Cloud Billing reports / billing export.
  # (GKE usage metering export to BigQuery is not supported on Autopilot.)
  cost_management_config { enabled = true }


  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = var.node_service_account
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T02:00:00Z"
      end_time   = "2026-01-03T08:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }
}

output "name" { value = google_container_cluster.this.name }
output "id" { value = google_container_cluster.this.id }
output "endpoint" { value = google_container_cluster.this.endpoint }
