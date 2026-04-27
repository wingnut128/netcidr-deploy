resource "google_service_account" "runtime" {
  project      = var.project
  account_id   = "netcidr-v2-run"
  display_name = "netcidr v2 Cloud Run runtime"
  description  = "Single-purpose runtime identity for the netcidr v2 Cloud Run service."

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "build" {
  project      = var.project
  account_id   = "netcidr-v2-build"
  display_name = "netcidr v2 Cloud Build deployer"
  description  = "Single-purpose build identity for the Terraform-managed netcidr v2 Cloud Build trigger."

  depends_on = [google_project_service.apis]
}

# Runtime: read Cloud SQL via the in-Cloud-Run socket.
resource "google_project_iam_member" "runtime_cloudsql" {
  project = var.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Runtime: read the DB URL secret.
resource "google_secret_manager_secret_iam_member" "runtime_db_url" {
  project   = var.project
  secret_id = google_secret_manager_secret.db_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

# Build: push images to Artifact Registry.
resource "google_artifact_registry_repository_iam_member" "build_ar_writer" {
  project    = var.project
  location   = google_artifact_registry_repository.netcidr.location
  repository = google_artifact_registry_repository.netcidr.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

# Build: deploy new Cloud Run revisions.
resource "google_project_iam_member" "build_run_admin" {
  project = var.project
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Build: write Cloud Build logs.
resource "google_project_iam_member" "build_logs_writer" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Build: act as the runtime SA when deploying.
resource "google_service_account_iam_member" "build_act_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.build.email}"
}

# Public invoker — opt-in. Required when fronting Cloud Run with Cloudflare or
# any other public reverse proxy. Auth on /ipam/* is enforced inside netcidr.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count = var.enable_public_invoker ? 1 : 0

  project  = var.project
  location = google_cloud_run_v2_service.netcidr.location
  name     = google_cloud_run_v2_service.netcidr.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
