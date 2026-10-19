# Chuyển từ tofu/main.tf (1 file) sang module (18/10/2026): báo cho tofu tài nguyên chỉ ĐỔI ĐỊA CHỈ, không tạo lại.
moved {
  from = google_compute_network.zone
  to   = module.network.google_compute_network.zone
}
moved {
  from = google_compute_subnetwork.zone
  to   = module.network.google_compute_subnetwork.zone
}
moved {
  from = google_compute_firewall.inside_in
  to   = module.network.google_compute_firewall.inside_in
}
moved {
  from = google_compute_firewall.dmz_web
  to   = module.network.google_compute_firewall.dmz_web
}
moved {
  from = google_compute_instance.fw
  to   = module.firewall.google_compute_instance.fw
}
moved {
  from = google_compute_address.fw_wan
  to   = module.firewall.google_compute_address.fw_wan
}
moved {
  from = google_compute_address.vpn
  to   = module.firewall.google_compute_address.vpn
}
moved {
  from = google_compute_target_instance.fw_edge
  to   = module.firewall.google_compute_target_instance.fw_edge
}
moved {
  from = google_compute_forwarding_rule.vpn
  to   = module.firewall.google_compute_forwarding_rule.vpn
}
moved {
  from = google_compute_firewall.wan_in
  to   = module.firewall.google_compute_firewall.wan_in
}
moved {
  from = google_compute_firewall.wan_vpn
  to   = module.firewall.google_compute_firewall.wan_vpn
}
moved {
  from = google_compute_route.via_fw
  to   = module.firewall.google_compute_route.via_fw
}
moved {
  from = google_compute_instance.vm
  to   = module.vm.google_compute_instance.vm
}
