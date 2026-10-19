# Mạng: mỗi vùng 1 VPC + subnet; firewall của VPC chỉ mở tối thiểu, lọc thật nằm ở OPNsense
resource "google_compute_network" "zone" {
  for_each                = var.zones
  name                    = "${var.prefix}-${each.key}"
  auto_create_subnetworks = false
  mtu                     = var.mtu
  # Vùng bên trong không có đường ra Internet của GCP: mọi traffic ra ngoài phải qua OPNsense
  delete_default_routes_on_create = each.key != "wan"
}

resource "google_compute_subnetwork" "zone" {
  for_each      = var.zones
  name          = "${var.prefix}-${each.key}"
  region        = var.region
  network       = google_compute_network.zone[each.key].id
  ip_cidr_range = each.value.cidr
}

# Vùng bên trong: cho mọi traffic nội bộ (10/8, gồm cả VPN 10.50) — OPNsense quyết định cho/chặn giữa các vùng
resource "google_compute_firewall" "inside_in" {
  for_each      = { for k, v in var.zones : k => v if k != "wan" }
  name          = "${var.prefix}-${each.key}-allow-internal"
  network       = google_compute_network.zone[each.key].id
  direction     = "INGRESS"
  source_ranges = ["10.0.0.0/8"]
  allow { protocol = "all" }
}

# DMZ: OPNsense port forward giữ IP thật của client → HAProxy nhận traffic từ mọi IP Internet
resource "google_compute_firewall" "dmz_web" {
  name          = "${var.prefix}-dmz-allow-web"
  network       = google_compute_network.zone["dmz"].id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}
