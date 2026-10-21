# layered-infra — hạ tầng nhiều lớp kiểu doanh nghiệp (chạy trên GCP, có bản mẫu on-prem)

Mô hình on-prem (2 firewall OPNsense + DMZ + K8s kubeadm + Harbor/Squid + SIEM) dựng trên GCP,
**chỉ dùng phần GCP bắt buộc**: VPC, route, VM, đĩa, 2 IP public (web + VPN). Firewall, NAT, DNS, VPN, cửa vào,
registry, proxy, SIEM đều tự host. Mục tiêu: luyện đúng mô hình sẽ triển khai on-prem thật.

|             |                                                                                                   |
|-------------|---------------------------------------------------------------------------------------------------|
| Project GCP | `ultra-evening-511813-t2` (Free Trial, credit hết hạn 23/12/2026)                                 |
| Vùng        | `asia-southeast1-a`                                                                               |
| Tạo máy     | Tách rời, tuỳ chọn: GCP = OpenTofu `provision/gcp/` · máy nhà = libvirt `provision/libvirt/` · nơi khác = tự tạo đúng `hosts.yml` |
| Firewall    | OPNsense 26.7 (golden image = bản nano gốc của hãng)                                              |
| Quản trị    | VPN WireGuard trên OPNsense → chỉ tới **jump server** jump-01; mọi SSH/kubectl/GUI đi qua jump-01 |
| Kubernetes  | v1.37.1 kubeadm, Cilium 1.20.2, kube-vip, MetalLB, Gateway API, cert-manager                      |
| Tự động hoá | Ansible chia 3 team (`network` · `platform` · `observability`), hợp đồng chung `shared/`, IP từ inventory `hosts.yml` |

---

## Sơ đồ

Mô hình **2 firewall** (screened subnet): biên đối mặt Internet, core lọc mọi luồng vào trong.

```
Internet
   │  IP web (lab-fw-wan): chỉ tcp 80/443 → port forward edge-01
   │  IP VPN (lab-vpn, protocol forwarding): chỉ udp 51820 → WireGuard (Virtual IP trên WAN)
   ▼
┌─ firewall-edge-01 — BIÊN (OPNsense, e2-medium) ─┐
│ vtnet1 WAN 10.99.0.2 · vtnet0 DMZ 10.10.10.253   │  NAT (hybrid), port forward, VPN wg0 10.50.0.1/24
└──────────────────────┬──────────────────────────┘
        VPC lab-dmz 10.10.10.0/24 (vùng biên + trung chuyển)
        edge-01 10.10.10.10: HAProxy + WAF (OWASP CRS)
                       │  route VPC: 0/0 → biên .253 · 10.20/24, 10.40/24 → core .252
┌─ firewall-core-01 — CORE (OPNsense, e2-highcpu-4) ───────────────────────┐
│ vtnet1 DMZ 10.10.10.252 · vtnet0 LAN 10.20.0.253 · vtnet2 MGMT 10.40.0.253 │  KHÔNG NAT, không IP public
└──────────────┬───────────────────────────────────────┬────────────────────┘
   VPC lab-lan 10.20.0.0/24                 VPC lab-mgmt 10.40.0.0/24
   k8s-master-01 .11 (+VIP .10)             siem-01 .10: Loki, Alloy, Grafana, Mailpit, Wazuh
   k8s-worker-01 .21 (+.200 .210)           jump-01 .20: bastion
   infra-01 .30: Harbor, Squid, S3, Loki bản sao

VPN quản trị: máy admin 10.50.0.2 ⇄ IP VPN ⇄ wg0 trên biên → chỉ tới jump-01:22 (qua core) và GUI/API 2 firewall :443
```

- Mỗi vùng là **1 VPC riêng** (VM nhiều card phải có mỗi card ở 1 VPC khác nhau; số card ≤ số vCPU).
- VPC lan/dmz/mgmt **không có route Internet của GCP**; route của VPC trỏ vào card firewall (bảng ở trên).
- VIP `10.20.0.10` (kube-vip) và IP Gateway `.200`/`.210` (MetalLB) là **alias IP** do GCP định tuyến tới
  k8s-master-01/k8s-worker-01.
- GCP giữ `.0 .1 .254 .255` của mỗi subnet nên firewall dùng `.253`/`.252`.
- DMZ **không phân giải được tên nội bộ** (DNS `lab.internal` chỉ ở core).

