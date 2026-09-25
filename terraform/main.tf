locals {
  labels = {
    app         = "gke-platform"
    managed_by  = "terraform"
    environment = "demo"
  }
}

# --- Network ------------------------------------------------------------------------------------
module "network" {
  source     = "./modules/network"
  project_id = var.project_id
  region     = var.region
  name       = "platform-vpc"
  depends_on = [google_project_service.apis]
}

# --- FinOps: per-namespace/label cost attribution lands here ------------------------------------
resource "google_bigquery_dataset" "usage" {
  project                    = var.project_id
  dataset_id                 = "gke_usage"
  location                   = var.region
  description                = "GKE resource-consumption metering export (cost allocation by namespace/label)"
  delete_contents_on_destroy = true
  labels                     = local.labels
  depends_on                 = [google_project_service.apis]
}

# --- Cluster ----------------------------------------------------------------------------------------
module "gke" {
  source               = "./modules/gke"
  project_id           = var.project_id
  region               = var.region
  name                 = var.cluster_name
  network              = module.network.network
  subnetwork           = module.network.subnetwork
  authorized_cidr      = var.authorized_cidr
  node_service_account = local.sa["gke-nodes"]
  usage_dataset_id     = google_bigquery_dataset.usage.dataset_id
  labels               = local.labels

  # The policy must exist before the first pod is admitted, so system workloads never race it.
  depends_on = [
    google_project_iam_member.this,
    module.binauthz,
  ]
}

# --- Artifact Registry ------------------------------------------------------------------------------
resource "google_artifact_registry_repository" "apps" {
  project       = var.project_id
  location      = var.region
  repository_id = "apps"
  format        = "DOCKER"
  description   = "Application images (vulnerability-scanned on push, tags immutable)"

  docker_config { immutable_tags = true }

  cleanup_policies {
    id     = "keep-last-15"
    action = "KEEP"
    most_recent_versions { keep_count = 15 }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition { older_than = "1209600s" }
  }
  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "writer" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.sa["plat-build"]}"
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each   = toset(["gke-nodes", "plat-deploy-exec"])
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.apps.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.sa[each.value]}"
}

# --- Buckets ---------------------------------------------------------------------------------------
resource "google_storage_bucket" "build_staging" {
  project                     = var.project_id
  name                        = "${var.project_id}-gke-build-staging"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  lifecycle_rule {
    condition { age = 7 }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "deploy_artifacts" {
  project                     = var.project_id
  name                        = "${var.project_id}-clouddeploy-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  lifecycle_rule {
    condition { age = 14 }
    action { type = "Delete" }
  }
}

# Data owned by tenant team-a: readable by team-a's Kubernetes ServiceAccount only (keyless, via
# Workload Identity Federation for GKE); team-b has no grant, which scripts/test.sh proves.
resource "google_storage_bucket" "team_a" {
  project                     = var.project_id
  name                        = "${var.project_id}-team-a-data"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
}

resource "google_storage_bucket_object" "team_a_sample" {
  bucket  = google_storage_bucket.team_a.name
  name    = "hello.txt"
  content = "team-a private data: readable only via team-a's workload identity\n"
}

resource "google_storage_bucket_iam_member" "team_a_reader" {
  bucket = google_storage_bucket.team_a.name
  role   = "roles/storage.objectViewer"
  member = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/team-a/sa/reader"
}

resource "google_storage_bucket_iam_member" "build_reads_source" {
  bucket = google_storage_bucket.build_staging.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.sa["plat-build"]}"
}

resource "google_storage_bucket_iam_member" "stagers" {
  for_each = { admin = "user:${var.admin_email}", ci = "serviceAccount:${local.sa["plat-ci-deploy"]}" }
  bucket   = google_storage_bucket.build_staging.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "exec_artifacts" {
  bucket = google_storage_bucket.deploy_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.sa["plat-deploy-exec"]}"
}

# --- Supply-chain security: only pipeline-signed images may run ------------------------------------
module "binauthz" {
  source     = "./modules/binauthz"
  project_id = var.project_id
  region     = var.region
  suffix     = var.resource_suffix
  attester_members = {
    build = "serviceAccount:${local.sa["plat-build"]}"
  }
  allowlist_patterns = var.admission_allowlist
  depends_on         = [google_project_service.apis, google_project_iam_member.this]
}

# --- Edge -------------------------------------------------------------------------------------------
module "edge" {
  source     = "./modules/edge"
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

# --- Continuous delivery ---------------------------------------------------------------------------
module "delivery" {
  source          = "./modules/delivery"
  project_id      = var.project_id
  region          = var.region
  cluster_id      = module.gke.id
  executor_sa     = local.sa["plat-deploy-exec"]
  artifact_bucket = google_storage_bucket.deploy_artifacts.name
  depends_on = [
    google_project_service.apis,
    google_project_iam_member.this,
    google_storage_bucket_iam_member.exec_artifacts,
  ]
}

# --- Observability & cost guardrails ----------------------------------------------------------------
module "observability" {
  source       = "./modules/observability"
  project_id   = var.project_id
  cluster_name = var.cluster_name
  alert_email  = var.alert_email
  lb_ip        = module.edge.ip_address
  depends_on   = [google_project_service.apis]
}

resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = "gke-platform monthly guardrail"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }
  amount {
    specified_amount { units = tostring(var.budget_amount) }
  }
  dynamic "threshold_rules" {
    for_each = [0.25, 0.5, 0.9, 1.0]
    content { threshold_percent = threshold_rules.value }
  }
  all_updates_rule {
    monitoring_notification_channels = [module.observability.notification_channel]
    disable_default_iam_recipients   = false
  }
}

# --- Keyless CI/CD ------------------------------------------------------------------------------------
module "github_wif" {
  source          = "./modules/github_wif"
  project_id      = var.project_id
  github_repo     = var.github_repo
  plan_sa_email   = local.sa["plat-ci-plan"]
  deploy_sa_email = local.sa["plat-ci-deploy"]
  pool_suffix     = var.resource_suffix
  depends_on      = [google_project_service.apis]
}
