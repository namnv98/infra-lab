# BỘ TẠO MÁY cho GCP (tuỳ chọn, xoá cả provision/gcp/ được): chỉ dựng thứ GCP bắt buộc (VPC, route, VM, đĩa, IP public).
# Đầu vào: ansible/shared/inventory/hosts.yml (inventory Ansible, viết tay) + out/opnsense-<vai>-bootstrap.xml (make fw-config).
# Đầu ra cho lớp cấu hình: máy chạy đúng IP trong hosts.yml + ansible/shared/inventory/provisioned.yml (IP public, gcp.sh ghi sau apply).
# File này chỉ đổi inventory → tham số cho 3 module: network (VPC), firewall (OPNsense, IP public, route), vm (Linux).
locals {
  lab = "${path.root}/../.."
  inv = yamldecode(file("${local.lab}/ansible/shared/inventory/hosts.yml")).all
  v   = local.inv.vars

  zones = { for k, z in local.v.zones : k => { cidr = z.cidr } }
  mtu   = try(local.v.lab_mtu, 1460)

  fw_hosts = local.inv.children.firewalls.hosts
  firewalls = { for k, f in local.fw_hosts : k => {
    role = f.fw_role, type = f.machine_type, nics = [for n in f.nics : { zone = n.zone, ip = n.ip }]
  } }

  # VM Linux: máy nằm trong nhóm con của linux, sâu tối đa 2 tầng (vd. linux → k8s → k8s_control_plane)
  linux = local.inv.children.linux.children
  linux_hosts = merge(
    merge([for g in values(local.linux) : try(g.hosts, {})]...),
    merge([for g in values(local.linux) : merge([for c in values(try(g.children, {})) : try(c.hosts, {})]...)]...)
  )

  # alias IP (VIP kube-vip, IP Gateway MetalLB): inventory ghi TÊN (gcp_alias), đổi ra IP /32
  alias_ips = {
    api_vip          = local.v.api_vip
    gateway_public   = local.v.gateways.public.ip
    gateway_internal = local.v.gateways.internal.ip
  }
  vms = { for k, h in local.linux_hosts : k => {
    zone  = h.zone, ip = h.ansible_host, type = h.machine_type, disk = h.disk_gb
    alias = [for a in try(h.gcp_alias, []) : "${local.alias_ips[a]}/32"]
  } }

  # Route VPC: mỗi vùng trong có 0/0 → firewall của vùng (zones.*.fw); thêm route sang vùng khác (extra_routes)
  routes = merge(
    { for z, zv in local.v.zones : "${z}-default" => { zone = z, dest = "0.0.0.0/0", next_hop = zv.fw } if can(zv.fw) },
    { for r in local.v.extra_routes : r.name => {
      zone     = r.in
      dest     = local.v.zones[r.to].cidr
      next_hop = one([for n in local.fw_hosts[r.via].nics : n.ip if n.zone == r.in])
    } }
  )
}

resource "google_project_service" "api" {
  for_each           = toset(["compute.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source     = "./modules/network"
  prefix     = var.prefix
  region     = var.region
  zones      = local.zones
  mtu        = local.mtu
  depends_on = [google_project_service.api]
}

module "firewall" {
  source                = "./modules/firewall"
  prefix                = var.prefix
  region                = var.region
  zone                  = var.zone
  image                 = var.opnsense_image
  firewalls             = local.firewalls
  edge                  = one([for k, f in local.firewalls : k if f.role == "edge"])
  routes                = local.routes
  vpn_port              = local.v.vpn.port
  bootstrap_dir         = "${local.lab}/out"
  network_ids           = module.network.network_ids
  wan_network_self_link = module.network.network_self_links["wan"]
  subnet_ids            = module.network.subnet_ids
  depends_on            = [google_project_service.api]
}

module "vm" {
  source     = "./modules/vm"
  zone       = var.zone
  vms        = local.vms
  subnet_ids = module.network.subnet_ids
  ssh_pubkey = trimspace(file(pathexpand(var.ssh_pubkey_file)))
  depends_on = [module.firewall] # VM cần OPNsense + route sẵn sàng để cài gói lúc khởi động
}
