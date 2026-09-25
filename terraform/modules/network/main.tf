variable "project_id" { type = string }
variable "region" { type = string }
variable "name" { type = string }

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke" {
  project                  = var.project_id
  name                     = "${var.name}-gke"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.20.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.32.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.33.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.3
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Private nodes have no public IPs; Cloud NAT gives them controlled egress (image pulls from
# upstream registries, GitHub for Argo CD). Ingress from the internet only via the LB.
resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "this" {
  project                            = var.project_id
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  min_ports_per_vm                   = 64

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

output "network" { value = google_compute_network.vpc.name }
output "network_id" { value = google_compute_network.vpc.id }
output "subnetwork" { value = google_compute_subnetwork.gke.name }
