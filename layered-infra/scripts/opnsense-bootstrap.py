#!/usr/bin/env python3
"""Sinh config.xml BOOTSTRAP cho OPNsense từ cấu hình mặc định của hãng (config.xml.sample đúng phiên bản).

Chỉ chứa phần tối thiểu để Ansible vào được qua API lần đầu:
  - gán card + IP + MTU, gateway từng vùng, route, DNS hệ thống (theo vai edge/core)
  - mật khẩu root + 1 API key (sinh ngẫu nhiên, lưu ở out/)
  - 1 luật TẠM trên WAN: chỉ IP public của máy admin được vào API (443). Ansible xoá luật này khi VPN đã chạy.
Mọi thứ khác (VPN, alias, luật, NAT, DNS nội bộ, syslog) do role Ansible `opnsense` cấu hình.

Hai vai:
  edge = firewall biên: WAN (IP public) + DMZ; NAT, port forward, VPN. Luật BOOTSTRAP: IP admin → API trên WAN.
  core = firewall core: LAN + DMZ (card ngoài, gateway mặc định = biên) + MGMT; không NAT. Luật BOOTSTRAP: dải VPN → API
         trên card DMZ (core không có IP public, Ansible gọi xuyên VPN của biên).

Dùng: opnsense-bootstrap.py <factory-config.xml> <out-dir> <admin-public-ip> <edge|core>
"""
import ipaddress, secrets, string, subprocess, sys, uuid, pathlib
import xml.etree.ElementTree as ET

factory, outdir, admin_ip, role = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]

# Card, IP, gateway, route: đọc từ inventory hosts.yml (nguồn IP duy nhất, scripts/inventory.py). Card theo thứ tự = vtnet0..n.
# GCP không trả lời ARP giữa các VM → mọi gateway trong VPC là .1 của subnet, bật far gateway (trừ WAN).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import inventory as invlib
P = invlib.load()
fw_name, FW = next((k, f) for k, f in P["firewalls"].items() if f["role"] == role)
GCP = P.get("platform", "gcp") == "gcp"
# dev: tên card trong FreeBSD — mặc định vtnet<i> (virtio: KVM/Proxmox/GCP); VMware: vmx<i>, máy thật: igb<i>/em<i>/ix<i> → ghi dev trong nics (hosts.yml)
# lab_vlan_trunk: vùng có vlan đi chung 1 card trunk → interface VLAN vtnet<i>_vlan<tag> (inventory.fw_ports)
zones_t = [(n["if"], invlib.nic_dev(P, fw_name, n), n["ip"], n.get("descr"), P["zones"][n["zone"]]["cidr"].split("/")[1])
           for n in FW["nics"]]
my_nic = {n["zone"]: n for n in FW["nics"]}
GW, RT = [], []   # gateway: (tên, card, IP, mặc định?, far?) · route tĩnh: (mạng, tên gateway, mô tả)
if GCP:
    # GCP không trả lời ARP giữa VM → mỗi card một gateway = .1 của VPC (far gateway, trừ WAN) + 2 route /25 cùng vùng;
    # vào vùng khác qua route của VPC (VPC đưa tới firewall kia)
    for n in FW["nics"]:
        far = n["zone"] != "wan"
        GW.append((f"{n['zone'].upper()}_GW", n["if"], P["zones"][n["zone"]]["gateway"], bool(n.get("default_gw")), far))
        if far:
            RT += [(h, f"{n['zone'].upper()}_GW", "GCP: tới VM cùng vùng qua gateway VPC") for h in invlib.halves(P["zones"][n["zone"]]["cidr"])]
    RT += [(P["zones"][r["to"]]["cidr"], f"{r['in'].upper()}_GW", "Vào trong qua firewall core (route VPC lab-dmz → core)")
           for r in P["extra_routes"] if r["in"] in my_nic and r["via"] != fw_name]
else:
    # On-prem: ARP thật, firewall là gateway của VLAN → chỉ cần gateway mặc định + gateway sang firewall kia.
    # Gateway mặc định = card firewall kia trong vùng uplink (core: card DMZ của biên), vùng không có fw (wan) thì gateway của vùng
    up = next(n for n in FW["nics"] if n.get("default_gw"))
    GW.append((f"{up['zone'].upper()}_GW", up["if"], invlib.gateway(P, up["zone"]), True, False))
    for r in P["extra_routes"]:
        if r["in"] in my_nic and r["via"] != fw_name:
            gname = r["via"].split("-")[1].upper() + "_GW"      # vd. firewall-core-01 → CORE_GW
            if gname not in [g[0] for g in GW]:
                GW.append((gname, my_nic[r["in"]]["if"], invlib.nic(P, r["via"], r["in"]), False, False))
            RT.append((P["zones"][r["to"]]["cidr"], gname, f"Vào {r['to'].upper()} qua {r['via']}"))
