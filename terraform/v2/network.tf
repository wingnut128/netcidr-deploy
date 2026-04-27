data "google_compute_network" "vpc" {
  project = var.project
  name    = var.vpc_network
}

# Reserved IP range for Service Networking peering — Cloud SQL allocates its
# private IP from this range.
resource "google_compute_global_address" "sql_private_range" {
  project       = var.project
  name          = "netcidr-v2-sql-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.vpc.id
  labels        = var.labels

  depends_on = [google_project_service.apis]
}

# One-time peering between the VPC and Google Service Networking.
resource "google_service_networking_connection" "sql_private" {
  network                 = data.google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_private_range.name]

  depends_on = [google_project_service.apis]
}
