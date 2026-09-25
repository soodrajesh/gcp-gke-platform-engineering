variable "project_id" { type = string }
variable "region" { type = string }
variable "suffix" {
  type    = string
  default = ""
}
variable "attester_members" {
  description = "Identities allowed to create attestations (the CI build service account)."
  type        = map(string)
}
variable "allowlist_patterns" { type = list(string) }

# --- Signing key (asymmetric, in KMS: the private key never leaves Google) ------------------
resource "google_kms_key_ring" "sign" {
  project  = var.project_id
  name     = "plat-binauthz${var.suffix}"
  location = var.region
}

resource "google_kms_crypto_key" "sign" {
  name     = "build-attestor"
  key_ring = google_kms_key_ring.sign.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "EC_SIGN_P256_SHA256"
    protection_level = "SOFTWARE"
  }
}

data "google_kms_crypto_key_version" "sign" {
  crypto_key = google_kms_crypto_key.sign.id
}

# --- Attestor: "this image was built by our pipeline" ------------------------------------------
resource "google_container_analysis_note" "build" {
  project = var.project_id
  name    = "built-by-pipeline"
  attestation_authority {
    hint { human_readable_name = "Built by the platform Cloud Build pipeline" }
  }
}

resource "google_binary_authorization_attestor" "build" {
  project = var.project_id
  name    = "built-by-pipeline"

  attestation_authority_note {
    note_reference = google_container_analysis_note.build.name
    public_keys {
      id = data.google_kms_crypto_key_version.sign.id
      pkix_public_key {
        public_key_pem      = data.google_kms_crypto_key_version.sign.public_key[0].pem
        signature_algorithm = data.google_kms_crypto_key_version.sign.public_key[0].algorithm
      }
    }
  }
}

resource "google_kms_crypto_key_iam_member" "sign" {
  for_each      = var.attester_members
  crypto_key_id = google_kms_crypto_key.sign.id
  role          = "roles/cloudkms.signerVerifier"
  member        = each.value
}

resource "google_binary_authorization_attestor_iam_member" "view" {
  for_each = var.attester_members
  project  = var.project_id
  attestor = google_binary_authorization_attestor.build.name
  role     = "roles/binaryauthorization.attestorsViewer"
  member   = each.value
}

resource "google_container_analysis_note_iam_member" "attach" {
  for_each = var.attester_members
  project  = var.project_id
  note     = google_container_analysis_note.build.name
  role     = "roles/containeranalysis.notes.attacher"
  member   = each.value
}

resource "google_project_iam_member" "occurrences" {
  for_each = var.attester_members
  project  = var.project_id
  role     = "roles/containeranalysis.occurrences.editor"
  member   = each.value
}

# --- Policy: deny anything that is not signed by our pipeline ------------------------------
# ENFORCED_BLOCK_AND_AUDIT_LOG: blocked at admission and written to Cloud Audit Logs.
resource "google_binary_authorization_policy" "this" {
  project                       = var.project_id
  global_policy_evaluation_mode = "ENABLE" # Google-maintained system images are exempt

  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = [google_binary_authorization_attestor.build.name]
  }

  dynamic "admission_whitelist_patterns" {
    for_each = var.allowlist_patterns
    content { name_pattern = admission_whitelist_patterns.value }
  }
}

output "attestor" { value = google_binary_authorization_attestor.build.name }
output "signing_key_version" { value = data.google_kms_crypto_key_version.sign.name }
output "note" { value = google_container_analysis_note.build.name }
