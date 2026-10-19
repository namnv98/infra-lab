#!/usr/bin/env python3
"""Lần boot đầu của OPNsense (bản nano gốc, cấu hình mặc định): qua console nối tiếp, đăng nhập root/opnsense
mặc định, tải config bootstrap từ metadata của VM (giống cắm USB chứa config.xml ở on-prem) rồi khởi động lại.

Dùng: fw-console-bootstrap.py <vm> <zone> <project> <gateway của card vtnet1>
  gateway = .1 của vùng chứa card vtnet1 (00-firewall-bootstrap.yml tính từ plan.yml); chạy song song được
"""
import re, subprocess, sys, time

vm, zone, project, gw = sys.argv[1:5]
S = f"fwcon-{vm}"   # mỗi máy 1 phiên tmux → bootstrap 2 firewall cùng lúc
subprocess.run(["tmux", "kill-session", "-t", S], capture_output=True)
subprocess.run(["tmux", "new-session", "-d", "-s", S, "-x", "200", "-y", "50",
                f"gcloud compute connect-to-serial-port {vm} --zone {zone} --project {project} --port 1"], check=True)
subprocess.run(["tmux", "set-option", "-t", S, "history-limit", "5000"])


def screen(n=8):
    out = subprocess.run(["tmux", "capture-pane", "-p", "-t", S, "-S", f"-{n}"], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if l.strip()]


def send(s):
    subprocess.run(["tmux", "send-keys", "-t", S, "-l", s])
    subprocess.run(["tmux", "send-keys", "-t", S, "Enter"])


# Câu hỏi có thể gặp ở lần boot đầu (gán card khi cấu hình mặc định không khớp phần cứng) → câu trả lời
ANSWERS = [
    (r"LAGGs now\? \[y/N\]", "n"),
    (r"VLANs now\? \[y/N\]", "n"),
    (r"Enter the WAN interface name", "vtnet1"),
    (r"Enter the LAN interface name", "vtnet0"),
    (r"Enter the Optional interface 1 name", ""),
    (r"Do you want to proceed\? \[y/N\]", "y"),
    (r"login:\s*$", "root"),
    (r"Password:\s*$", "opnsense"),
    (r"Enter an option:\s*$", "8"),
]
# dhclient chạy tay không đặt default route → thêm route tới metadata qua gateway VPC (.1) của card vtnet1.
# Chuỗi báo thành công ghép từ 2 nửa để không trùng với chính dòng lệnh vừa gõ trên màn hình.
CMD = (f"dhclient vtnet1 ; route add -host 169.254.169.254 {gw} ; curl -fsS -H 'Metadata-Flavor: Google' "
       "http://169.254.169.254/computeMetadata/v1/instance/attributes/opnsense-config -o /tmp/boot.xml "
       "&& cp /tmp/boot.xml /conf/config.xml && echo BOOT''STRAP-OK && reboot")

deadline = time.time() + 900
last = None
poked = 0
while time.time() < deadline:
    lines = screen()
    tail = lines[-1] if lines else ""
    if any("BOOTSTRAP-OK" in l for l in lines):
        print("== đã nạp config bootstrap, OPNsense đang khởi động lại")
        break
    if re.search(r"(root@.*|^)\s*[#%]\s*$", tail) and "Enter an option" not in tail:
        if last != "CMD":
            print("== shell: tải config từ metadata"); send(CMD); last = "CMD"
        time.sleep(3); continue
    for rx, ans in ANSWERS:
        if re.search(rx, tail):
            if tail != last:
                print(f"  {tail.strip()[:60]!r} → {ans or '<ENTER>'}"); send(ans); last = tail
            break
    else:
        # màn hình đứng yên quá lâu ở dấu nhắc lạ: gõ Enter để console in lại dấu nhắc
        poked += 1
        if poked % 30 == 0:
            send("")
    time.sleep(2)
else:
    sys.exit("!! hết giờ, màn hình cuối:\n" + "\n".join(screen(15)))
time.sleep(5)
subprocess.run(["tmux", "kill-session", "-t", S], capture_output=True)
