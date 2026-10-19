#!/usr/bin/env python3
"""Sinh phần "Chi tiết" của docs/architecture.html: 4 sơ đồ luồng, sơ đồ bên trong cluster, 2 ma trận luật firewall.

Ma trận luật đọc thẳng từ ansible/network/host_vars/firewall-{edge,core}-01.yml (opn_rules) + ansible/network/group_vars/firewalls.yml (opn_aliases),
nên luôn khớp với thứ Ansible đẩy lên 2 firewall. Chạy lại sau mỗi lần đổi luật/kiến trúc:
    python3 docs/src/build_details.py
Kết quả chèn giữa <!-- CHI-TIET:BEGIN --> và <!-- CHI-TIET:END --> trong docs/architecture.html .
"""
import html, json, os, pathlib, re, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def ansible_vars(host, *names):
    """Giá trị biến SAU khi Ansible render (IP trong alias/luật là biểu thức đọc inventory hosts.yml)."""
    # biến của team network: group_vars + host_vars (luật từng firewall) cạnh playbook của team (--playbook-dir network)
    out = subprocess.run(["ansible", host, "--playbook-dir", "network",
                          "-m", "debug", "-a", "var=[" + ",".join(names) + "]"], cwd=ROOT / "ansible",
                         capture_output=True, text=True, check=True, env={**os.environ, "ANSIBLE_STDOUT_CALLBACK": "json",
                                                                          "ANSIBLE_LOAD_CALLBACK_PLUGINS": "1"}).stdout
    res = json.loads(out)["plays"][0]["tasks"][0]["hosts"][host]
    return dict(zip(names, next(v for k, v in res.items() if k.startswith("["))))


FWV = {r: ansible_vars(f"firewall-{r}-01", "opn_rules", "opn_aliases") for r in ("edge", "core")}
GV = {"opn_aliases": FWV["edge"]["opn_aliases"]}   # alias dùng chung (ansible/network/group_vars/firewalls.yml)
E = html.escape

# ---------------------------------------------------------------- khung chung
# Lưới: Internet/admin trên cùng; firewall biên (trái, nối WAN + DMZ) và firewall core (phải, nối DMZ + LAN + MGMT);
# 3 vùng bên dưới (DMZ | LAN | MGMT).
#   biên: x 80–360, y 100–170 · core: x 560–900, y 100–170
ZONES = [("dmz", "VPC DMZ", "10.10.10.0/24", 20, 310),
         ("lan", "VPC LAN", "10.20.0.0/24", 350, 480),
         ("mgmt", "VPC MGMT", "10.40.0.0/24", 850, 310)]
HOSTS = {  # x, y, w, h, tiêu đề, dòng phụ
    "edge":   (40, 300, 270, 64, "edge-01 · LB + WAF", "10.10.10.10"),
    "master": (370, 300, 210, 64, "k8s-master-01", "10.20.0.11 · VIP .10"),
    "worker": (600, 300, 210, 64, "k8s-worker-01", "10.20.0.21 · GW .200/.210"),
    "infra":  (370, 470, 440, 80, "infra-01", "Harbor :443 · Squid :3128 · S3 :3900 · Loki :3100"),
    "jump":   (870, 300, 270, 64, "jump-01 · bastion", "10.40.0.20"),
    "siem":   (870, 440, 270, 100, "siem-01 · SIEM", "Alloy :1514 · Wazuh :1515/16"),
}


def box(key, extra=""):
    x, y, w, h, t, s = HOSTS[key]
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" class="box"/>',
           f'<text x="{x+14}" y="{y+23}" class="t">{E(t)}</text>',
           f'<text x="{x+14}" y="{y+42}" class="mono dim">{E(s)}</text>']
    if extra:
        out.append(f'<text x="{x+14}" y="{y+60}" class="mono dim">{E(extra)}</text>')
    return "\n".join(out)


