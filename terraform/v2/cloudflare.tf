# Cloudflare DNS + origin behavior for the public hostname.
#
# Two strategies controlled by `var.use_cloud_run_domain_mapping`:
#
#   true  — Point Cloudflare at `ghs.googlehosted.com` and use a Cloud Run
#           legacy domain mapping (created in cloud_run.tf, gated on
#           var.custom_domain). Cloud Run knows about the custom hostname,
#           so no Host-header rewrite is needed at the proxy. Requires the
#           caller to be a verified owner of the domain in Google Search
#           Console — see README.
#
#   false (default) — Point Cloudflare at the Cloud Run service's own
#           default URL (`<svc>-<project-num>.<region>.run.app`). Cloud
#           Run's frontend routes by Host header / SNI, so Cloudflare must
#           rewrite both to the run.app hostname before forwarding —
#           handled by the cloudflare_ruleset below. Cloudflare proxy must
#           be ON (cloudflare_proxied = true) for TLS termination at the
#           edge.
#
# All resources here are no-ops when `cloudflare_zone_id` is empty.

data "cloudflare_zone" "this" {
  count   = var.cloudflare_zone_id == "" ? 0 : 1
  zone_id = var.cloudflare_zone_id
}

locals {
  cloud_run_default_host = replace(google_cloud_run_v2_service.netcidr.uri, "https://", "")

  cloudflare_target = var.use_cloud_run_domain_mapping ? "ghs.googlehosted.com" : local.cloud_run_default_host

  cloudflare_fqdn = var.cloudflare_zone_id == "" ? "" : "${var.cloudflare_subdomain}.${data.cloudflare_zone.this[0].name}"
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

# Path B only: Cloudflare Origin Rule that rewrites Host header and SNI to
# the Cloud Run default hostname before the request leaves the proxy.
# Without this, Cloud Run's frontend sees Host = `<custom>.cloudreaper.dev`,
# can't find a service for that hostname, and returns 404.
resource "cloudflare_ruleset" "cloud_run_origin" {
  count = (var.cloudflare_zone_id == "" || var.use_cloud_run_domain_mapping) ? 0 : 1

  zone_id     = var.cloudflare_zone_id
  name        = "netcidr-v2 Cloud Run origin rewrite"
  description = "Rewrite Host header and SNI to Cloud Run's default hostname so requests proxied through Cloudflare route to the netcidr-v2 service."
  kind        = "zone"
  phase       = "http_request_origin"

  rules {
    action = "route"
    action_parameters {
      host_header = local.cloud_run_default_host
      sni {
        value = local.cloud_run_default_host
      }
    }
    expression  = "(http.host eq \"${local.cloudflare_fqdn}\")"
    description = "netcidr-v2 host + SNI rewrite"
    enabled     = true
  }
}
