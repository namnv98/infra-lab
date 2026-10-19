#!/usr/bin/env python3
"""Đọc inventory Ansible của lab (ansible/shared/inventory/hosts.yml, viết tay) cho script ngoài Ansible.
Không sinh gì — chỉ đọc. Bộ tạo máy (vd. provision/gcp) ghi thêm provisioned.yml cạnh hosts.yml (IP public) — gộp đè lên.

Dùng như thư viện (opnsense-bootstrap.py, gcp.sh) hoặc lệnh cho shell (lab.sh, harbor-prewarm.sh, smoke.sh):
  inventory.py check                 kiểm tra hosts.yml (IP trong dải, không trùng, không dùng IP GCP giữ, số card ≤ vCPU)
  inventory.py get jump_ip           IP của máy nhóm bastion
  inventory.py get host_ip <tên>     IP của 1 VM
  inventory.py get vpn_allowed_ips   AllowedIPs cho máy admin (các vùng trong, tách /25 + dải VPN)
  inventory.py get dns               DNS nội bộ cho máy admin (card LAN của core)
  inventory.py get group_ip <nhóm>   IP máy đầu tiên của 1 nhóm (vd. infra, k8s_control_plane)
  inventory.py get vpn_admin         IP máy admin trong VPN
  inventory.py get vpn_port          cổng WireGuard
  inventory.py get fw_names          tên các firewall
  inventory.py get ssh_hosts         "tên IP" từng VM Linux (lab.sh sinh out/ssh_config)
  inventory.py get fw_gui            GUI của các firewall (card mặc định của từng vùng có fw), cách nhau bởi dấu cách
  inventory.py get public_web|public_vpn  IP public của firewall biên: web (80/443) · VPN (Endpoint WireGuard)
"""
import ipaddress, pathlib, sys
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
INV = ROOT / "ansible" / "shared" / "inventory" / "hosts.yml"
VCPU = {"e2-micro": 2, "e2-small": 2, "e2-medium": 2, "e2-standard-2": 2, "e2-highcpu-4": 4, "e2-standard-4": 4}


def _hosts(group, groups=()):
    """Duyệt cây nhóm của inventory YAML: (tên máy, biến máy, các nhóm chứa nó)."""
    for name, h in (group.get("hosts") or {}).items():
        yield name, h or {}, list(groups)
    for g, sub in (group.get("children") or {}).items():
        yield from _hosts(sub or {}, (*groups, g))


def load():
    """hosts.yml (+ provisioned.yml) → dict gọn cho script: zones, firewalls, hosts, k8s, vpn, mtu, domain, public…"""
    inv = yaml.safe_load(INV.read_text())["all"]
    v = dict(inv.get("vars") or {})
    prov = INV.with_name("provisioned.yml")
    if prov.exists():
        v.update(((yaml.safe_load(prov.read_text()) or {}).get("all") or {}).get("vars") or {})
    p = {"platform": v.get("lab_hosting", "gcp"), "domain": v["lab_domain"], "mtu": v.get("lab_mtu", 1500),
         "node": {"interface": v.get("node_interface"), "network": v.get("node_network_mode"), "ntp": v.get("ntp_client")},
         "zones": v["zones"], "extra_routes": v.get("extra_routes", []), "vpn": v["vpn"],
         "k8s": {"api_vip": v["api_vip"], "gateways": v["gateways"], "metallb_pools": v.get("metallb_pools", {})},
         "public": {k: v[f] for k, f in (("web", "fw_public_ip"), ("vpn", "vpn_public_ip")) if v.get(f)},
         "firewalls": {}, "hosts": {}}
    for name, h, groups in _hosts(inv):
        if "firewalls" in groups:
            p["firewalls"][name] = {"role": h["fw_role"], "type": h.get("machine_type"), "dns": h["fw_dns"], "nics": h["nics"]}
        elif "linux" in groups:
            p["hosts"][name] = {"ip": h["ansible_host"], "zone": h["zone"], "groups": groups[-1:], "type": h.get("machine_type"),
                                "disk": h.get("disk_gb"), "alias": h.get("gcp_alias", [])}
    return p


def host_in_group(p, group):
    return [n for n, h in p["hosts"].items() if group in h["groups"]]


def nic(p, fw, zone):
    """IP card của firewall `fw` trong vùng `zone`."""
    return next(n["ip"] for n in p["firewalls"][fw]["nics"] if n["zone"] == zone)


def halves(cidr):
    """/24 → 2 nửa /25: cụ thể hơn route /24 của lab local (virbr) nên đi qua VPN khi VPN bật."""
    return [str(s) for s in ipaddress.ip_network(cidr).subnets(prefixlen_diff=1)]


