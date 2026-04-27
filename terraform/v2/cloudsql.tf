resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "netcidr" {
  project          = var.project
  region           = var.region
  name             = var.sql_instance_name
  database_version = "POSTGRES_16"

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.sql_tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true
    user_labels       = var.labels

    backup_configuration {
      enabled    = true
      start_time = "09:00"
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.vpc.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  depends_on = [
    google_project_service.apis,
    google_service_networking_connection.sql_private,
  ]

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_sql_database" "netcidr" {
  project  = var.project
  instance = google_sql_database_instance.netcidr.name
  name     = var.sql_database_name
}

resource "google_sql_user" "netcidr" {
  project  = var.project
  instance = google_sql_database_instance.netcidr.name
  name     = var.sql_user_name
  password = random_password.db.result
}
