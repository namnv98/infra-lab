#!/usr/bin/env python3
"""Sinh sơ đồ TOPOLOGY CHÍNH (chi tiết, phóng to/kéo được) cho docs/architecture.html.

Vẽ đủ: IP public, VPC + dải IP + route, 2 firewall (từng card, IP, gateway, dịch vụ), mọi VM (card, IP, alias, dịch vụ + cổng),
"thanh" subnet của từng VPC. Lớp bật/tắt: luồng web (chặng 1–6), VPN quản trị, ghi chú route.
Chạy:  python3 docs/src/build_topology.py   → chèn giữa <!-- TOPO:BEGIN --> và <!-- TOPO:END -->.
"""
import html, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
E = html.escape
W, H = 1800, 1520
o = []  # các phần tử SVG


def t(x, y, s, cls="", anchor="start"):
    o.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="{cls}">{E(s)}</text>')


def rect(x, y, w, h, cls, rx=10, extra=""):
    o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" class="{cls}" {extra}/>')


def line(pts, cls, marker=""):
    p = " ".join(f"{a},{b}" for a, b in pts)
    m = f' marker-end="url(#{marker})"' if marker else ""
    o.append(f'<polyline points="{p}" class="{cls}"{m}/>')


def port(x, y, zone):
    o.append(f'<circle cx="{x}" cy="{y}" r="7" class="port c-{zone}"/>')


def host(x, y, w, h, title, rows, cls="box"):
    """Hộp máy: tiêu đề + các dòng (text, lớp)."""
    rect(x, y, w, h, cls, 8)
    t(x + 16, y + 28, title, "tt")
    yy = y + 52
    for r in rows:
        txt, c = (r, "tm dim") if isinstance(r, str) else r
        t(x + 16, yy, txt, c)
        yy += 21


def nic_rows(x, y, rows):
    """Bảng card mạng của firewall: (card, vùng, IP, ghi chú)."""
    for i, (nic, zone, ip, note) in enumerate(rows):
        yy = y + i * 24
        o.append(f'<circle cx="{x + 6}" cy="{yy - 5}" r="5" class="c-{zone}"/>')
        t(x + 18, yy, nic, "tm")
        t(x + 90, yy, ip, f"tm c-{zone}")
        t(x + 270, yy, note, "tm dim")


def badge(x, y, n):
    o.append(f'<circle cx="{x}" cy="{y}" r="13" class="badge"/><text x="{x}" y="{y + 5}" text-anchor="middle" class="badge-t tb">{n}</text>')


# ================================================================ khung
rect(20, 120, 1760, 1380, "gcp", 16)
t(40, 146, "GCP project ultra-evening-511813-t2 · asia-southeast1-a · chỉ dùng: VPC, route, VM, đĩa, IP public", "tm dim")

# bên ngoài
rect(260, 20, 340, 74, "box")
t(430, 50, "Internet · người dùng", "tt", "middle")
t(430, 74, "https://*.apps.lab.internal", "tm dim", "middle")
rect(1090, 20, 380, 74, "box")
t(1280, 50, "Máy admin (EndeavourOS)", "tt", "middle")
t(1280, 74, "WireGuard gcp-lab · 10.50.0.2/32", "tm dim", "middle")

# IP public
rect(280, 156, 300, 52, "box", 26)
t(430, 178, "IP web (tĩnh)", "tt", "middle")
t(430, 199, "NAT 1:1 → 10.99.0.2 · chỉ tcp 80,443", "tm dim", "middle")
rect(1160, 156, 240, 52, "box", 26)
t(1280, 178, "IP VPN (tĩnh, riêng)", "tt vpn-t", "middle")
t(1280, 199, "protocol fwd · chỉ udp 51820", "tm dim", "middle")
line([(430, 94), (430, 156)], "ln")
line([(1280, 94), (1280, 156)], "vpn")

# ================================================================ VPC WAN
rect(40, 236, 1720, 70, "z-wan")
t(640, 258, "VPC WAN · 10.99.0.0/24", "tt c-wan")
t(640, 278, "gateway .1 → Internet (route GCP)", "tm dim")
t(640, 298, "VPC firewall: IP web tcp 80,443 · IP VPN udp 51820", "tm dim")
line([(60, 290), (600, 290)], "bus c-wan-s")
line([(430, 208), (430, 290)], "ln-wan")

