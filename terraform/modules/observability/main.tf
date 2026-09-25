variable "project_id" { type = string }
variable "cluster_name" { type = string }
variable "alert_email" { type = string }
variable "lb_ip" { type = string }

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Platform on-call (email)"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

# --- Synthetic availability: external probe of the production route -------------------------
resource "google_monitoring_uptime_check_config" "prod" {
  project      = var.project_id
  display_name = "shop-prod via Gateway"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/healthz"
    port           = 80
    use_ssl        = false
    request_method = "GET"
  }
  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.project_id, host = var.lb_ip }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  project      = var.project_id
  display_name = "shop-prod - external uptime check failing"
  combiner     = "OR"
  conditions {
    display_name = "Uptime check failing for 3 minutes"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.prod.uptime_check_id}\" AND resource.type=\"uptime_url\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "180s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
}

# --- App SLO signal from Managed Prometheus (PromQL evaluated by Cloud Monitoring) ----------
resource "google_monitoring_alert_policy" "error_ratio" {
  project      = var.project_id
  display_name = "shop-prod - 5xx ratio above 5% for 5m (canary guard)"
  combiner     = "OR"
  conditions {
    display_name = "5xx / total > 5%"
    condition_prometheus_query_language {
      query               = "sum(rate(http_requests_total{namespace=\"shop-prod\",code=~\"5..\"}[2m])) / sum(rate(http_requests_total{namespace=\"shop-prod\"}[2m])) > 0.05"
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  documentation {
    mime_type = "text/markdown"
    content   = "A bad release is hurting users. `gcloud deploy rollouts` -> roll back / abandon the canary. Runbook: docs/runbooks/05-release-and-rollback.md"
  }
}

resource "google_monitoring_alert_policy" "restarts" {
  project      = var.project_id
  display_name = "GKE - container restart loop"
  combiner     = "OR"
  conditions {
    display_name = ">5 restarts in 10 minutes"
    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/container/restart_count\" AND resource.type=\"k8s_container\" AND resource.label.cluster_name=\"${var.cluster_name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"
      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
}

# --- Dashboard ---------------------------------------------------------------------------------
resource "google_monitoring_dashboard" "platform" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "GKE Platform - Golden Signals"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          xPos = 0, yPos = 0, width = 6, height = 4
          widget = {
            title = "shop-prod request rate by status (Managed Prometheus)"
            xyChart = {
              dataSets = [{
                plotType        = "STACKED_AREA"
                timeSeriesQuery = { prometheusQuery = "sum by (code) (rate(http_requests_total{namespace=\"shop-prod\"}[1m]))" }
              }]
            }
          }
        },
        {
          xPos = 6, yPos = 0, width = 6, height = 4
          widget = {
            title = "shop-prod latency p50 / p95 (seconds)"
            xyChart = {
              dataSets = [
                { plotType = "LINE", legendTemplate = "p50", timeSeriesQuery = { prometheusQuery = "histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{namespace=\"shop-prod\"}[2m])))" } },
                { plotType = "LINE", legendTemplate = "p95", timeSeriesQuery = { prometheusQuery = "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace=\"shop-prod\"}[2m])))" } },
              ]
            }
          }
        },
        {
          xPos = 0, yPos = 4, width = 6, height = 4
          widget = {
            title = "Pods per namespace (HPA scaling)"
            xyChart = {
              dataSets = [{
                plotType        = "LINE"
                timeSeriesQuery = { prometheusQuery = "sum by (namespace) (kube_pod_status_phase{namespace=~\"shop-.*\",phase=\"Running\"})" }
              }]
            }
          }
        },
        {
          xPos = 6, yPos = 4, width = 6, height = 4
          widget = {
            title = "Container CPU by namespace (cores)"
            xyChart = {
              dataSets = [{
                plotType        = "STACKED_AREA"
                timeSeriesQuery = { prometheusQuery = "sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~\"shop-.*|team-.*\",container!=\"\"}[2m]))" }
              }]
            }
          }
        },
      ]
    }
  })
}

output "notification_channel" { value = google_monitoring_notification_channel.email.id }
output "dashboard_id" { value = google_monitoring_dashboard.platform.id }