uplink = next(n for n in FW["nics"] if n.get("default_gw"))
if role == "edge":   # biên: chỉ IP public của admin được gọi API trên WAN
    boot = dict(interface=uplink["if"], source_net=f"{admin_ip}/32", destination_net="wanip",
                description="BOOTSTRAP: admin → API qua WAN (Ansible xoá khi VPN chạy)")
else:                # core: không IP public → dải VPN (đi xuyên biên) gọi API trên card ngoài
    lan_ip = next(n["ip"] for n in FW["nics"] if n["if"] == "lan")
    boot = dict(interface=uplink["if"], source_net=P["vpn"]["cidr"], destination_net=f"{lan_ip}/32",
                description="BOOTSTRAP: VPN (qua biên) → API core (Ansible xoá khi cấu hình xong)")
ROLES = {role: dict(hostname=fw_name, dns=FW["dns"], zones=zones_t, boot_rule=boot)}
R = ROLES[role]
ZONES = R["zones"]
MTU = str(P.get("mtu", 1500))   # lab_mtu trong hosts.yml (GCP: 1460 của VPC)


def rnd(n):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))


def crypt6(pw):  # SHA-512 crypt, PHP password_verify() hiểu được
    return subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=pw, capture_output=True, text=True, check=True).stdout.strip()


def secret_file(name, gen):  # giữ secret cũ nếu đã có → chạy lại không đổi mật khẩu/API key
    p = outdir / name
    if not p.exists():
        p.write_text(gen())
        p.chmod(0o600)
    return p.read_text()


def sub(parent, tag, text=None):
    e = parent.find(tag)
    if e is None:
        e = ET.SubElement(parent, tag)
    if text is not None:
        e.text = text
    return e


root_pw = secret_file(f"opnsense-{role}-root.txt", lambda: rnd(20) + "\n").strip()   # mỗi firewall 1 bộ mật khẩu/API key
api = secret_file(f"opnsense-{role}-api.txt", lambda: f"key={rnd(40)}\nsecret={rnd(80)}\n")
api_key = api.split("key=")[1].split("\n")[0]
api_secret = api.split("secret=")[1].split("\n")[0]

tree = ET.parse(factory)
r = tree.getroot()
for t in ("trigger_initial_wizard",):  # không bắt chạy wizard trên GUI
    e = r.find(t)
    if e is not None:
        r.remove(e)

# --- system ---
s = r.find("system")
sub(s, "hostname", R["hostname"])
sub(s, "domain", P["domain"])
sub(s, "dnsserver", R["dns"])
# Bỏ luật anti-lockout (GUI mở cho card "LAN"): ở biên "LAN" là DMZ → edge-01 sẽ vào được GUI. Quản trị chỉ theo luật.
sub(s.find("webgui"), "noantilockout", "1")
sub(s, "primaryconsole", "serial")  # bản nano: console nối tiếp (GCP serial port / IPMI SOL)
sub(s, "serialspeed", "115200")
# On-prem, core: gateway của card ngoài là biên, nhưng máy DMZ (edge-01) nằm cùng dải → trả lời phải đi thẳng tới máy đó.
# reply-to (mặc định trên card có gateway) đẩy trả lời về biên → biên không có state → chặn. GCP: .1 của VPC tự chuyển đúng
if role == "core" and not GCP:
    sub(s, "disablereplyto", "yes")
u = s.find("user")
sub(u, "password", crypt6(root_pw))
sub(u, "apikeys", f"{api_key}|{crypt6(api_secret)}")

# --- interfaces: IP tĩnh, MTU theo hosts.yml, tắt IPv6 ---
ifs = r.find("interfaces")
for name, nic, ip, descr, prefix in ZONES:
    e = ifs.find(name)
    if e is None:
        e = ET.SubElement(ifs, name)
    for c in list(e):
        if c.tag.startswith(("ipaddrv6", "subnetv6", "track6", "dhcp6")):
            e.remove(c)
    sub(e, "enable", "1")
    sub(e, "if", nic)
    sub(e, "mtu", MTU)
    sub(e, "ipaddr", ip)
    sub(e, "subnet", prefix)   # đúng dải của vùng (on-prem: WAN/transit /29)
    if descr:
        sub(e, "descr", descr)
    if name == "wan":
        sub(e, "gateway", next(g[0] for g in GW if g[3]))   # gateway mặc định gắn trên card "wan" (biên: Internet; core: về biên)
        # card ngoài nằm trong dải private → không chặn private/bogon: core (card ngoài ở DMZ/transit), biên on-prem sau NAT
        # của nhà mạng/libvirt (máy admin + VPN tới từ dải private). GCP giữ chặn: Internet tới bằng IP public thật
        wan_cidr = P["zones"][next(n["zone"] for n in FW["nics"] if n["if"] == "wan")]["cidr"]
        if role == "core" or (not GCP and ipaddress.ip_network(wan_cidr).is_private):
            for t in ("blockpriv", "blockbogons"):
                c = e.find(t)
                if c is not None:
                    e.remove(c)

