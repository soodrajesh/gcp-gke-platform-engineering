variable "project_id" { type = string }

# Static global IP for the Gateway: survives Gateway re-creation, and the WAF/uptime check target.
resource "google_compute_global_address" "gateway" {
  project = var.project_id
  name    = "platform-gateway-ip"
}

# Cloud Armor edge policy, attached to backends with a GCPBackendPolicy (k8s/base/backendpolicy.yaml).
resource "google_compute_security_policy" "waf" {
  project     = var.project_id
  name        = "gke-platform-waf"
  description = "OWASP preconfigured rules + per-IP rate limit"

  rule {
    action      = "deny(403)"
    priority    = 1000
    description = "SQL injection (OWASP CRS, sensitivity 1)"
    match {
      expr { expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})" }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1001
    description = "Cross-site scripting (OWASP CRS, sensitivity 1)"
    match {
      expr { expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})" }
    }
  }

  rule {
    action      = "throttle"
    priority    = 2000
    description = "120 requests / minute / client IP"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 120
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "default"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
  }
}

output "ip_name" { value = google_compute_global_address.gateway.name }
output "ip_address" { value = google_compute_global_address.gateway.address }
output "waf_policy" { value = google_compute_security_policy.waf.name }
