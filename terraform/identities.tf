locals {
  sa_ids = ["gke-nodes", "plat-build", "plat-deploy-exec", "plat-ci-plan", "plat-ci-deploy"]
}

resource "google_service_account" "this" {
  for_each     = toset(local.sa_ids)
  project      = var.project_id
  account_id   = each.value
  display_name = each.value
  depends_on   = [google_project_service.apis]
}

locals {
  sa = { for k, v in google_service_account.this : k => v.email }

  project_roles = {
    # Least-privilege node identity (instead of the default Compute SA with Editor).
    "gke-nodes" = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
      "roles/monitoring.viewer",
      "roles/stackdriver.resourceMetadata.writer",
      "roles/autoscaling.metricsWriter",
    ]
    "plat-build" = ["roles/logging.logWriter", "roles/ondemandscanning.admin"]
    # Cloud Deploy runs render/deploy as this identity, not as a human or the default SA.
    "plat-deploy-exec" = [
      "roles/clouddeploy.jobRunner",
      "roles/clouddeploy.operator",
      "roles/container.developer",
      "roles/logging.logWriter",
    ]
    "plat-ci-plan" = [
      "roles/viewer",
      "roles/iam.securityReviewer",
      "roles/serviceusage.serviceUsageConsumer",
    ]
    "plat-ci-deploy" = [
      "roles/cloudbuild.builds.editor",
      "roles/clouddeploy.releaser",
      "roles/serviceusage.serviceUsageConsumer",
      "roles/logging.viewer",
    ]
  }

  role_pairs = flatten([for sa, roles in local.project_roles : [for r in roles : { sa = sa, role = r }]])
}

resource "google_project_iam_member" "this" {
  for_each = { for p in local.role_pairs : "${p.sa}:${p.role}" => p }
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${local.sa[each.value.sa]}"
}

# --- Delegation ---------------------------------------------------------------------------------
resource "google_service_account_iam_member" "act_as" {
  for_each = {
    for p in setproduct(
      ["user:${var.admin_email}", "serviceAccount:${local.sa["plat-ci-deploy"]}"],
      ["plat-build", "plat-deploy-exec"]
    ) : "${p[0]}>${p[1]}" => { member = p[0], sa = p[1] }
  }
  service_account_id = google_service_account.this[each.value.sa].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.member
}

# Cloud Deploy automation runs as the executor SA and must be able to act as itself.
resource "google_service_account_iam_member" "exec_self" {
  service_account_id = google_service_account.this["plat-deploy-exec"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.sa["plat-deploy-exec"]}"
}

resource "google_project_iam_member" "admin_deploy" {
  for_each = toset(["roles/clouddeploy.releaser", "roles/clouddeploy.approver", "roles/clouddeploy.viewer"])
  project  = var.project_id
  role     = each.value
  member   = "user:${var.admin_email}"
}
