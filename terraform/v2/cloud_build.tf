locals {
  target_image = "${var.region}-docker.pkg.dev/${var.project}/${var.artifact_repo}/${var.image_name}"

  cloud_build_repository = "projects/${var.project}/locations/${var.region}/connections/${var.deploy_repo_connection}/repositories/${var.deploy_repo_name}"
}

resource "google_cloudbuild_trigger" "netcidr" {
  project         = var.project
  location        = var.region
  name            = var.build_trigger_name
  description     = "Terraform-managed build and image rollout for upstream netcidr v2"
  service_account = google_service_account.build.id

  source_to_build {
    repository = local.cloud_build_repository
    ref        = "refs/heads/${var.deploy_repo_branch}"
    repo_type  = "GITHUB"
  }

  git_file_source {
    path       = "cloudbuild-v2.yaml"
    repository = local.cloud_build_repository
    revision   = "refs/heads/${var.deploy_repo_branch}"
    repo_type  = "GITHUB"
  }

  substitutions = {
    _REGION         = var.region
    _AR_REPO        = var.artifact_repo
    _IMAGE_NAME     = var.image_name
    _SERVICE_NAME   = var.service_name
    _NETCIDR_REF    = var.netcidr_ref
    _FEATURES       = "default,ipam-postgres"
    _WITH_DASHBOARD = "true"
  }

  depends_on = [
    google_artifact_registry_repository.netcidr,
    google_cloud_run_v2_service.netcidr,
    google_project_iam_member.build_run_admin,
    google_project_iam_member.build_logs_writer,
    google_artifact_registry_repository_iam_member.build_ar_writer,
    google_service_account_iam_member.build_act_as_runtime,
  ]
}
