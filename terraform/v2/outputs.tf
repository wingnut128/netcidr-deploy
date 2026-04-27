output "artifact_repository" {
  value = google_artifact_registry_repository.netcidr.repository_id
}

output "image" {
  description = "Latest-tagged image path. Cloud Build pushes here and updates Cloud Run."
  value       = "${local.target_image}:latest"
}

output "service_name" {
  value = google_cloud_run_v2_service.netcidr.name
}

output "service_uri" {
  value = google_cloud_run_v2_service.netcidr.uri
}

output "custom_domain_url" {
  value = var.custom_domain == null ? null : "https://${var.custom_domain}"
}

output "oidc_audience" {
  description = "Set this as NETCIDR_OIDC_AUDIENCE; this is the OAuth Web Client ID."
  value       = var.oauth_web_client_id
}

output "db_url_secret_name" {
  value = google_secret_manager_secret.db_url.secret_id
}

output "cloud_sql_connection_name" {
  value = google_sql_database_instance.netcidr.connection_name
}

output "build_trigger_name" {
  value = google_cloudbuild_trigger.netcidr.name
}

output "run_build_trigger_command" {
  description = "Convenience: kick the build trigger to push a real image."
  value       = "gcloud builds triggers run ${google_cloudbuild_trigger.netcidr.name} --branch=${var.deploy_repo_branch} --region=${var.region} --project=${var.project}"
}