def base(extras=None, sub_edge="NAT · port fwd · VPN wg0", sub_core="lọc vào trong · không NAT"):
    extras = extras or {}
    o = ['<rect x="10" y="76" width="1160" height="514" rx="14" class="gcp"/>',
         '<rect x="100" y="16" width="240" height="46" rx="10" class="box"/>',
         '<text x="220" y="44" text-anchor="middle" class="t">Internet</text>',
         '<rect x="420" y="16" width="240" height="46" rx="10" class="box"/>',
         '<text x="540" y="37" text-anchor="middle" class="t">Máy admin</text>',
         '<text x="540" y="54" text-anchor="middle" class="mono dim">10.50.0.2 (VPN)</text>']
    for z, name, cidr, x, w in ZONES:
        o += [f'<rect x="{x}" y="240" width="{w}" height="336" rx="10" class="z-{z}"/>',
              f'<text x="{x+14}" y="262" class="t c-{z}">{name}</text>',
              f'<text x="{x+14}" y="280" class="mono dim">{cidr}</text>']
    o += ['<rect x="80" y="100" width="280" height="70" rx="10" class="box-fw"/>',
          '<text x="220" y="128" text-anchor="middle" class="t">firewall-edge-01 · BIÊN</text>',
          f'<text x="220" y="150" text-anchor="middle" class="mono dim">{E(sub_edge)}</text>',
          '<rect x="560" y="100" width="340" height="70" rx="10" class="box-fw"/>',
          '<text x="730" y="128" text-anchor="middle" class="t">firewall-core-01 · CORE</text>',
          f'<text x="730" y="150" text-anchor="middle" class="mono dim">{E(sub_core)}</text>']
    for k in HOSTS:
        o.append(box(k, extras.get(k, "")))
    return o


def path(pts, cls="flow", mid="ah"):
    p = " ".join(f"{x},{y}" for x, y in pts)
    return f'<polyline points="{p}" class="{cls}" marker-end="url(#{mid})"/>'


def label(x, y, txt, cls="lb", anchor="start"):
    return f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="mono {cls}">{E(txt)}</text>'


def svg(fid, aria, body, h=600):
    return (f'<svg viewBox="0 0 1180 {h}" role="img" aria-label="{E(aria)}">\n<defs>'
            f'<marker id="{fid}-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="m-flow"/></marker>'
            f'<marker id="{fid}-b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="m-blk"/></marker>'
            f'<marker id="{fid}-v" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="m-vpn"/></marker>'
            '</defs>\n' + "\n".join(body).replace('url(#ah)', f'url(#{fid}-a)').replace('url(#blk)', f'url(#{fid}-b)').replace('url(#vpn)', f'url(#{fid}-v)')
            + "\n</svg>")


def figure(fid, title, aria, body, caption, legend):
    return (f'<h3 id="{fid}">{E(title)}</h3>\n<figure>\n<div class="scroll">\n{svg(fid, aria, body)}\n</div>\n'
            f'<div class="legend">{legend}</div>\n<figcaption>{caption}</figcaption>\n</figure>')


LEG_FLOW = '<span><i class="sw req"></i>luồng được phép (ghi luật # và firewall)</span>'
LEG_BLK = '<span><i class="sw blk"></i>bị chặn</span>'
LEG_VPN = '<span><i class="sw vpn"></i>VPN quản trị</span>'
# Đường dùng chung: core → các máy LAN (cổng dưới core)
CORE_TO_MASTER = [(700, 172), (700, 214), (475, 214), (475, 298)]
CORE_TO_WORKER = [(760, 172), (760, 232), (705, 232), (705, 298)]
CORE_TO_INFRA = [(838, 172), (838, 520), (814, 520)]

