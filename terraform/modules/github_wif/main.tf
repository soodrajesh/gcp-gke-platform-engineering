variable "project_id" { type = string }
variable "github_repo" { type = string }
variable "plan_sa_email" { type = string }
variable "deploy_sa_email" { type = string }
variable "pool_suffix" {
  type    = string
  default = ""
}
variable "deploy_environment" {
  type    = string
  default = "prod"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github${var.pool_suffix}"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}

resource "google_service_account_iam_member" "plan" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.plan_sa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "deploy" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.deploy_sa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${var.github_repo}:environment:${var.deploy_environment}"
}

output "provider" { value = google_iam_workload_identity_pool_provider.github.name }