| VM               | Loại               | Vai trò                                                                                   |
|------------------|--------------------|-------------------------------------------------------------------------------------------|
| firewall-edge-01 | e2-medium, 10GB    | Firewall BIÊN (OPNsense): NAT, port forward, VPN WireGuard, DNS công cộng, NTP cho DMZ    |
| firewall-core-01 | e2-highcpu-4, 10GB | Firewall CORE (OPNsense): lọc DMZ → LAN/MGMT và giữa các vùng, DNS nội bộ, NTP; không NAT |
| edge-01          | e2-small, 10GB     | Vùng biên: HAProxy (TLS, LB) + WAF ModSecurity/OWASP CRS (container)                      |
| k8s-master-01    | e2-medium, 30GB    | control-plane + etcd + kube-vip                                                           |
| k8s-worker-01    | e2-medium, 30GB    | worker, Gateway, app demo (hạ từ e2-standard-2 để vừa quota)                              |
| infra-01         | e2-medium, 50GB    | Harbor (proxy-cache image) + Squid (proxy egress có allowlist) + Garage S3 + Loki bản sao |
| siem-01          | e2-medium, 30GB    | SIEM: Loki, Alloy, Grafana, Mailpit, Wazuh manager                                        |
| jump-01          | e2-micro, 10GB     | Jump server (bastion): SSH chỉ bằng khoá, ghi phiên (pam_tty_audit → SIEM)                |

---

## Cấu trúc thư mục

```
layered-infra/
├── Makefile          # cửa vào chuẩn: fw-config · provision · bootstrap · cluster · test · network/platform/observability
├── lab.sh            # LỚP CẤU HÌNH: fw-config, fw-bootstrap, vpn, ssh, tunnel, browser, cluster — chỉ đọc inventory hosts.yml
├── provision/        # LỚP TẠO MÁY — tuỳ chọn, mỗi nền tảng 1 thư mục, xoá đi lớp cấu hình vẫn chạy
│   ├── gcp/          # OpenTofu (main.tf + modules/{network,firewall,vm}) · gcp.sh (up, image, console, stop/start, down, cost)
│   │                 #   · fw-load-config.py (nạp config bootstrap qua serial console) · build-opnsense-image.sh · provision.mk
│   └── libvirt/      # máy nhà (KVM): libvirt.sh (use/restore, image, up, console, stop/start, down) · provisioned.yml (IP public + biến riêng) · provision.mk
├── scripts/
│   ├── inventory.py              # đọc/kiểm tra inventory hosts.yml (+ provisioned.yml) cho lab.sh, smoke.sh, gcp.sh, bootstrap OPNsense
│   ├── opnsense-bootstrap.py     # sinh config.xml bootstrap từ config mặc định của hãng
│   └── harbor-prewarm.sh         # nạp cache Harbor bằng image cluster đang dùng
├── ansible/          # mỗi team 1 thư mục: network/ · platform/ · observability/ (site.yml + group_vars + roles riêng)
│                     #   + shared/ (inventory/hosts.yml ★ NGUỒN IP DUY NHẤT, viết tay + hợp đồng giữa các team)  (đọc docs/ansible-doc.md)
├── test/smoke.sh     # kiểm thử đầu-cuối trên lab đang chạy (make test): web/WAF, VPN, egress, DMZ, cluster, prod, SIEM
├── docs/             # architecture.html (sơ đồ, luồng, ma trận luật — sinh từ docs/src/*.py) · ansible-doc.md · examples/onprem/ (ví dụ inventory on-prem)
├── .editorconfig · .yamllint   # định dạng chung, luật yamllint (pre-commit + CI ở gốc repo: ../.pre-commit-config.yaml, ../.github/)
└── out/              # bí mật, kubeconfig, known_hosts, log — KHÔNG commit (đã có trong .gitignore)
```

---

## Dựng từ đầu

Hai lớp tách rời, nối với nhau chỉ bằng inventory `ansible/shared/inventory/hosts.yml` (viết tay). Ansible không quan tâm máy
chạy ở đâu: **chuyển nơi chạy = sửa IP trong `hosts.yml`**.

| Lớp | Việc | GCP (có bộ tạo máy `provision/gcp/`) | Máy có sẵn / on-prem |
|---|---|---|---|
| **Tạo máy** (tuỳ chọn) | máy chạy đúng IP trong hosts.yml, 2 firewall đã nạp config bootstrap, IP public biết trước | `make provision` (tofu + console) | tự tạo; cài OPNsense, nạp config qua USB/console; ghi `fw_public_ip`/`vpn_public_ip` vào hosts.yml |
| **Cấu hình** (giống nhau) | firewall → K8s → dịch vụ → bảo mật → SIEM → backup → kiểm thử | `make bootstrap cluster test` | `make bootstrap cluster test` |

