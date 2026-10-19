output "network_ids" { value = { for k, v in google_compute_network.zone : k => v.id } }
output "network_self_links" { value = { for k, v in google_compute_network.zone : k => v.self_link } }
output "subnet_ids" { value = { for k, v in google_compute_subnetwork.zone : k => v.id } }