def check(p):
    errs, seen = [], {}
    gcp = p.get("platform", "gcp") == "gcp"
    zones = {z: ipaddress.ip_network(v["cidr"]) for z, v in p["zones"].items()}

    def use(ip, zone, who):
        a = ipaddress.ip_address(ip)
        if zone and a not in zones[zone]:
            errs.append(f"{who}: {ip} không nằm trong vùng {zone} ({zones[zone]})")
        off = int(a) - int(zones[zone].network_address) if zone else None
        if zone and gcp and off in (0, 1, 254, 255):
            errs.append(f"{who}: {ip} là IP GCP giữ (.0 .1 .254 .255)")
        if zone and not gcp and (a == zones[zone].network_address or a == zones[zone].broadcast_address):
            errs.append(f"{who}: {ip} là địa chỉ mạng/broadcast")
        if ip in seen and seen[ip] != who:
            errs.append(f"{who}: {ip} trùng với {seen[ip]}")
        seen[ip] = who

    node = p.get("node", {})
    if not node.get("interface"):
        errs.append("node_interface: thiếu tên card mạng chính của VM Linux (vd. ens4, enp1s0)")
    if node.get("network") not in ("dhcp", "static"):
        errs.append("node_network_mode: phải là dhcp hoặc static")
    if node.get("ntp") not in ("chrony", "systemd-timesyncd"):
        errs.append("ntp_client: phải là chrony hoặc systemd-timesyncd")
    for k, ip in p.get("public", {}).items():
        if k not in ("web", "vpn"):
            errs.append(f"public.{k}: chỉ có web, vpn")
        else:
            ipaddress.ip_address(ip)
    for z, v in p["zones"].items():
        if gcp and ipaddress.ip_address(v["gateway"]) != zones[z].network_address + 1:
            errs.append(f"vùng {z}: gateway {v['gateway']} phải là .1 (GCP)")
        if not gcp and "fw" in v and v["fw"] != v["gateway"]:
            errs.append(f"vùng {z}: on-prem thì firewall ({v['fw']}) chính là gateway ({v['gateway']})")
    for fw, f in p["firewalls"].items():
        if gcp and len(f["nics"]) > VCPU.get(f["type"], 0):
            errs.append(f"{fw}: {len(f['nics'])} card > {VCPU.get(f['type'])} vCPU của {f['type']}")
        for n in f["nics"]:
            use(n["ip"], n["zone"], f"{fw}/{n['zone']}")
        if sum(1 for n in f["nics"] if n.get("default_gw")) != 1:
            errs.append(f"{fw}: cần đúng 1 card default_gw")
    for z, v in p["zones"].items():
        if "fw" in v and not any(n["ip"] == v["fw"] for f in p["firewalls"].values() for n in f["nics"]):
            errs.append(f"vùng {z}: fw {v['fw']} không phải card của firewall nào")
    for n, h in p["hosts"].items():
        use(h["ip"], h["zone"], n)
        for a in h.get("alias", []):
            ip = alias_ip(p, a)
            if ip is None:
                errs.append(f"{n}: gcp_alias '{a}' không phải api_vip/gateway_public/gateway_internal")
            else:
                use(ip, h["zone"], f"{n}/alias {a}")
    for r in p["extra_routes"]:
        try:
            nic(p, r["via"], r["in"])
        except StopIteration:
            errs.append(f"route {r['name']}: {r['via']} không có card trong vùng {r['in']}")
    return errs


def alias_ip(p, name):
    k = p["k8s"]
    return {"api_vip": k["api_vip"], "gateway_public": k["gateways"]["public"]["ip"],
            "gateway_internal": k["gateways"]["internal"]["ip"]}.get(name)


def get(p, key, *args):
    if key == "jump_ip":
        return p["hosts"][host_in_group(p, "bastion")[0]]["ip"]
    if key == "host_ip":
        return p["hosts"][args[0]]["ip"]
    if key == "vpn_allowed_ips":
        nets = [h for z, v in p["zones"].items() if "fw" in v for h in halves(v["cidr"])] + [p["vpn"]["cidr"]]
        return ", ".join(nets)
    if key == "dns":
        return p["zones"]["lan"]["fw"]
    if key == "group_ip":
        return p["hosts"][host_in_group(p, args[0])[0]]["ip"]
    if key == "ssh_hosts":
        return "\n".join(f"{n} {h['ip']}" for n, h in p["hosts"].items())
    if key == "fw_names":     # tên 2 firewall (cách nhau dấu cách)
        return " ".join(p["firewalls"])
    if key == "group_hosts":   # tên các máy trong nhóm (cách nhau dấu cách)
        return " ".join(host_in_group(p, args[0]))
    if key == "start_order":   # thứ tự bật máy, mỗi dòng 1 tầng (tắt: ngược lại) — tầng sau cần tầng trước chạy
        tiers = [list(p["firewalls"])]
        for g in ("bastion", "infra", "k8s_control_plane", "k8s_workers"):
            tiers.append(host_in_group(p, g))
        done = {n for t in tiers for n in t}
        tiers.append([n for n in p["hosts"] if n not in done])   # còn lại: edge-01, siem-01…
        return "\n".join(" ".join(t) for t in tiers if t)
    if key == "domain":      # tên miền nội bộ (lab.internal)
        return p["domain"]
    if key == "gw_domain":   # tên miền của Gateway K8s: public | internal
        return p["k8s"]["gateways"][args[0]]["domain"]
    if key == "vpn_admin":
        return p["vpn"]["admin"]
    if key == "vpn_port":
        return p["vpn"]["port"]
    if key == "fw_gui":   # biên: card DMZ; core: card LAN (theo thứ tự xuất hiện, bỏ trùng)
        return " ".join(dict.fromkeys(p["zones"][z]["fw"] for z in ("dmz", "lan")))
    if key in ("public_web", "public_vpn"):
        ip = p.get("public", {}).get(key.split("_")[1])
        if not ip:
            sys.exit(f"thiếu IP public ({key}): bộ tạo máy (make provision) ghi vào "
                     f"{INV.with_name('provisioned.yml').relative_to(ROOT)}, máy có sẵn thì ghi tay fw_public_ip/vpn_public_ip vào "
                     f"{INV.relative_to(ROOT)}")
        return ip
    sys.exit(f"không biết khoá: {key}")


if __name__ == "__main__":
    p = load()
    if sys.argv[1:2] == ["check"]:
        e = check(p)
        print("\n".join(e) if e else f"OK: {INV.relative_to(ROOT)} hợp lệ")
        sys.exit(1 if e else 0)
    if sys.argv[1:2] == ["get"]:
        print(get(p, *sys.argv[2:]))
    else:
        sys.exit(__doc__)
