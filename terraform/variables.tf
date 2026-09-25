variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "cluster_name" {
  type    = string
  default = "platform-eu"
}

variable "github_repo" {
  description = "owner/name of this repo: Argo CD syncs from it and CI federates from it."
  type        = string
  default     = "soodrajesh/gcp-gke-platform-engineering"
}

variable "billing_account_id" {
  type = string
}

variable "budget_amount" {
  type    = number
  default = 25
}

variable "alert_email" {
  type = string
}

variable "admin_email" {
  description = "Human operator: may create Cloud Deploy releases and impersonate the deploy executor."
  type        = string
}

variable "authorized_cidr" {
  description = "Your public IP as a /32. Only this range (plus Google Cloud public IPs for Cloud Deploy) can reach the Kubernetes API."
  type        = string
}

variable "resource_suffix" {
  description = "Appended to names GCP refuses to reuse after deletion (KMS key rings, WIF pools). scripts/up.sh generates one per deployment."
  type        = string
  default     = ""
}

variable "admission_allowlist" {
  description = "Image patterns exempt from the signed-image requirement (platform add-ons pulled from upstream registries)."
  type        = list(string)
  default = [
    "quay.io/argoproj/*",
    "public.ecr.aws/docker/library/*",
    "ecr-public.aws.com/docker/library/*",
    "registry.k8s.io/*",
    "gcr.io/gke-release/*",
    "gke.gcr.io/*",
    "gcr.io/google-containers/*",
    "europe-docker.pkg.dev/gke-release/*",
    "us-docker.pkg.dev/cloud-ops-agent-repository/*",
  ]
}