# ---------------------------------------------------------------- 1. đi ra Internet
b = base({"siem": "Grafana · Mailpit"})
b += [
    path([(475, 366), (475, 466)]), path([(705, 366), (705, 466)]),
    label(590, 424, "image → Harbor :443 · apt/helm → Squid :3128 (cùng subnet)", anchor="middle"),
    path([(590, 466), (590, 200), (650, 200), (650, 174)]), label(598, 194, "#140 core"),
    path([(558, 135), (364, 135)]), label(461, 126, "#20 biên + NAT", anchor="middle"),
    path([(220, 98), (220, 66)]), label(228, 88, "NAT ra IP public"),
    path([(210, 298), (210, 174)]), label(216, 214, "#10 biên: apt, Docker Hub"),
    path([(1005, 298), (1005, 150), (904, 150)]), label(999, 214, "#220 core → Squid/Harbor", anchor="end"),
    path(CORE_TO_INFRA),
    path([(440, 298), (440, 186), (570, 186), (570, 174)], "blk", "blk"), label(446, 236, "✕ #190 node ra thẳng", "lb-blk"),
    path([(1130, 298), (1130, 120), (904, 120)], "blk", "blk"), label(1124, 112, "✕ #290 MGMT ra thẳng", "lb-blk", "end"),
]
F1 = figure("fl-egress", "Đi ra Internet: chỉ infra-01 được ra, NAT ở biên",
            "Node K8s kéo image qua Harbor và cài gói qua Squid trên infra-01 cùng subnet; infra-01 ra Internet qua firewall core (luật 140) rồi firewall biên (luật 20) và được NAT ra IP public; edge-01 ra thẳng qua biên; MGMT đi qua Squid; node và MGMT ra thẳng bị chặn ở core.",
            b, "Node trong LAN không có đường ra Internet: image đi qua Harbor (proxy-cache), gói apt/Helm đi qua Squid với allowlist tên miền. "
               "infra-01 là máy LAN duy nhất được ra: core cho (#140), biên cho tiếp (#20) và NAT (Source NAT hybrid — NAT tự động không gồm dải sau core). "
               "Core không NAT, nên biên thấy đúng IP 10.20.0.30 để lọc. MGMT mượn Squid/Harbor (#220 ở core). DMZ ra thẳng qua biên (#10).",
            LEG_FLOW + LEG_BLK)

# ---------------------------------------------------------------- 2. log + cảnh báo
b = base({"siem": "Grafana → luật cảnh báo → Mailpit"}, sub_edge="syslog của biên → siem-01", sub_core="syslog của core → siem-01")
b += [
    path([(290, 298), (290, 232), (480, 232), (480, 160), (556, 160)]), label(296, 224, "#25/#26 core: syslog, Wazuh"),
    path([(364, 128), (556, 128)]), label(461, 120, "#27 core: syslog biên", anchor="middle"),
    path([(475, 298), (475, 214), (700, 214), (700, 174)]), path([(705, 298), (705, 232), (760, 232), (760, 174)]),
    path([(600, 466), (600, 214)]), label(608, 206, "#160/#165 core"),
    path([(904, 135), (1150, 135), (1150, 490), (1142, 490)]), label(1144, 214, "→ siem-01 :1514, :1515/16", anchor="end"),
    path([(1005, 366), (1005, 438)]), label(1012, 406, "cùng subnet"),
    path([(868, 500), (858, 500), (858, 174)]),
    path(CORE_TO_INFRA), label(806, 566, "#220 core: Loki bản sao :3100 (90 ngày)", anchor="end"),
    path([(680, 172), (680, 298)]), label(686, 290, "#215 → Prometheus .210"),
]
F2 = figure("fl-logs", "Log và cảnh báo: mọi máy và 2 firewall → siem-01",
            "Mọi máy gửi syslog và sự kiện Wazuh về siem-01 qua firewall core; firewall biên gửi syslog qua core; siem-01 ghi bản sao log sang infra-01 và đọc Prometheus qua Gateway internal; cảnh báo gửi Mailpit.",
            b, "rsyslog trên mọi máy Linux gửi journal, auth, auditd (kể cả phiên SSH trên jump-01) theo RFC5424 về Alloy :1514; Wazuh agent gửi tới manager :1515/1516. "
               "edge-01 đi thẳng sang core (route VPC DMZ), không qua biên; biên gửi syslog của chính nó qua core (#27). "
               "Alloy ghi vào Loki trên siem-01 (30 ngày) và bản sao trên infra-01 (90 ngày). Grafana chạy luật cảnh báo trên log + metric và gửi email tới Mailpit.",
            LEG_FLOW)