# ================================================================ firewall-edge-01
rect(250, 340, 560, 220, "box-fw", 12)
t(266, 368, "firewall-edge-01 · FIREWALL BIÊN", "tt")
t(794, 368, "OPNsense 26.7 · e2-medium", "tm dim", "end")
nic_rows(270, 398, [("vtnet1", "wan", "10.99.0.2/24", "WAN · gw .1 mặc định"),
                    ("vtnet0", "dmz", "10.10.10.253/24", "DMZ · gw .1 (far)"),
                    ("wg0", "vpn", "10.50.0.1/24", "WireGuard udp 51820")])
t(270, 480, "NAT hybrid (LAN/MGMT sau core) · port fwd 80/443 → edge-01", "tm")
t(270, 502, "Unbound (tên công cộng) · NTP cho DMZ", "tm dim")
t(270, 524, "route 10.20/24, 10.40/24 → DMZ_GW (.1) → core", "tm dim")
t(270, 546, "17 luật: WAN 1 · VPN 6 · DMZ 10 · GUI: VPN, jump-01", "tm dim")
port(430, 340, "wan"); line([(430, 290), (430, 333)], "ln-wan")
port(530, 560, "dmz")

# ================================================================ VPC DMZ
rect(40, 574, 1720, 200, "z-dmz")
t(60, 600, "VPC DMZ · 10.10.10.0/24 · vùng biên + trung chuyển", "tt c-dmz")
line([(60, 616), (1200, 616)], "bus c-dmz-s")
line([(530, 567), (530, 616)], "ln-dmz")
host(110, 636, 640, 128, "edge-01 · LB + WAF  (10.10.10.10 · e2-small)", [
    ("HAProxy :80 → 301 · :443 TLS (cert edge riêng *.apps.lab.internal)", "tm"),
    ("→ WAF 127.0.0.1:8080: ModSecurity v3 + OWASP CRS 4.30 (PL1, chặn 403)", "tm req-t"),
    ("→ HAProxy 127.0.0.1:8081 → Gateway .200:443 (TLS, kiểm lab-ca, SNI = Host)", "tm"),
    "rsyslog · auditd · Wazuh agent · chrony/DNS → .253 (biên)"])
line([(330, 616), (330, 636)], "ln-dmz")
rect(1240, 626, 500, 136, "box", 8)
t(1256, 652, "Route VPC DMZ", "tt")
t(1256, 676, "0.0.0.0/0    → 10.10.10.253 (biên)", "tm")
t(1256, 698, "10.20.0.0/24 → 10.10.10.252 (core)", "tm")
t(1256, 720, "10.40.0.0/24 → 10.10.10.252 (core)", "tm")
t(1256, 744, "VPC firewall: 10/8 mọi cổng · tcp 80,443 từ mọi nơi", "tm dim")

# ================================================================ firewall-core-01
rect(560, 808, 640, 200, "box-fw", 12)
t(576, 836, "firewall-core-01 · FIREWALL CORE", "tt")
t(1184, 836, "OPNsense 26.7 · e2-highcpu-4", "tm dim", "end")
nic_rows(580, 866, [("vtnet1", "dmz", "10.10.10.252/24", "DMZ (\"wan\") · gw .1 mặc định → biên"),
                    ("vtnet0", "lan", "10.20.0.253/24", "LAN"),
                    ("vtnet2", "mgmt", "10.40.0.253/24", "MGMT")])
t(580, 948, "KHÔNG NAT · không IP public · Unbound nội bộ lab.internal · NTP", "tm")
t(580, 970, "route /25 qua gateway .1 từng vùng (GCP không trả lời ARP giữa VM)", "tm dim")
t(580, 992, "25 luật: DMZ 9 (nguồn đích danh) · LAN 10 · MGMT 6", "tm dim")
port(900, 808, "dmz"); line([(900, 616), (900, 801)], "ln-dmz")
port(760, 1008, "lan")
port(1130, 1008, "mgmt")

# ================================================================ VPC LAN
rect(40, 1040, 1150, 450, "z-lan")
t(60, 1066, "VPC LAN · 10.20.0.0/24 — cluster K8s v1.37 + dịch vụ chung", "tt c-lan")
line([(60, 1082), (1170, 1082)], "bus c-lan-s")
line([(760, 1015), (760, 1082)], "ln-lan")
host(60, 1104, 360, 250, "k8s-master-01", [
    ("10.20.0.11 · alias 10.20.0.10 (VIP)", "tm c-lan"),
    "e2-medium · 30GB · control-plane",
    "kube-apiserver :6443 (qua VIP)",
    "kube-vip · etcd (Secret mã hoá)",
    "scheduler · controller-manager",
    "Kyverno (chỉ image Harbor)",
    "Pod Security restricted · audit log",
    "etcd snapshot 02:00 (7 bản)"])
