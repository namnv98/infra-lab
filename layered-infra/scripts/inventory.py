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
  inventory.py get admin_ip          IP máy admin như firewall biên thấy (admin_public_ip; trống = tự dò IP public)
  inventory.py get zone_list         "vùng dải gateway vlan" từng vùng (vlan "-" nếu không có; bộ tạo máy dựng mạng)
  inventory.py get sw_list           tên các switch Open vSwitch (lab_switches; trống = mỗi vùng 1 bridge riêng)
  inventory.py get sw_ports <switch> "access <vùng> <vlan>" · "trunk trunk-<firewall> <vlan,…>"
                                     · "uplink <switch kia> <vlan,…> lacp|rstp <veth này:veth kia:số cổng,…>"
  inventory.py get sw_stp <switch>   ưu tiên RSTP (stp_priority, mặc định 32768)
  inventory.py get sw_mgmt           "switch card IP/prefix gateway vlan số-thứ-tự IP-siem" từng switch có IP quản trị
  inventory.py get host_sw <vùng>    switch mà VM của vùng cắm vào ("-" nếu không có: mạng riêng lab-<vùng>)
  inventory.py get zone_sw <vùng>    switch đầu tiên có vùng này (VM hoặc firewall); "-" = mạng riêng lab-<vùng>
  inventory.py get fw_ports <tên>    "card trunk|access vùng,… IP,… switch|-" từng card vật lý của firewall (thứ tự = vtnet0..n)
  inventory.py get vm_list           "tên fw|linux vCPU RAM(MiB) đĩa(GB) vùng,… IP,…" từng máy (vcpus/ram_mb/disk_gb)
  inventory.py get host_net <tên>    "IP/prefix gateway DNS" của 1 VM Linux (cloud-init lần boot đầu)
  inventory.py get zone_fw <vùng>    card firewall của vùng (gateway của máy on-prem, DNS/NTP của máy trong vùng)
  inventory.py get host_routes <tên> "dải qua" từng route extra_routes của vùng máy đó (on-prem: route tĩnh trên máy)
  inventory.py get fw_role <tên>     vai của firewall: edge | core
  inventory.py get lab_image_dir     thư mục image OS gốc của bộ tạo máy (lab_image_dir)
  inventory.py get mtu|node_interface
