variable "project" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Run, Cloud SQL, Artifact Registry, Cloud Build."
  type        = string
  default     = "us-central1"
}

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "netcidr-v2"
}

variable "artifact_repo" {
  description = "Artifact Registry repository ID."
  type        = string
  default     = "netcidr-v2-repo"
}

variable "image_name" {
  description = "Docker image name within the Artifact Registry repository."
  type        = string
  default     = "netcidr-v2"
}

variable "sql_instance_name" {
  description = "Cloud SQL Postgres instance name."
  type        = string
  default     = "netcidr-v2-db"
}

variable "sql_database_name" {
  description = "Cloud SQL database name."
  type        = string
  default     = "netcidr"
}

variable "sql_user_name" {
  description = "Cloud SQL user name."
  type        = string
  default     = "netcidr"
}

variable "sql_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-f1-micro"
}

variable "db_url_secret_name" {
  description = "Secret Manager secret ID storing the Postgres connection URL."
  type        = string
  default     = "netcidr-v2-ipam-db-url"
}

variable "vpc_network" {
  description = "VPC network name to peer with Service Networking for Cloud SQL private IP."
  type        = string
  default     = "default"
}

variable "min_instances" {
  description = "Cloud Run minimum instance count."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Cloud Run maximum instance count."
  type        = number
  default     = 3
}

variable "deletion_protection" {
  description = "Enable deletion protection on the SQL instance, secret, and Cloud Run service."
  type        = bool
  default     = true
}

variable "bootstrap_image" {
  description = "Image used the first time the Cloud Run service is created. Cloud Build replaces it on the first build."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "oauth_web_client_id" {
  description = "Google OAuth 2.0 Web Client ID. Used as the OIDC audience the application validates ID tokens against."
  type        = string
}

variable "allowed_emails" {
  description = "Email allowlist gating /ipam/* access. Empty list = no allowlist enforcement."
  type        = list(string)
  default     = []
}

variable "enable_public_invoker" {
  description = "Grant roles/run.invoker to allUsers, making the Cloud Run service reachable from the open internet (e.g., for Cloudflare to proxy). Auth on /ipam/* is enforced inside the application."
  type        = bool
  default     = false
}

variable "custom_domain" {
  description = "Optional custom domain to map to the Cloud Run service. Leave null to skip."
  type        = string
  default     = null
}

variable "deploy_repo_connection" {
  description = "Cloud Build GitHub connection name (in the deploy region)."
  type        = string
  default     = "github-connection"
}

variable "deploy_repo_name" {
  description = "Cloud Build GitHub repository resource name."
  type        = string
  default     = "netcidr-deploy"
}

variable "deploy_repo_branch" {
  description = "Branch in the deploy repo whose cloudbuild-v2.yaml drives the build trigger."
  type        = string
  default     = "main"
}

variable "build_trigger_name" {
  description = "Cloud Build trigger name."
  type        = string
  default     = "netcidr-v2-build"
}

variable "netcidr_ref" {
  description = "Upstream netcidr git ref to build."
  type        = string
  default     = "v2"
}

variable "labels" {
  description = "Labels applied to project resources where supported."
  type        = map(string)
  default = {
    app        = "netcidr"
    stack      = "v2"
    managed_by = "terraform"
  }
}
