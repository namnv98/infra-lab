output "fw_public_ip" {
  description = "IP web (firewall biên, NAT 1:1): tcp 80/443"
  value       = module.firewall.fw_public_ip
}

output "vpn_public_ip" {
  description = "IP VPN (protocol forwarding → firewall biên): udp cổng VPN — Endpoint WireGuard của máy admin"
  value       = module.firewall.vpn_public_ip
}

output "vms" {
  value = merge(module.firewall.ips, module.vm.ips)
}