Cần: `ansible`, `nmcli` (NetworkManager), `wg` (wireguard-tools), khoá `~/.ssh/id_ed25519`. Riêng GCP: `gcloud` đã đăng nhập, `tofu`.

```bash
cd ~/labs/infra-lab/layered-infra
make fw-config          # sinh config bootstrap 2 OPNsense từ hosts.yml → out/opnsense-<edge|core>-bootstrap.xml
make provision          # GCP: tofu apply (hỏi xác nhận) → ghi IP public → nạp config vào firewall qua serial console
                        #   (lần đầu: make gcp-image — golden image OPNsense ~5 phút). Không có bộ tạo máy: in ra việc cần tự làm
make bootstrap          # API biên qua IP public dựng VPN → bật VPN → network/10-firewall.yml cho cả hai qua VPN
make cluster            # network → platform (K8s, Harbor, app) → nạp cache → network (biên, khoá egress) → platform ‖ observability → backup (~25 phút)
make test               # kiểm thử đầu-cuối (~2 phút): 33 kiểm thử, thoát lỗi nếu có kiểm thử không đạt (./test/smoke.sh prod: chỉ 1 nhóm)
make gcp-stop           # [GCP] TẮT cả lab, giữ cấu hình (~0,07 USD/giờ thay vì ~0,33) · make gcp-start: bật lại theo tầng (~5 phút)
```

**Máy nhà (KVM/libvirt)**: `make libvirt-use fw-config provision bootstrap cluster test` — xem `provision/libvirt/README.md`
(~20GB RAM, 8 VM, cùng IP với GCP — chỉ khác IP public; quay lại GCP: `make libvirt-restore`, không đổi file nào trong git).

**Chuyển sang máy tự tạo / on-prem**: sửa `ansible/shared/inventory/hosts.yml` (IP, card, vùng, `node_*`, IP public) và luật
firewall `ansible/network/host_vars/firewall-*.yml` nếu topology đổi — ví dụ đầy đủ ở `docs/examples/onprem/` — rồi
`make fw-config bootstrap cluster test`. Không cần tofu, gcloud hay thư mục `provision/`.

Trước khi commit: `make lint` (yamllint, ansible-lint, tofu fmt, kiểm tra IP trong hosts.yml) và `make validate`
(cú pháp Ansible mọi team + tofu của bộ tạo máy). CI trên GitHub chạy đúng 2 lệnh này mỗi lần push.

Ghi chú GCP: `make gcp-image` và `make provision` lần đầu đều cần VPC `lab-wan` (VM tạm dựng image nằm trong đó),
nên nếu chưa có hạ tầng thì tạo mạng trước: `tofu -chdir=provision/gcp apply -target=module.network`.

---

## Ansible

Từng file trong `ansible/` làm gì: **`docs/ansible-doc.md`**.

Mỗi team một thư mục, **không gọi role/biến của team khác** (Ansible chỉ thấy `group_vars/` và `roles/` cạnh playbook đang chạy):

| Team | Thư mục | Lo |
|---|---|---|
| network | `ansible/network/` | 2 firewall, VPN, bastion, DNS/NTP mọi VM, Squid (egress), vùng biên HAProxy + WAF |
| platform | `ansible/platform/` | K8s, addon, Harbor + S3 trên infra-01, app, bảo mật cluster, Prometheus, backup |
| observability | `ansible/observability/` | SIEM trên siem-01, bản sao log, agent log/audit/Wazuh trên mọi máy |
| (chung) | `ansible/shared/` | **inventory `hosts.yml`** (viết tay) + **hợp đồng** `contract.yml` (biến team này cung cấp cho team khác), đường dẫn, đặc thù máy |

Hai team trao đổi qua dữ liệu, không gọi chéo: `shared/` (IP, cổng syslog, proxy, Harbor), và file trong
`out/` (platform ghi cert vùng biên `edge-tls.pem` → network cài lên edge-01). Thứ tự GIỮA các team: `lab.sh cluster`.

```bash
make network ARGS='--tags firewall'               # [network] sau khi sửa luật firewall (network/host_vars/firewall-*.yml)
make platform ARGS='--tags coredns'               # [platform] CoreDNS đọc lại DNS sau khi network đổi DNS của node
make observability                                # [observability] sửa SIEM/cảnh báo
cd ansible && ansible-playbook platform/site.yml --list-tags   # tag mỗi team: xem đầu <team>/site.yml
cd ansible && ansible-lint                        # kiểm tra trước khi chạy (.ansible-lint)
cd ansible && ansible-playbook platform/ops-upgrade-cluster.yml   # nâng cấp K8s sau khi đổi k8s_version: drain từng node
cd ansible && ansible-playbook platform/ops-etcd-restore.yml      # khôi phục etcd từ snapshot (phá huỷ thay đổi sau snapshot)
```