# --- VLAN (on-prem có switch): thiết bị VLAN trên card trunk, interface ở trên dùng tên thiết bị này ---
if P["vlan_trunk"]:
    vl = sub(r, "vlans")
    vl.set("version", "1.0.0")
    for x in invlib.fw_ports(P, fw_name):
        for n in x["nics"] if x["trunk"] else []:
            v = ET.SubElement(vl, "vlan", {"uuid": str(uuid.uuid4())})
            tag = str(P["zones"][n["zone"]]["vlan"])
            for k, val in [("if", x["dev"]), ("tag", tag), ("pcp", "0"), ("proto", None),
                           ("descr", f"VLAN {tag} {n['zone'].upper()}"), ("vlanif", invlib.nic_dev(P, fw_name, n))]:
                ET.SubElement(v, k).text = val

# --- DHCP/RA trên LAN của bản mặc định: tắt (DHCP do VPC lo) ---
d = r.find("dnsmasq")
if d is not None:
    for c in d.findall("dhcp_ranges"):
        d.remove(c)
    sub(d, "enable", "0")

# --- Gateway từng card. GCP không trả lời ARP giữa các VM: mọi gói tới VM khác phải gửi qua gateway .1 của subnet.
# Giữ IP /24 (luật, NAT, Unbound vẫn hiểu "mạng LAN"), thêm 2 route /25 (cụ thể hơn /24) qua gateway của vùng.
# far gateway: OPNsense thêm route host tới .1 qua card, tránh .1 tự lặp vào route /25.
opn = r.find("OPNsense")
gws = opn.find("Gateways")
if gws is None:
    gws = ET.SubElement(opn, "Gateways", {"version": "1.0.0"})
sr = r.find("staticroutes")
if sr is None:
    sr = ET.SubElement(r, "staticroutes", {"version": "1.0.0"})


def route(net, gname, descr):
    rt = ET.SubElement(sr, "route", {"uuid": str(uuid.uuid4())})
    for k, v in [("network", net), ("gateway", gname), ("descr", descr), ("disabled", "0")]:
        ET.SubElement(rt, k).text = v


for gname, iface, gip, dflt, far in GW:
    g = ET.SubElement(gws, "gateway_item", {"uuid": str(uuid.uuid4())})
    zname = next((d or n.upper()) for n, _, _, d, _ in ZONES if n == iface)
    for k, v in [("disabled", "0"), ("name", gname), ("descr", f"Gateway VPC vùng {zname}" if GCP else f"Gateway {gname} ({gip})"),
                 ("interface", iface), ("ipprotocol", "inet"), ("gateway", gip), ("defaultgw", "1" if dflt else "0"),
                 ("fargw", "1" if far else "0"), ("monitor_disable", "1"), ("priority", "255"), ("weight", "1")]:
        ET.SubElement(g, k).text = v
for net, gname, descr in RT:
    route(net, gname, descr)

# --- NAT: core KHÔNG NAT (biên phải thấy IP thật của LAN/MGMT để lọc và NAT ra Internet). Biên: tự động.
if role == "core":
    nat = r.find("nat")
    if nat is None:
        nat = ET.SubElement(r, "nat")
    sub(sub(nat, "outbound"), "mode", "disabled")

# --- luật TẠM để Ansible vào được API lần đầu ---
rules = opn.find("Firewall/Filter/rules")
tmpl = rules.find("rule")  # luật mặc định của hãng làm khuôn (đủ trường)
rule = ET.fromstring(ET.tostring(tmpl))
rule.attrib["uuid"] = str(uuid.uuid4())
br = R["boot_rule"]
for k, v in [("enabled", "1"), ("sequence", "1"), ("action", "pass"), ("interface", br["interface"]), ("protocol", "TCP"),
             ("source_net", br["source_net"]), ("destination_net", br["destination_net"]), ("destination_port", "443"),
             ("log", "1"), ("description", br["description"])]:
    sub(rule, k, v)
rules.insert(0, rule)

ET.indent(tree, "  ")
out = outdir / f"opnsense-{role}-bootstrap.xml"
tree.write(out, encoding="unicode", xml_declaration=True)
out.chmod(0o600)
print(f"OK: {out} ({R['hostname']}, admin {admin_ip}, API key {api_key[:6]}…)")
