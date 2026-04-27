resource "google_artifact_registry_repository" "netcidr" {
  project       = var.project
  location      = var.region
  repository_id = var.artifact_repo
  description   = "Docker images for netcidr v2"
  format        = "DOCKER"
  labels        = var.labels

  depends_on = [google_project_service.apis]
}
