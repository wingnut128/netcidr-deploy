provider "google" {
  project = var.project
  region  = var.region
}

data "google_project" "current" {
  project_id = var.project
}

# Cloudflare API token. Reads `var.cloudflare_api_token` if set; otherwise
# falls back to the CLOUDFLARE_API_TOKEN env var. Either source is fine on
# Spacelift — set the var (or env var) as a secret, not plain.
provider "cloudflare" {
  api_token = var.cloudflare_api_token == "" ? null : var.cloudflare_api_token
}