"""
import ipaddress, os, pathlib, sys
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
INV = ROOT / "ansible" / "shared" / "inventory" / "hosts.yml"
# LAB_PROVISIONED: gộp 1 file khác thay provisioned.yml (vd. bộ tạo máy nhà dọn máy khi ansible/ đang dùng GCP)
PROV = pathlib.Path(os.environ.get("LAB_PROVISIONED") or INV.with_name("provisioned.yml"))
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
    if PROV.exists():
        v.update(((yaml.safe_load(PROV.read_text()) or {}).get("all") or {}).get("vars") or {})
    p = {"platform": v.get("lab_hosting", "gcp"), "domain": v["lab_domain"], "mtu": v.get("lab_mtu", 1500),
         "node": {"interface": v.get("node_interface"), "network": v.get("node_network_mode"), "ntp": v.get("ntp_client")},
         "zones": v["zones"], "extra_routes": v.get("extra_routes", []), "vpn": v["vpn"],
         "k8s": {"api_vip": v["api_vip"], "gateways": v["gateways"], "metallb_pools": v.get("metallb_pools", {})},
         "public": {k: v[f] for k, f in (("web", "fw_public_ip"), ("vpn", "vpn_public_ip")) if v.get(f)},
         "admin_ip": v.get("admin_public_ip"), "image_dir": v.get("lab_image_dir", ""),
         "switches": v.get("lab_switches") or {},
         "firewalls": {}, "hosts": {}}
    for name, h, groups in _hosts(inv):
        if "firewalls" in groups:
            p["firewalls"][name] = {"role": h["fw_role"], "type": h.get("machine_type"), "dns": h["fw_dns"], "nics": h["nics"],
                                    "vcpus": h.get("vcpus"), "ram_mb": h.get("ram_mb"), "disk": h.get("disk_gb", 10)}
        elif "linux" in groups:
            p["hosts"][name] = {"ip": h["ansible_host"], "zone": h["zone"], "groups": groups[-1:], "type": h.get("machine_type"),
                                "disk": h.get("disk_gb"), "alias": h.get("gcp_alias", []),
                                "vcpus": h.get("vcpus"), "ram_mb": h.get("ram_mb")}
    return p


def host_in_group(p, group):
    return [n for n, h in p["hosts"].items() if group in h["groups"]]


def nic(p, fw, zone):
    """IP card của firewall `fw` trong vùng `zone`."""
    return next(n["ip"] for n in p["firewalls"][fw]["nics"] if n["zone"] == zone)


def sw_of(p, zone, kind):
    """Switch (lab_switches) mà card firewall (kind=fw) hoặc VM (kind=hosts) của vùng cắm vào; None = mạng riêng của vùng."""
    return next((s for s, v in p["switches"].items() if zone in (v.get(kind) or [])), None)


def uplinks(p, sw):
    """Uplink của 1 switch, khai ở đầu nào cũng được: {switch kia: {vlans: [vùng cho qua], links: số dây, lacp: gộp dây?}}.
    Khai gọn [vùng,…] = 1 dây. Nhiều dây: lacp (mặc định) = gộp thành 1 cổng logic; lacp: false = dây riêng, RSTP chặn dây thừa."""
    def norm(u):
        u = {"vlans": u} if isinstance(u, list) else dict(u)
        u.setdefault("links", 1)
        u["lacp"] = u.get("lacp", True) and u["links"] > 1
        return u
    out = {peer: norm(u) for peer, u in (p["switches"][sw].get("uplink") or {}).items()}
    out.update({s: norm(v["uplink"][sw]) for s, v in p["switches"].items() if sw in (v.get("uplink") or {})})
    return out


def short(sw):
    """Tên ngắn của switch cho tên card Linux (≤ 15 ký tự): sw-core → core."""
    return sw.removeprefix("sw-")


def uplink_ifs(sw, peer, links):
    """Dây uplink = cặp veth: [(đầu ở sw, đầu ở peer)], vd. core-access1 ↔ access-core1."""
    return [(f"{short(sw)}-{short(peer)}{i}", f"{short(peer)}-{short(sw)}{i}") for i in range(1, links + 1)]


def mgmt_zone(p, ip):
    """Vùng chứa IP quản trị của switch."""
    a = ipaddress.ip_address(ip)
    return next((z for z, v in p["zones"].items() if a in ipaddress.ip_network(v["cidr"])), None)


def sw_vlans(p, sw):
    """Vùng có mặt trên switch: card firewall, VM, hoặc đi qua uplink."""
    v = p["switches"][sw]
    return set((v.get("fw") or []) + (v.get("hosts") or []) + [z for u in uplinks(p, sw).values() for z in u["vlans"]])


def fw_ports(p, fw):
    """Card vật lý của firewall theo thứ tự (= vtnet0..n): [{dev, trunk, nics, sw}]. Các nic cắm cùng 1 switch gom vào 1 card
    (đặt ở vị trí nic đầu tiên): từ 2 vùng trở lên là card trunk (interface VLAN), 1 vùng là card thường cắm cổng access."""
    ports = []
    for n in p["firewalls"][fw]["nics"]:
        sw = sw_of(p, n["zone"], "fw")
        x = next((x for x in ports if sw and x["sw"] == sw), None)
        if x is None:
            ports.append({"sw": sw, "nics": [n]})
        else:
            x["nics"].append(n)
    for i, x in enumerate(ports):
        x["trunk"] = len(x["nics"]) > 1
        x["dev"] = x["nics"][0].get("dev", f"vtnet{i}") if not x["trunk"] else f"vtnet{i}"
    return ports


def nic_dev(p, fw, n):
    """Thiết bị FreeBSD của 1 nic: card riêng (vtnet<i>) hoặc VLAN trên card trunk (vtnet<i>_vlan<tag>, cách đặt tên của OPNsense)."""
    for x in fw_ports(p, fw):
        if n in x["nics"]:
            return f"{x['dev']}_vlan{p['zones'][n['zone']]['vlan']}" if x["trunk"] else x["dev"]


def gateway(p, zone):
    """Gateway mặc định của máy trong vùng: GCP = .1 của VPC · on-prem = card firewall của vùng (không có router .1)."""
    z = p["zones"][zone]
    return z["gateway"] if p["platform"] == "gcp" else z.get("fw", z["gateway"])


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
    vlans = [v["vlan"] for v in p["zones"].values() if "vlan" in v]
    if len(vlans) != len(set(vlans)) or not all(isinstance(t, int) and 1 <= t <= 4094 for t in vlans):
        errs.append(f"vlan của các vùng phải là số 1–4094, không trùng: {vlans}")
    errs += check_switches(p, gcp)
    for s, v in p["switches"].items():
        if v.get("mgmt") and mgmt_zone(p, v["mgmt"]):
            use(v["mgmt"], mgmt_zone(p, v["mgmt"]), f"lab_switches.{s}/mgmt")
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


def check_switches(p, gcp):
    """lab_switches: vùng có vlan, mỗi vùng cắm ở tối đa 1 switch cho firewall và 1 switch cho VM; switch của VM phải là
    switch của firewall hoặc nối thẳng tới nó bằng uplink cho vùng đó đi qua (không thì VM không tới được gateway)."""
    errs, sws = [], p["switches"]
    if sws and gcp:
        return ["lab_switches: GCP không có switch/VLAN (mỗi vùng 1 VPC)"]
    for kind in ("fw", "hosts"):
        for z in p["zones"]:
            on = [s for s, v in sws.items() if z in (v.get(kind) or [])]
            if len(on) > 1:
                errs.append(f"lab_switches: vùng {z} có {kind} ở nhiều switch {on}")
    for s, v in sws.items():
        for peer, u in (v.get("uplink") or {}).items():
            if peer not in sws:
                errs.append(f"lab_switches.{s}: uplink tới switch lạ {peer}")
            elif not isinstance(u, list) and not (isinstance(u.get("links", 1), int) and 1 <= u.get("links", 1) <= 4):
                errs.append(f"lab_switches.{s}.uplink.{peer}: links phải là số 1–4")
        if errs:
            return errs
        for z in sw_vlans(p, s):
            if z not in p["zones"] or not p["zones"][z].get("vlan"):
                errs.append(f"lab_switches.{s}: vùng {z} không có hoặc thiếu vlan")
        for peer, u in uplinks(p, s).items():
            if any(len(n) > 15 for pair in uplink_ifs(s, peer, u["links"]) for n in pair):
                errs.append(f"lab_switches: tên {s}/{peer} dài quá (tên card veth ≤ 15 ký tự)")
        if v.get("mgmt"):
            z = mgmt_zone(p, v["mgmt"])
            if z is None or z not in sw_vlans(p, s):
                errs.append(f"lab_switches.{s}: mgmt {v['mgmt']} phải thuộc 1 vùng có trên switch này")
            if len(f"{short(s)}-mgmt") > 15:
                errs.append(f"lab_switches: tên {s} dài quá (tên card {short(s)}-mgmt ≤ 15 ký tự)")
        prio = v.get("stp_priority", 32768)
        if not (isinstance(prio, int) and 0 <= prio <= 61440 and prio % 4096 == 0):
            errs.append(f"lab_switches.{s}: stp_priority phải là bội của 4096, 0–61440")
    if errs:
        return errs
    for z in p["zones"]:
        hs, fs = sw_of(p, z, "hosts"), sw_of(p, z, "fw")
        if hs and hs != fs and z not in uplinks(p, hs).get(fs, {}).get("vlans", []):
            errs.append(f"lab_switches: VM vùng {z} ở {hs}, firewall ở {fs or '(không switch)'} — cần uplink {hs} ↔ {fs} cho {z} đi qua")
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
                     f"{PROV.relative_to(ROOT)}, máy có sẵn thì ghi tay fw_public_ip/vpn_public_ip vào "
                     f"{INV.relative_to(ROOT)}")
        return ip
    if key == "admin_ip":
        return p.get("admin_ip") or ""
    if key == "zone_list":
        return "\n".join(f"{z} {v['cidr']} {v['gateway']} {v.get('vlan', '-')}" for z, v in p["zones"].items())
    if key == "sw_list":
        return " ".join(p["switches"])
    if key == "sw_ports":   # portgroup (cổng access của từng vùng, trunk của từng firewall) + uplink của 1 switch
        sw, vl = args[0], lambda zs: ",".join(str(p["zones"][z]["vlan"]) for z in zs)
        v = p["switches"][sw]
        rows = [f"access {z} {p['zones'][z]['vlan']}" for z in dict.fromkeys((v.get("fw") or []) + (v.get("hosts") or []))]
        rows += [f"trunk trunk-{f} {vl([n['zone'] for n in x['nics']])}"
                 for f in p["firewalls"] for x in fw_ports(p, f) if x["sw"] == sw and x["trunk"]]
        # dây uplink cắm các cổng cuối, cố định (như uplink 47–48 của switch 48 cổng); cổng VM do OVS cấp từ 1 theo thứ tự cắm
        ups = [(peer, u, a, b) for peer, u in uplinks(p, sw).items() for a, b in uplink_ifs(sw, peer, u["links"])]
        port = {a: 49 - len(ups) + i for i, (_, _, a, _) in enumerate(ups)}
        rows += [f"uplink {peer} {vl(u['vlans'])} {'lacp' if u['lacp'] else 'rstp'} "
                 f"{','.join(f'{a}:{b}:{port[a]}' for a, b in uplink_ifs(sw, peer, u['links']))}" for peer, u in uplinks(p, sw).items()]
        return "\n".join(rows)
    if key == "sw_stp":     # ưu tiên RSTP của switch (nhỏ = được bầu làm gốc)
        return p["switches"][args[0]].get("stp_priority", 32768)
    if key == "sw_mgmt":    # IP quản trị của switch (namespace riêng, như mạng quản trị tách của switch thật) + nơi nhận sFlow
        siem = host_in_group(p, "siem")
        rows = []
        for i, (s, v) in enumerate(p["switches"].items()):
            if v.get("mgmt"):
                z = p["zones"][mgmt_zone(p, v["mgmt"])]
                rows.append(f"{s} {short(s)}-mgmt {v['mgmt']}/{z['cidr'].split('/')[1]} {z.get('fw', z['gateway'])} {z['vlan']} "
                            f"{i} {p['hosts'][siem[0]]['ip'] if siem else '-'}")
        return "\n".join(rows)
    if key == "host_sw":
        return sw_of(p, args[0], "hosts") or "-"
    if key == "zone_sw":    # vùng có trên switch nào không (VM hoặc card firewall); "-" = cần bridge riêng lab-<vùng>
        return sw_of(p, args[0], "hosts") or sw_of(p, args[0], "fw") or "-"
    if key == "fw_ports":
        return "\n".join(f"{x['dev']} {'trunk' if x['trunk'] else 'access'} {','.join(n['zone'] for n in x['nics'])} "
                         f"{','.join(n['ip'] for n in x['nics'])} {x['sw'] or '-'}" for x in fw_ports(p, args[0]))
    if key == "vm_list":   # bộ tạo máy cần vcpus/ram_mb ghi trong hosts.yml (GCP dùng machine_type thay thế)
        rows = [(n, "fw", f, [x["zone"] for x in f["nics"]], [x["ip"] for x in f["nics"]]) for n, f in p["firewalls"].items()]
        rows += [(n, "linux", h, [h["zone"]], [h["ip"]]) for n, h in p["hosts"].items()]
        for n, _, h, _, _ in rows:
            if not (h.get("vcpus") and h.get("ram_mb") and h.get("disk")):
                sys.exit(f"{n}: thiếu vcpus / ram_mb / disk_gb trong {INV.relative_to(ROOT)}")
        return "\n".join(f"{n} {k} {h['vcpus']} {h['ram_mb']} {h['disk']} {','.join(z)} {','.join(i)}" for n, k, h, z, i in rows)
    if key == "host_net":
        h = p["hosts"][args[0]]
        z = p["zones"][h["zone"]]
        return f"{h['ip']}/{z['cidr'].split('/')[1]} {gateway(p, h['zone'])} {z.get('fw', z['gateway'])}"
    if key == "zone_fw":
        return p["zones"][args[0]]["fw"]
    if key == "host_routes":
        zone = p["hosts"][args[0]]["zone"]
        return "\n".join(f"{p['zones'][r['to']]['cidr']} {nic(p, r['via'], zone)}" for r in p["extra_routes"] if r["in"] == zone)
    if key == "lab_image_dir":
        return p["image_dir"]
    if key == "fw_role":
        return p["firewalls"][args[0]]["role"]
    if key == "mtu":
        return p["mtu"]
    if key == "node_interface":
        return p["node"]["interface"]
    sys.exit(f"không biết khoá: {key}")


if __name__ == "__main__":
    p = load()
    if sys.argv[1:2] == ["check"]:
        e = check(p)
        print("\n".join(e) if e else f"OK: {INV} hợp lệ")
        sys.exit(1 if e else 0)
    if sys.argv[1:2] == ["get"]:
        print(get(p, *sys.argv[2:]))
    else:
        sys.exit(__doc__)