# ---------------------------------------------------------------- 3. quản trị
b = base({"siem": "Grafana :3000 · Mailpit :8025"}, sub_edge="wg0 10.50.0.1 · GUI :443 (#304)", sub_core="GUI :443 (#42) · DNS (#43)")
b += [
    path([(540, 64), (540, 112), (364, 112)], "vpn", "vpn"), label(548, 88, "WireGuard udp 51820 → IP VPN → wg0 (biên)", "lb-vpn"),
    path([(364, 150), (556, 150)], "vpn", "vpn"), label(461, 142, "#300/#303 biên", "lb-vpn", "middle"),
    path([(904, 120), (1100, 120), (1100, 298)], "vpn", "vpn"), label(1094, 226, "#40 core :22", "lb-vpn", "end"),
    path([(960, 298), (960, 160), (904, 160)]), label(954, 226, "#205 :22 :443 :6443 :3000 :8025", anchor="end"),
    path(CORE_TO_MASTER), path(CORE_TO_WORKER), path([(590, 172), (590, 466)]),
    path([(556, 162), (480, 162), (480, 232), (300, 232), (300, 298)]), label(306, 224, "từ jump-01: SSH, web"),
    path([(480, 200), (330, 200), (330, 174)]), label(336, 194, "#30 biên: GUI"),
    path([(1005, 366), (1005, 438)]), label(1012, 406, "cùng subnet"),
    path([(250, 174), (250, 238)], "blk", "blk"), label(244, 206, "✕ #309 (biên): VPN →", "lb-blk", "end"), label(244, 222, "edge-01, máy khác", "lb-blk", "end"),
]
F3 = figure("fl-admin", "Quản trị: VPN (biên) → jump-01 → máy trong",
            "Máy admin vào WireGuard trên firewall biên; VPN chỉ được tới jump-01 cổng 22 (qua core) và GUI/API của 2 firewall; từ jump-01 mới SSH, kubectl, web tới các máy khác qua core, và tới GUI firewall biên qua core rồi biên; VPN đi thẳng tới máy khác bị chặn ngay ở biên.",
            b, "Tunnel kết thúc ở wg0 trên <b>biên</b>. Biên chỉ cho VPN tới jump-01:22 (#300), GUI/API core (#303) và GUI/API biên (#304), chặn phần còn lại (#309); "
               "core lọc lần nữa (#40 jump-01, #42 GUI core, #43 DNS nội bộ). Từ jump-01, core cho các cổng quản trị (#205) tới LAN, edge-01 và cả GUI biên — biên kiểm thêm lần nữa (#30). <code>./lab.sh ssh</code>, <code>scp</code> và Ansible dùng ProxyCommand qua jump-01; "
               "<code>./lab.sh tunnel up</code> mở SOCKS qua jump-01 cho trình duyệt và kubectl. Luật #205 (core) giới hạn jump-01 ở cổng quản trị. "
               "Phiên SSH trên jump-01 được ghi (pam_tty_audit → auditd → siem-01).",
            LEG_VPN + LEG_FLOW + LEG_BLK)

