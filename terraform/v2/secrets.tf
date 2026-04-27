locals {
  db_url = "postgresql://${google_sql_user.netcidr.name}:${random_password.db.result}@/${google_sql_database.netcidr.name}?host=/cloudsql/${google_sql_database_instance.netcidr.connection_name}"
}

resource "google_secret_manager_secret" "db_url" {
  project   = var.project
  secret_id = var.db_url_secret_name
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_url" {
  secret      = google_secret_manager_secret.db_url.id
  secret_data = local.db_url
}
