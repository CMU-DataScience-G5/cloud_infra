resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "gke" {
  name                     = "${var.name_prefix}-gke"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Nodes are private; Cloud NAT lets them pull public images (nvcr.io, docker.io, ghcr.io).
resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Static public IP for the Gateway's external HTTP(S) load balancer (GKE Ingress).
resource "google_compute_global_address" "gateway" {
  name = "${var.name_prefix}-gateway-ip"

  depends_on = [google_project_service.apis]
}

# Static public IPs for the Grafana and Kibana web UIs (one GKE Ingress each, since an
# Ingress can only route to Services in its own namespace).
resource "google_compute_global_address" "ui" {
  for_each = toset(["grafana", "kibana"])

  name = "${var.name_prefix}-${each.key}-ip"

  depends_on = [google_project_service.apis]
}