**Đổi IP / thêm máy**: chỉ sửa `ansible/shared/inventory/hosts.yml` → `make lint` (IP ngoài dải, trùng, IP GCP giữ, quá số
card) → tạo/sửa máy (GCP: `make gcp-plan`, `make provision`) → chạy Ansible. Ansible, alias firewall, config bootstrap OPNsense,
`lab.sh`, `harbor-prewarm.sh`, `smoke.sh` và tofu của GCP đều đọc thẳng file đó.

## Vận hành hằng ngày

```bash
./lab.sh vpn up | down      # bật/tắt VPN (kết nối NetworkManager "lab", không cần sudo)
make gcp-console FW=core    # [GCP] serial console của firewall — cứu hộ khi mất VPN
make gcp-plan               # [GCP] xem trước thay đổi hạ tầng
make gcp-cost               # [GCP] liệt kê VM, IP, đĩa, image còn trong project
make gcp-down               # [GCP] XOÁ SẠCH hạ tầng (hỏi xác nhận) — dùng xong là chạy
./lab.sh ssh k8s-master-01             # SSH vào VM theo tên hoặc IP, xuyên qua jump-01 (VPN chỉ vào được jump-01)
./lab.sh scp file k8s-master-01:/tmp/  # upload/download file qua jump-01
./lab.sh tunnel up | down    # SOCKS 127.0.0.1:1080 qua jump-01 — trình duyệt + kubectl
./lab.sh browser            # mở Chromium đi qua tunnel, sẵn các trang quản trị (xem mục dưới)
export KUBECONFIG=~/labs/infra-lab/layered-infra/out/kubeconfig   # kubectl (cần tunnel up: kubeconfig có proxy-url SOCKS)
```

---

## Vào các trang quản trị nội bộ

Không trang nào mở ra Internet. Đường vào duy nhất: **VPN → jump server → trang cần vào**.

```
Trình duyệt ──SOCKS 127.0.0.1:1080──► ssh ──VPN WireGuard──► jump-01 (10.40.0.20) ──► Grafana, Harbor, Prometheus...
```

VPN chỉ cho tới jump-01:22 và GUI OPNsense; gõ thẳng `http://10.40.0.10:3000` khi chỉ bật VPN sẽ **bị firewall chặn**
(đúng thiết kế).

### Cách nhanh nhất

```bash
cd ~/labs/infra-lab/layered-infra
./lab.sh vpn up       # 1. bật VPN
./lab.sh browser      # 2. tự bật tunnel + mở Chromium (profile riêng của lab) với sẵn các trang bên dưới
```

Cửa sổ này dùng profile riêng `out/browser`, chỉ nó đi qua tunnel. Trình duyệt chính của bạn không bị ảnh hưởng.

### Các trang

| Trang                                | Địa chỉ                             | Đăng nhập                             |
|--------------------------------------|-------------------------------------|---------------------------------------|
| Firewall biên                        | https://10.10.10.253                | `root` / `out/opnsense-edge-root.txt` |
| Firewall core                        | https://10.20.0.253                 | `root` / `out/opnsense-core-root.txt` |
| Harbor (registry)                    | https://harbor.lab.internal         | `admin` / `out/harbor-admin.txt`      |
| Grafana (SIEM: log, cảnh báo, Wazuh) | http://mon.lab.internal:3000        | `admin` / `out/grafana-admin.txt`     |
| Mailpit (email cảnh báo)             | http://mon.lab.internal:8025        | không cần                             |
| Prometheus (metric cluster)          | https://prometheus.int.lab.internal | không cần                             |
| App demo, đường nội bộ               | https://whoami.int.lab.internal     | không cần                             |

Xem mật khẩu: `cat out/grafana-admin.txt` (tương tự các file khác). Tên miền `*.lab.internal` do Unbound trên OPNsense
phân giải, ở **phía jump-01**, nên máy bạn không cần sửa `/etc/hosts`.

### Dùng trình duyệt khác (Firefox)

```bash
./lab.sh tunnel up
```

