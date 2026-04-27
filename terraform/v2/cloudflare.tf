# Cloudflare DNS record pointing the public hostname at Cloud Run.
#
# Cloud Run's legacy domain mapping returns DNS records to add manually; we
# automate that here. For a subdomain like `netcidr-v2.cloudreaper.dev`, a
# single CNAME to `ghs.googlehosted.com` is the right answer (Google routes
# by Host header). For an apex domain you'd need 4 A and 4 AAAA records
# instead — switch to the `cloudflare_record` `type = "A"`/`"AAAA"` resources
# if you ever map an apex domain.
#
# All resources here are no-ops when `cloudflare_zone_id` is empty.

resource "cloudflare_record" "netcidr_v2" {
  count = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id = var.cloudflare_zone_id
  name    = var.cloudflare_subdomain
  content = "ghs.googlehosted.com"
  type    = "CNAME"
  proxied = var.cloudflare_proxied
  ttl     = 1 # 1 = automatic; required when proxied = true

  comment = "Managed by terraform/v2 — points at Cloud Run service ${google_cloud_run_v2_service.netcidr.name} via legacy domain mapping."
}
