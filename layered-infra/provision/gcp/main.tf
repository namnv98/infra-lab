# BỘ TẠO MÁY cho GCP (tuỳ chọn, xoá cả provision/gcp/ được): chỉ dựng thứ GCP bắt buộc (VPC, route, VM, đĩa, IP public).
# Đầu vào: envs/gcp/plan.yml + out/gcp/opnsense-<vai>-bootstrap.xml (make fw-config).
# Đầu ra cho lớp cấu hình: máy chạy đúng IP trong plan + envs/gcp/provisioned.yml (IP public, gcp.sh ghi sau apply).
# File này chỉ đổi plan → tham số cho 3 module: network (VPC), firewall (OPNsense, IP public, route), vm (Linux).
locals {
  lab  = "${path.root}/../.."
  plan = yamldecode(file("${local.lab}/envs/gcp/plan.yml"))

  zones = { for k, v in local.plan.zones : k => { cidr = v.cidr } }
  mtu   = try(local.plan.mtu, 1460)

  firewalls = { for k, f in local.plan.firewalls : k => {
    role = f.role, type = f.type, nics = [for n in f.nics : { zone = n.zone, ip = n.ip }]
  } }

  # alias IP (VIP kube-vip, IP Gateway MetalLB): plan ghi TÊN trong k8s.*, đổi ra IP /32
  alias_ips = {
    api_vip          = local.plan.k8s.api_vip
    gateway_public   = local.plan.k8s.gateways.public.ip
    gateway_internal = local.plan.k8s.gateways.internal.ip
  }
  vms = { for k, h in local.plan.hosts : k => {
    zone  = h.zone, ip = h.ip, type = h.type, disk = h.disk
    alias = [for a in try(h.alias, []) : "${local.alias_ips[a]}/32"]
  } }

  # Route VPC: mỗi vùng trong có 0/0 → firewall của vùng (zones.*.fw); thêm route sang vùng khác (extra_routes)
  routes = merge(
    { for z, v in local.plan.zones : "${z}-default" => { zone = z, dest = "0.0.0.0/0", next_hop = v.fw } if can(v.fw) },
    { for r in local.plan.extra_routes : r.name => {
      zone     = r.in
      dest     = local.plan.zones[r.to].cidr
      next_hop = one([for n in local.plan.firewalls[r.via].nics : n.ip if n.zone == r.in])
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
  vpn_port              = local.plan.vpn.port
  bootstrap_dir         = "${local.lab}/out/gcp"
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