host(440, 1104, 380, 250, "k8s-worker-01", [
    ("10.20.0.21 · alias .200 .210", "tm c-lan"),
    "e2-medium · 30GB · worker",
    ("Gateway public .200 (Envoy) *.apps", "tm req-t"),
    "Gateway internal .210 (Envoy) *.int",
    "whoami ×2 (ns demo, CNP)",
    "Prometheus · cert-manager · Velero",
    "MetalLB · Cilium (VXLAN)",
    "pod 10.244.0.0/16 · svc 10.96.0.0/12"])
host(840, 1104, 330, 250, "infra-01", [
    ("10.20.0.30", "tm c-lan"),
    "e2-medium · 50GB · dịch vụ chung",
    "Harbor :443 (proxy-cache image)",
    "Squid :3128 (allowlist tên miền)",
    "Garage S3 :3900 (Velero)",
    "Loki bản sao :3100 (90 ngày)",
    "ra Internet: core #140 → biên #20",
    "rồi NAT ở biên"])
for x in (240, 630, 1005):
    line([(x, 1082), (x, 1104)], "ln-lan")
t(60, 1384, "Route VPC LAN: 0.0.0.0/0 → 10.20.0.253 (core) · VPC firewall: 10/8 mọi cổng", "tm dim")
t(60, 1406, "alias IP (.10 VIP, .200/.210 Gateway) do GCP định tuyến — thay ARP của kube-vip/MetalLB · MTU 1460", "tm dim")

# ================================================================ VPC MGMT
rect(1210, 1040, 550, 450, "z-mgmt")
t(1230, 1066, "VPC MGMT · 10.40.0.0/24", "tt c-mgmt")
line([(1230, 1082), (1740, 1082)], "bus c-mgmt-s")
line([(1130, 1015), (1130, 1030), (1290, 1030), (1290, 1082)], "ln-mgmt")
host(1230, 1104, 500, 190, "siem-01 · SIEM", [
    ("10.40.0.10 · e2-medium · 30GB", "tm c-mgmt"),
    "Alloy :1514 (syslog RFC5424) → Loki (30 ngày)",
    "Grafana :3000 · luật cảnh báo → Mailpit :8025",
    "Wazuh manager :1515/1516",
    "← log 2 firewall, mọi VM; metric Prometheus (.210)",
    "bản sao log → infra-01:3100"])
host(1230, 1314, 500, 128, "jump-01 · bastion", [
    ("10.40.0.20 · e2-micro · 10GB", "tm c-mgmt"),
    "sshd chỉ khoá · pam_tty_audit (ghi phiên → SIEM)",
    "ProxyCommand (Ansible, ./lab.sh ssh/scp) · SOCKS :1080",
    "→ máy trong: :22 :443 :6443 :3000 :8025 (core #205)"])
line([(1480, 1082), (1480, 1104)], "ln-mgmt")
line([(1745, 1082), (1745, 1378), (1732, 1378)], "ln-mgmt")
t(1230, 1470, "Route VPC MGMT: 0.0.0.0/0 → 10.40.0.253 (core)", "tm dim")

# ================================================================ lớp: luồng web (chặng 1–6)
o.append('<g class="layer" data-layer="web">')
line([(590, 94), (590, 140), (620, 140), (620, 334)], "req", "tp-ah")
badge(636, 172, 1)
badge(244, 336, 2)
line([(552, 565), (552, 634)], "req", "tp-ah")
badge(572, 592, 3)
line([(700, 766), (700, 788), (880, 788), (880, 804)], "req", "tp-ah")
badge(840, 788, 4)
line([(740, 1012), (740, 1062), (600, 1062), (600, 1100)], "req", "tp-ah")
badge(668, 1062, 5)
badge(806, 1206, 6)
t(630, 120, "tcp 443 → port fwd", "tm req-t")
t(710, 780, "core #10", "tm req-t")
o.append('</g>')

# ================================================================ lớp: VPN quản trị
o.append('<g class="layer" data-layer="vpn">')
line([(1280, 208), (1280, 322), (830, 322), (830, 440), (814, 440)], "vpn", "tp-av")
t(1290, 250, "udp 51820 → wg0 (#5 biên)", "tm vpn-t")
t(1290, 270, "Virtual IP /32 trên WAN của biên", "tm dim")
line([(812, 530), (850, 530), (850, 796), (1000, 796), (1000, 804)], "vpn", "tp-av")
t(920, 652, "VPN → jump-01:22", "tm vpn-t")
t(920, 672, "(#300 biên)", "tm dim")
line([(1202, 900), (1770, 900), (1770, 1360), (1734, 1360)], "vpn", "tp-av")
t(1760, 892, "#40 core → jump-01:22", "tm vpn-t", "end")
o.append('</g>')

