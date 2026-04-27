provider "google" {
  project = var.project
  region  = var.region
}

data "google_project" "current" {
  project_id = var.project
}

# Cloudflare API token. Reads `var.cloudflare_api_token` when set.
#
# The cloudflare provider rejects an empty/null api_token at validation
# time even when no resource references the provider, so when Cloudflare
# DNS management is disabled (cloudflare_zone_id == ""), we feed the
# provider a placeholder string. It's never used because every resource
# in cloudflare.tf is gated on `count = var.cloudflare_zone_id == "" ? 0 : 1`,
# but it satisfies the provider's "must provide exactly one of api_key,
# api_token, or api_user_service_key" schema check.
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : "unused-no-cloudflare-resources-active"
}