# ---------------------------------------------------------------- 4. backup
b = base({"siem": "Loki 30 ngày"})
b += [
    label(378, 380, "etcd snapshot 02:00 → /var/backups/etcd (7 bản)", "lb"),
    path([(705, 366), (705, 466)]), label(712, 424, "Velero 02:00 → S3 (7 ngày)"),
    path([(520, 298), (520, 196), (640, 196), (640, 174)], "vpn", "vpn"),
    path([(556, 150), (364, 150)], "vpn", "vpn"),
    path([(364, 118), (500, 118), (500, 66)], "vpn", "vpn"), label(508, 92, "Ansible fetch → out/backups (qua jump-01)", "lb-vpn"),
    path([(868, 500), (858, 500), (858, 174)]),
    path(CORE_TO_INFRA), label(806, 566, "#220 core: log → Loki bản sao (90 ngày)", anchor="end"),
]
F4 = figure("fl-backup", "Backup: etcd, Velero, log",
            "etcd được snapshot hằng ngày trên k8s-master-01 và kéo về máy admin qua 2 firewall; Velero backup tài nguyên cluster vào Garage S3 trên infra-01; log được nhân bản sang infra-01.",
            b, "Ba lớp: <b>etcd</b> (toàn bộ trạng thái cluster) snapshot 02:00 trên master, giữ 7 bản, và <code>60-security.yml</code> kéo bản mới nhất về "
               "<code>out/backups</code>; khôi phục bằng <code>ops-etcd-restore.yml</code>. <b>Velero</b> backup theo namespace vào Garage S3 trên infra-01 "
               "(cùng subnet, không qua firewall). <b>Log</b> có bản sao 90 ngày trên infra-01, khác máy với siem-01. On-prem thật cần thêm bản sao ngoài site.",
            LEG_FLOW + LEG_VPN)

# ---------------------------------------------------------------- 5. bên trong cluster
def comp(x, y, w, h, t, s="", cls="box"):
    o = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" class="{cls}"/>',
         f'<text x="{x+10}" y="{y+19}" class="t">{E(t)}</text>']
    if s:
        o.append(f'<text x="{x+10}" y="{y+36}" class="mono dim">{E(s)}</text>')
    return "\n".join(o)


