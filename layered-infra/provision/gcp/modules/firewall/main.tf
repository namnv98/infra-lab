# 2 firewall OPNsense: biên (WAN có IP public + DMZ) và core (DMZ + LAN + MGMT), cửa vào từ Internet, route VPC qua firewall
data "google_compute_image" "opnsense" {
  name = var.image
}

resource "google_compute_instance" "fw" {
  for_each       = var.firewalls
  name           = each.key # tên VM = hostname = tên trong inventory; mạng/IP vẫn mang tiền tố var.prefix
  zone           = var.zone
  machine_type   = each.value.type
  tags           = each.value.role == "edge" ? ["fw"] : ["fw-core"] # chỉ biên nhận traffic từ Internet (wan_in)
  can_ip_forward = true                                             # firewall định tuyến giữa các vùng

  boot_disk {
    initialize_params {
      image = data.google_compute_image.opnsense.self_link
      size  = 10
      type  = "pd-balanced"
    }
  }

  dynamic "network_interface" {
    for_each = each.value.nics # thứ tự = vtnet0..n trong OPNsense
    content {
      subnetwork = var.subnet_ids[network_interface.value.zone]
      network_ip = network_interface.value.ip
      dynamic "access_config" {
        for_each = network_interface.value.zone == "wan" ? [1] : []
        content { nat_ip = google_compute_address.fw_wan.address }
      }
    }
  }

  metadata = {
    # Console nối tiếp: bootstrap lần đầu + cứu hộ (giống IPMI/iLO của máy thật)
    serial-port-enable = "TRUE"
    # config.xml bootstrap (scripts/opnsense-bootstrap.py <vai>): lần boot đầu nạp qua console, giống cắm USB chứa config ở on-prem.
    # make fw-config sinh file trước apply; thiếu file (máy mới, out/ trống) thì destroy vẫn chạy được
    opnsense-config = fileexists("${var.bootstrap_dir}/opnsense-${each.value.role}-bootstrap.xml") ? file("${var.bootstrap_dir}/opnsense-${each.value.role}-bootstrap.xml") : ""
  }

  allow_stopping_for_update = true
}

# ---------- Cửa vào từ Internet: 2 IP public của firewall biên ----------
#   IP web (NAT 1:1 → card WAN): chỉ tcp 80/443 · IP VPN (protocol forwarding): chỉ udp 51820
resource "google_compute_address" "fw_wan" {
  name   = "${var.prefix}-fw-wan"
  region = var.region
}

# IP VPN riêng: protocol forwarding GIỮ NGUYÊN IP đích → OPNsense phải có Virtual IP này trên WAN
# (role opnsense, ansible/network/host_vars/firewall-edge-01.yml) mới nhận gói.
resource "google_compute_address" "vpn" {
  name   = "${var.prefix}-vpn"
  region = var.region
}

resource "google_compute_target_instance" "fw_edge" {
  provider = google-beta
  name     = "${var.prefix}-fw-edge"
  zone     = var.zone
  instance = google_compute_instance.fw[var.edge].id
  # VM nhiều card: mặc định GCP đưa gói vào nic0 (= DMZ của biên) → phải chỉ rõ VPC của card WAN
  # API (beta) trả về URL dạng /compute/beta/... → ghi đúng dạng đó, không thì lần plan nào cũng đòi tạo lại
  network = replace(var.wan_network_self_link, "compute/v1/", "compute/beta/")
}

resource "google_compute_forwarding_rule" "vpn" {
  name                  = "${var.prefix}-vpn-wireguard"
  region                = var.region
  ip_address            = google_compute_address.vpn.address
  ip_protocol           = "UDP"
  port_range            = tostring(var.vpn_port)
  load_balancing_scheme = "EXTERNAL"
  target                = google_compute_target_instance.fw_edge.id
  # target instance đổi thì GCP không cho xoá khi rule còn trỏ vào → thay rule cùng lúc
  lifecycle { replace_triggered_by = [google_compute_target_instance.fw_edge.id] }
}

resource "google_compute_firewall" "wan_in" {
  name          = "${var.prefix}-wan-allow-web"
  network       = var.network_ids["wan"]
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["fw"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "wan_vpn" {
  name               = "${var.prefix}-wan-allow-vpn"
  network            = var.network_ids["wan"]
  direction          = "INGRESS"
  source_ranges      = ["0.0.0.0/0"]
  destination_ranges = ["${google_compute_address.vpn.address}/32"] # chỉ IP VPN mở cổng VPN, IP web thì không
  target_tags        = ["fw"]
  allow {
    protocol = "udp"
    ports    = [tostring(var.vpn_port)]
  }
}

# ---------- Route VPC: "default gateway" của vùng bên trong = card firewall ----------
resource "google_compute_route" "via_fw" {
  for_each    = var.routes
  name        = "${var.prefix}-${each.key}"
  network     = var.network_ids[each.value.zone]
  dest_range  = each.value.dest
  next_hop_ip = each.value.next_hop
  priority    = 100
  depends_on  = [google_compute_instance.fw]
}
