variable "prefix" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

variable "image" {
  description = "Image OPNsense tự đưa lên (provision/gcp/gcp.sh image)"
  type        = string
}

variable "firewalls" {
  description = "Tên VM → { role (edge|core), type, nics [{ zone, ip }] theo thứ tự vtnet0..n }"
  type = map(object({
    role = string
    type = string
    nics = list(object({ zone = string, ip = string }))
  }))
}

variable "edge" {
  description = "Tên VM firewall biên (nhận IP public)"
  type        = string
}

variable "routes" {
  description = "Tên route → { zone (VPC), dest, next_hop (IP card firewall) }"
  type        = map(object({ zone = string, dest = string, next_hop = string }))
}

variable "vpn_port" { type = number }
variable "bootstrap_dir" {
  description = "Thư mục chứa opnsense-<vai>-bootstrap.xml (out/gcp/)"
  type        = string
}

variable "network_ids" { type = map(string) }
variable "wan_network_self_link" { type = string }
variable "subnet_ids" { type = map(string) }