b = ['<rect x="20" y="90" width="1140" height="430" rx="10" class="z-lan"/>',
     '<text x="34" y="112" class="t c-lan">Cluster K8s v1.37 · VPC LAN</text>',
     comp(300, 10, 220, 46, "jump-01 (MGMT)", "kubectl qua SOCKS"),
     comp(600, 10, 220, 46, "edge-01 (DMZ)", "HAProxy + WAF"),
     comp(880, 10, 220, 46, "siem-01 (MGMT)", "Grafana"),
     # master
     '<rect x="40" y="128" width="500" height="300" rx="8" class="box"/>',
     '<text x="54" y="150" class="t">k8s-master-01 · control-plane</text>',
     comp(60, 164, 220, 46, "kube-apiserver :6443", "audit log → siem-01"),
     comp(300, 164, 220, 46, "kube-vip", "VIP 10.20.0.10 (alias IP)"),
     comp(60, 224, 220, 46, "etcd", "Secret mã hoá · snapshot 02:00"),
     comp(300, 224, 220, 46, "scheduler · controller", ""),
     comp(60, 284, 460, 46, "Kyverno (admission webhook)", "ns có lab/policy=strict: chỉ image harbor.lab.internal/*"),
     comp(60, 344, 460, 46, "Pod Security restricted", "default, demo, gateway, cert-manager"),
     # worker
     '<rect x="560" y="128" width="580" height="300" rx="8" class="box"/>',
     '<text x="574" y="150" class="t">k8s-worker-01 · worker</text>',
     comp(580, 164, 260, 46, "Gateway public .200", "Envoy · *.apps.lab.internal", "waf"),
     comp(860, 164, 260, 46, "Gateway internal .210", "Envoy · *.int.lab.internal"),
     comp(580, 244, 260, 46, "whoami ×2 (ns demo)", "CNP: chỉ nhận từ Envoy"),
     comp(860, 244, 260, 46, "Prometheus (ns monitoring)", "node-exporter, kube-state"),
     comp(580, 314, 170, 46, "cert-manager", "issuer lab-ca"),
     comp(765, 314, 170, 46, "Velero", "→ S3 infra-01"),
     comp(950, 314, 170, 46, "MetalLB", "cấp .200 / .210"),
     comp(580, 374, 540, 40, "containerd → mirror Harbor (infra-01)", ""),
     # cilium
     '<rect x="40" y="440" width="1100" height="56" rx="8" class="box"/>',
     '<text x="54" y="463" class="t">Cilium 1.20 (eBPF) · trên mọi node</text>',
     '<text x="54" y="482" class="mono dim">pod 10.244.0.0/16 · VXLAN · NetworkPolicy + CiliumNetworkPolicy (default-deny ns demo) · Gateway API (Envoy)</text>',
     # luồng
     path([(410, 58), (410, 162)]), label(418, 128, "kubectl → VIP :6443"),
     path([(710, 58), (710, 162)]), label(718, 128, "HTTPS đã qua WAF → .200:443 (core #10)"),
     path([(710, 212), (710, 242)]),
     path([(990, 58), (990, 162)]), label(998, 128, "#215 → .210:443"),
     path([(990, 212), (990, 242)]),
]
F5 = ('<h3 id="fl-k8s">Bên trong cluster</h3>\n<figure>\n<div class="scroll">\n'
      + svg("fl-k8s", "Cluster gồm k8s-master-01 (apiserver sau VIP kube-vip, etcd mã hoá, Kyverno, Pod Security) và k8s-worker-01 (2 Gateway Envoy, whoami, Prometheus, cert-manager, Velero, MetalLB); Cilium nối pod trên mọi node; edge-01 vào Gateway public, siem-01 vào Gateway internal, jump-01 gọi API qua VIP.", b, h=520)
      + '\n</div>\n<div class="legend">' + LEG_FLOW + '<span><i class="sw waf"></i>điểm vào từ Internet</span></div>\n'
      '<figcaption>Hai Gateway (Cilium Gateway API, Envoy) là cửa vào duy nhất của app: <b>public .200</b> chỉ nhận từ edge-01 (luật DMZ #10), '
      '<b>internal .210</b> cho LAN, VPN qua jump-01 và Grafana. IP .200/.210/.10 do MetalLB/kube-vip quản lý nhưng GCP định tuyến bằng alias IP. '
      'Pod chỉ chạy image từ Harbor (Kyverno), đạt Pod Security <code>restricted</code>, và namespace demo mặc định chặn mọi traffic trừ luồng khai báo.</figcaption>\n</figure>')

# ---------------------------------------------------------------- 6. ma trận luật (đọc từ host_vars từng firewall)
ALIAS = {a["name"]: a for a in GV["opn_aliases"]}
IFACE = {"edge": {"wan": "WAN", "wireguard": "VPN", "lan": "DMZ"},
         "core": {"wan": "DMZ", "lan": "LAN", "opt1": "MGMT"}}
NET = {"edge": {"lan": "DMZ", "lanip": "biên (DMZ .253)", "wanip": "IP WAN"},
       "core": {"wan": "DMZ", "lan": "LAN", "opt1": "MGMT", "lanip": "core (LAN .253)", "opt1ip": "core (MGMT .253)"}}
HOSTNAME = {"10.20.0.30": "infra-01", "10.40.0.10": "siem-01", "10.40.0.20": "jump-01", "10.20.0.200": "Gateway public .200",
            "10.20.0.210": "Gateway internal .210", "10.10.10.10": "edge-01", "10.50.0.0/24": "VPN admin",
            "10.10.10.253": "biên (DMZ .253)", "10.10.10.252": "core (DMZ .252)", "10.20.0.253": "core (LAN .253)"}


