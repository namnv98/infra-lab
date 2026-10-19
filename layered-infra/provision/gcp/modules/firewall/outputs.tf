output "fw_public_ip" { value = google_compute_address.fw_wan.address }
output "vpn_public_ip" { value = google_compute_address.vpn.address }
output "ips" { value = { for k, v in google_compute_instance.fw : k => join(" | ", [for n in v.network_interface : n.network_ip]) } }
output "routes" {
  description = "Route đã tạo — VM Linux chờ route có sẵn mới cài gói lúc khởi động"
  value       = [for r in google_compute_route.via_fw : r.id]
}