# ================================================================ lớp: ghi chú route (bật sẵn)
o.append('<g class="layer" data-layer="route">')
t(560, 1028, "DMZ_GW .1 = gateway mặc định của core (về biên)", "tm dim")
o.append('</g>')

SVG = (f'<svg id="topo-svg" viewBox="0 0 {W} {H}" role="img" '
       'aria-label="Topology chi tiết: Internet và máy admin vào qua IP public của firewall biên (WAN, DMZ, VPN wg0); '
       'DMZ chứa edge-01 (HAProxy + WAF) và card ngoài của firewall core; firewall core (DMZ, LAN, MGMT, không NAT) nối VPC LAN '
       '(k8s-master-01, k8s-worker-01, infra-01) và VPC MGMT (siem-01, jump-01).">\n<defs>'
       '<marker id="tp-ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="arrow"/></marker>'
       '<marker id="tp-av" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="m-vpn"/></marker>'
       '</defs>\n' + "\n".join(o) + '\n</svg>')

BLOCK = f'''<figure class="topo">
  <div class="topo-bar" role="toolbar" aria-label="Điều khiển sơ đồ">
    <button type="button" data-z="in" aria-label="Phóng to">+</button>
    <button type="button" data-z="out" aria-label="Thu nhỏ">−</button>
    <button type="button" data-z="fit">Vừa khung</button>
    <button type="button" data-z="full">Toàn màn hình</button>
    <span class="topo-sep"></span>
    <label><input type="checkbox" data-l="web" checked> luồng web (1–6)</label>
    <label><input type="checkbox" data-l="vpn" checked> VPN quản trị</label>
    <label><input type="checkbox" data-l="route" checked> ghi chú route</label>
    <span class="topo-hint">kéo để di chuyển · Ctrl + cuộn để phóng to</span>
  </div>
  <div class="topo-view" id="topo-view" tabindex="0">
{SVG}
  </div>
  <div class="legend">
    <span><i class="sw wan"></i>WAN</span><span><i class="sw dmz"></i>DMZ</span><span><i class="sw lan"></i>LAN / cluster</span><span><i class="sw mgmt"></i>MGMT</span>
    <span><i class="sw req"></i>request web</span><span><i class="sw vpn"></i>VPN quản trị</span><span><i class="bdg">1</i>chặng (bảng bên dưới)</span>
  </div>
  <figcaption>Sơ đồ chính, vẽ đủ card mạng, IP, gateway, route và dịch vụ của từng máy. Mô hình <b>screened subnet</b>: firewall
  <b>biên</b> giữ IP public, NAT, port forward, VPN; firewall <b>core</b> không IP public, không NAT, lọc mọi luồng vào LAN/MGMT. DMZ kiêm
  đường trung chuyển giữa 2 firewall. Mỗi vùng là một VPC riêng (GCP buộc mỗi card ở VPC khác nhau; số card ≤ số vCPU). <b>Web và VPN
  tách 2 IP public</b>: IP web chỉ mở tcp 80/443, IP VPN (protocol forwarding, giữ nguyên IP đích → Virtual IP trên WAN của biên) chỉ mở udp 51820 (<code>docs/thiet-ke-tach-ip-vpn.md</code>).</figcaption>
</figure>
<script>
(() => {{
  const view = document.getElementById("topo-view"), svg = document.getElementById("topo-svg");
  const W = {W}, H = {H}; let vb = {{x: 0, y: 0, w: W, h: H}};
  const set = () => svg.setAttribute("viewBox", `${{vb.x}} ${{vb.y}} ${{vb.w}} ${{vb.h}}`);
  const fit = () => {{ vb = {{x: 0, y: 0, w: W, h: H}}; set(); }};
  const zoom = (f, cx = 0.5, cy = 0.5) => {{
    const nw = Math.min(W * 1.5, Math.max(W / 8, vb.w * f)), nh = nw * H / W;
    vb.x += (vb.w - nw) * cx; vb.y += (vb.h - nh) * cy; vb.w = nw; vb.h = nh; set();
  }};
  document.querySelectorAll(".topo-bar [data-z]").forEach(b => b.addEventListener("click", () => {{
    const z = b.dataset.z;
    if (z === "in") zoom(0.7); else if (z === "out") zoom(1 / 0.7); else if (z === "fit") fit();
    else if (z === "full") {{ const f = view.closest(".topo"); document.fullscreenElement ? document.exitFullscreen() : f.requestFullscreen && f.requestFullscreen(); }}
  }}));
  document.querySelectorAll(".topo-bar [data-l]").forEach(c => c.addEventListener("change", () => {{
    svg.querySelectorAll(`[data-layer="${{c.dataset.l}}"]`).forEach(g => g.style.display = c.checked ? "" : "none");
  }}));
  view.addEventListener("wheel", e => {{
    if (!e.ctrlKey && !document.fullscreenElement) return;
    e.preventDefault(); const r = view.getBoundingClientRect();
    zoom(e.deltaY > 0 ? 1.15 : 1 / 1.15, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
  }}, {{passive: false}});
  view.addEventListener("dblclick", e => {{ const r = view.getBoundingClientRect(); zoom(0.6, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height); }});
  let drag = null;
  view.addEventListener("pointerdown", e => {{ drag = {{x: e.clientX, y: e.clientY, vx: vb.x, vy: vb.y}}; view.setPointerCapture(e.pointerId); view.classList.add("dragging"); }});
  view.addEventListener("pointermove", e => {{
    if (!drag) return; const r = view.getBoundingClientRect(), s = vb.w / r.width;
    vb.x = drag.vx - (e.clientX - drag.x) * s; vb.y = drag.vy - (e.clientY - drag.y) * s; set();
  }});
  const end = () => {{ drag = null; view.classList.remove("dragging"); }};
  view.addEventListener("pointerup", end); view.addEventListener("pointercancel", end);
  view.addEventListener("keydown", e => {{
    const k = {{ "+": 0.8, "=": 0.8, "-": 1.25 }}[e.key]; if (k) {{ zoom(k); e.preventDefault(); }}
    if (e.key === "0") fit();
  }});
}})();
</script>'''