def net(role, n, neg=False):
    if n in NET[role]:
        v = NET[role][n]
    elif n == "any":
        v = "bất kỳ"
    elif n == "RFC1918":
        v = "mọi IP nội bộ"
    elif n in ALIAS:
        v = ", ".join(HOSTNAME.get(x, x) for x in ALIAS[n]["content"].split("\n"))
    else:
        v = HOSTNAME.get(n, n)
    return ("Internet (" + "không phải " + v + ")") if neg else v


def port(p):
    if not p:
        return "mọi"
    p = str(p)
    if p in ALIAS:
        return ", ".join(ALIAS[p]["content"].split("\n"))
    return p


def matrix(role):
    order = list(IFACE[role])
    rows = []
    for r in sorted(FWV[role]["opn_rules"], key=lambda r: (order.index(r["interface"]), int(r["sequence"]))):
        act = '<span class="y">cho</span>' if r["action"] == "pass" else '<span class="n">chặn</span>'
        note = " (tạm, khi dựng)" if "TẠM" in r["description"] else ""
        neg = r.get("destination_not") == "1" and r["destination_net"] == "RFC1918"
        dst = "Internet" if neg else net(role, r["destination_net"])
        proto = "mọi" if r["protocol"] == "any" else r["protocol"] + " " + port(r.get("destination_port", ""))
        rows.append(f'<tr><td class="mono">#{r["sequence"]}</td><td>{IFACE[role][r["interface"]]}</td><td>{E(net(role, r["source_net"]))}</td>'
                    f'<td>{E(dst)}</td><td class="mono">{E(proto)}</td><td>{act}{note}</td><td>{E(r["description"])}</td></tr>')
    return rows


def table(rows):
    return ('<div class="tbl"><table>\n<thead><tr><th>#</th><th>Card vào</th><th>Nguồn</th><th>Đích</th><th>Giao thức · cổng</th><th>Hành động</th><th>Mô tả</th></tr></thead>\n<tbody>\n'
            + "\n".join(rows) + '\n</tbody></table></div>')


RE, RC = matrix("edge"), matrix("core")
F6 = ('<h3 id="fl-rules">Ma trận luật 2 firewall</h3>\n'
      '<p>Sinh tự động từ <code>ansible/network/host_vars/firewall-{edge,core}-01.yml</code> — đúng thứ Ansible đẩy lên OPNsense. '
      'Luật xét theo card nhận gói, số nhỏ trước, khớp là dừng; cuối mỗi card là luật chặn mọi thứ còn lại (ghi log → SIEM). '
      'Ngoài bảng: ở biên có port forward WAN 80/443 → edge-01 (giữ IP client) và Source NAT hybrid cho LAN/MGMT; core tắt NAT. '
      'Firewall VPC của GCP chỉ mở WAN 80/443/51820 vào máy gắn tag <code>fw</code> (biên).</p>\n'
      f'<h3>firewall-edge-01 (biên) — {len(RE)} luật</h3>\n' + table(RE) +
      f'\n<h3>firewall-core-01 (core) — {len(RC)} luật</h3>\n' + table(RC))

SECTION = ('<section id="detail">\n  <h2>Sơ đồ chi tiết theo luồng</h2>\n'
           '  <p>Cùng một khung (Internet, firewall biên, firewall core, 3 vùng), mỗi sơ đồ chỉ vẽ một loại traffic. '
           'Nhãn trên mũi tên ghi số luật và firewall cho phép luồng đó — xem 2 ma trận cuối mục.</p>\n'
           + "\n".join([F1, F2, F3, F4, F5, F6]) + '\n</section>')

for f in [ROOT / "docs/architecture.html"]:
    s = f.read_text()
    s, n = re.subn(r"<!-- CHI-TIET:BEGIN -->.*?<!-- CHI-TIET:END -->",
                   lambda m: "<!-- CHI-TIET:BEGIN -->\n" + SECTION + "\n<!-- CHI-TIET:END -->", s, flags=re.S)
    assert n == 1, f"thiếu marker CHI-TIET trong {f}"
    f.write_text(s)
print("ok:", len(RE), "luật biên,", len(RC), "luật core")
