# Cloudflare DNS record for the public hostname.
#
# Two strategies controlled by `var.use_cloud_run_domain_mapping`:
#
#   true  — Point Cloudflare at `ghs.googlehosted.com` and use a Cloud Run
#           legacy domain mapping (created in cloud_run.tf, gated on
#           var.custom_domain). Requires the caller to be a verified owner
#           of the domain in Google Search Console — see README.
#
#   false (default) — Point Cloudflare at the Cloud Run service's own
#           default URL (`<svc>-<hash>-<region>.run.app`). Cloud Run accepts
#           any Host header on its default URL, so we don't need a domain
#           mapping or Search Console ownership at all. Cloudflare proxy
#           must be ON (`cloudflare_proxied = true`) for this to work,
#           otherwise the browser sees the run.app cert mismatch.
#
# All resources here are no-ops when `cloudflare_zone_id` is empty.

locals {
  cloud_run_default_host = replace(google_cloud_run_v2_service.netcidr.uri, "https://", "")

  cloudflare_target = var.use_cloud_run_domain_mapping ? "ghs.googlehosted.com" : local.cloud_run_default_host
}

resource "cloudflare_record" "netcidr_v2" {
  count = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id = var.cloudflare_zone_id
  name    = var.cloudflare_subdomain
  content = local.cloudflare_target
  type    = "CNAME"
  proxied = var.cloudflare_proxied
  ttl     = 1 # 1 = automatic; required when proxied = true

  comment = var.use_cloud_run_domain_mapping ? "Managed by terraform/v2 — Cloud Run legacy domain mapping." : "Managed by terraform/v2 — Cloudflare → Cloud Run default URL (no GCP domain mapping)."
}
