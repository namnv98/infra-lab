# VM Linux: Ubuntu 24.04, không IP public, user ubuntu + khoá SSH
resource "google_compute_instance" "vm" {
  for_each     = var.vms
  name         = each.key # tên VM = hostname = tên node K8s = tên trong inventory Ansible
  zone         = var.zone
  machine_type = each.value.type
  tags         = [each.value.zone]
  # Node K8s chuyển tiếp traffic Pod và nhận IP phụ (VIP, IP Gateway)
  can_ip_forward = each.value.zone == "lan"

  boot_disk {
    initialize_params {
      image = var.image
      size  = each.value.disk
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnet_ids[each.value.zone]
    network_ip = each.value.ip
    dynamic "alias_ip_range" {
      for_each = each.value.alias
      content { ip_cidr_range = alias_ip_range.value }
    }
  }

  metadata = {
    ssh-keys               = "ubuntu:${var.ssh_pubkey}"
    block-project-ssh-keys = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true
}