CSS = '''/* topology chính (build_topology.py) */
.topo{gap:8px}
.topo-bar{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;font-size:13px}
.topo-bar button{font:inherit;padding:4px 12px;border:1px solid var(--line);border-radius:6px;background:var(--surface);color:var(--fg);cursor:pointer}
.topo-bar button:hover{border-color:var(--req)}
.topo-bar label{display:inline-flex;gap:5px;align-items:center;color:var(--muted)}
.topo-sep{width:1px;height:18px;background:var(--line)}
.topo-hint{color:var(--muted);font-size:12px;margin-left:auto}
.topo-view{height:min(82vh,960px);border:1px solid var(--line);border-radius:10px;background:var(--surface);overflow:hidden;cursor:grab;touch-action:none}
.topo-view.dragging{cursor:grabbing}
.topo-view:focus-visible{outline:2px solid var(--req);outline-offset:2px}
.topo-view svg{width:100%;height:100%;display:block;user-select:none}
.topo:fullscreen{background:var(--bg);padding:16px;display:grid;grid-template-rows:auto 1fr auto auto}
.topo:fullscreen .topo-view{height:auto}
#topo-svg .tt{font-size:17px;font-weight:600}
#topo-svg .tm{font-family:var(--mono);font-size:13.5px}
#topo-svg .tb{font-size:13px}
#topo-svg .bus{fill:none;stroke-width:6;stroke-linecap:round}
#topo-svg .c-wan-s{stroke:var(--wan)} #topo-svg .c-dmz-s{stroke:var(--dmz)} #topo-svg .c-lan-s{stroke:var(--lan)} #topo-svg .c-mgmt-s{stroke:var(--mgmt)}
#topo-svg .c-vpn{fill:var(--vpn)}
#topo-svg .ln,#topo-svg .ln-wan,#topo-svg .ln-dmz,#topo-svg .ln-lan,#topo-svg .ln-mgmt{stroke-width:2.2}
'''

for f in [ROOT / "docs/architecture.html"]:
    s = f.read_text()
    if "<!-- TOPO:BEGIN -->" not in s:  # lần đầu: thay figure topology cũ
        i = s.index('<section id="topology">')
        a = s.index("<figure>", i)
        b = s.index("</figure>", a) + len("</figure>")
        s = s[:a] + "<!-- TOPO:BEGIN -->\n<!-- TOPO:END -->" + s[b:]
    if "/* topology chính (build_topology.py) */" not in s:
        s = s.replace("/* sơ đồ chi tiết theo luồng (build_details.py) */", CSS + "/* sơ đồ chi tiết theo luồng (build_details.py) */", 1)
    s, n = re.subn(r"<!-- TOPO:BEGIN -->.*?<!-- TOPO:END -->", lambda m: "<!-- TOPO:BEGIN -->\n" + BLOCK + "\n<!-- TOPO:END -->", s, flags=re.S)
    assert n == 1
    f.write_text(s)
print("ok:", len(o), "phần tử")