Firefox → Settings → Network Settings → **Manual proxy configuration**: SOCKS Host `127.0.0.1`, Port `1080`,
**SOCKS v5**, tick **Proxy DNS when using SOCKS v5** (thiếu ô này sẽ báo "Server not found" với `*.lab.internal`).
Nên tạo profile riêng (`firefox -P`) để trình duyệt chính không đi qua lab.

### Bỏ cảnh báo chứng chỉ

Cert do CA riêng của lab ký (`out/lab-ca.crt`), nên trình duyệt báo "Not secure". Lab nào cũng vậy; muốn hết cảnh báo
thì import CA một lần:

- Chromium/Chrome: `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n gcp-lab-ca -i out/lab-ca.crt`
  (xoá: `certutil -d sql:$HOME/.pki/nssdb -D -n gcp-lab-ca`)
- Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import → `out/lab-ca.crt`
  → tick "Trust this CA to identify websites"

Mỗi lần dựng lại lab từ đầu, CA mới được sinh ra, nên phải import lại.

### Không phải trình duyệt

```bash
./lab.sh ssh k8s-master-01                               # SSH theo tên (k8s-master-01, k8s-worker-01, infra-01, siem-01, edge-01, jump-01) hoặc IP, xuyên qua jump-01
./lab.sh ssh infra-01 'df -h /'                    # chạy 1 lệnh rồi thoát
./lab.sh scp ./app.tar k8s-master-01:/tmp/               # upload (xuyên qua jump-01, jump-01 không giữ lại file)
./lab.sh scp infra-01:/var/log/syslog ./           # download
rsync -av -e "ssh -F out/ssh_config" ./dir/ infra-01:/tmp/dir/   # thư mục lớn, chép tiếp khi đứt
ssh -F out/ssh_config k8s-master-01                      # dùng thẳng ssh/scp/sftp với file cấu hình lab.sh sinh ra
export KUBECONFIG=~/labs/infra-lab/layered-infra/out/kubeconfig # kubectl (cần tunnel up; kubeconfig có proxy-url SOCKS)
kubectl get nodes
curl --socks5-hostname 127.0.0.1:1080 --cacert out/lab-ca.crt https://harbor.lab.internal/api/v2.0/health
```

### Tắt

```bash
./lab.sh tunnel down
./lab.sh vpn down
```

### Sự cố thường gặp

| Hiện tượng                                        | Nguyên nhân / cách xử lý                                                                                  |
|---------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| Trang quay mãi rồi timeout                        | Tunnel chưa bật (`ss -ltn \| grep 1080`) hoặc VPN tắt (`nmcli connection show --active \| grep lab`). |
| "Server not found" với `*.lab.internal`           | Trình duyệt tự phân giải tên: Firefox chưa tick "Proxy DNS when using SOCKS v5".                          |
| Mở `http://10.40.0.10:3000` không được dù VPN bật | Đúng thiết kế: VPN không vào thẳng máy trong. Dùng `./lab.sh browser` hoặc bật SOCKS.                     |
| `tunnel up` báo lỗi "cannot listen to port: 1080" | Cổng 1080 đang bị chương trình khác dùng: `ss -ltnp \| grep 1080`.                                        |
| Tunnel treo sau khi máy ngủ / đổi mạng            | `./lab.sh tunnel down; ./lab.sh tunnel up`.                                                               |
| `REMOTE HOST IDENTIFICATION HAS CHANGED`          | Lab vừa dựng lại, máy mới có khoá mới: `ssh-keygen -f out/known_hosts -R 10.40.0.20` (và IP máy báo lỗi). |
| VPN bật nhưng không vào được gì                   | IP public đổi sau khi dựng lại: chạy lại `./lab.sh vpn up` (lấy IP mới từ plan / `provisioned.yml`).      |
| Grafana đăng nhập sai mật khẩu                    | Mật khẩu sinh mới mỗi lần dựng từ đầu (`out/` trống): xem lại `out/grafana-admin.txt`.                    |

App demo từ Internet (đi qua WAF ở vùng biên, không cần VPN):
`curl --resolve whoami.apps.lab.internal:443:<IP public> --cacert out/lab-ca.crt https://whoami.apps.lab.internal/`
(IP public: `python3 scripts/inventory.py get public_web`).

---

## Chi phí

8 VM + 2 IP public + 1 forwarding rule ≈ **0,33 USD/giờ** (quota Free Trial: 11/12 vCPU, 8/8 VM), trừ vào credit Free
Trial. Image OPNsense được giữ lại để lần sau dựng nhanh (< 0,1 USD/tháng). **Dùng xong chạy `make gcp-down`**, rồi `make gcp-cost` để chắc không còn sót gì.
