resource "google_cloud_run_v2_service" "netcidr" {
  project  = var.project
  location = var.region
  name     = var.service_name

  ingress      = "INGRESS_TRAFFIC_ALL"
  launch_stage = "BETA"
  labels       = var.labels

  deletion_protection = var.deletion_protection

  template {
    service_account                  = google_service_account.runtime.email
    timeout                          = "30s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.netcidr.connection_name]
      }
    }

    containers {
      image = var.bootstrap_image
      args  = ["serve", "--address", "0.0.0.0", "--port", "8080", "--config", "/app/netcidr.toml"]

      ports {
        container_port = 8080
      }

      env {
        name  = "RUST_LOG"
        value = "info"
      }

      env {
        name  = "NETCIDR_OIDC_AUDIENCE"
        value = var.oauth_web_client_id
      }

      env {
        name  = "NETCIDR_OIDC_ALLOWED_EMAILS"
        value = join(",", var.allowed_emails)
      }

      env {
        name = "NETCIDR_IPAM_DB_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_url.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  depends_on = [
    google_sql_database.netcidr,
    google_sql_user.netcidr,
    google_secret_manager_secret_version.db_url,
  ]

  # Cloud Build owns the image; once the first real image lands, Terraform
  # leaves it alone on subsequent applies. Same shape as the previous Pulumi
  # `ignoreChanges` arrangement.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_domain_mapping" "netcidr" {
  count = var.custom_domain == null ? 0 : 1

  project  = var.project
  location = var.region
  name     = var.custom_domain

  metadata {
    namespace = var.project
    labels    = var.labels
  }

  spec {
    route_name       = google_cloud_run_v2_service.netcidr.name
    certificate_mode = "AUTOMATIC"
  }
}
