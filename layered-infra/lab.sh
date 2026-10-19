#!/usr/bin/env bash
# Lab hạ tầng nhiều lớp (OPNsense + DMZ + K8s kubeadm + Harbor/Squid + SIEM) — LỚP CẤU HÌNH, không quan tâm máy chạy ở đâu.
# Chỉ đọc inventory ansible/shared/inventory/hosts.yml (+ provisioned.yml). Chuyển nơi chạy = sửa IP trong hosts.yml.
# Tạo máy là bước riêng, tuỳ chọn: provision/<nền tảng>/ (vd. provision/gcp/gcp.sh) hoặc tự tạo tay đúng IP trong hosts.yml.
#   ./lab.sh fw-config   sinh config bootstrap 2 OPNsense (out/opnsense-<edge|core>-bootstrap.xml) — bước tạo máy nạp vào firewall
#   ./lab.sh fw-bootstrap  2 firewall đã nạp config: Ansible dựng VPN ở biên qua IP public, bật VPN, rồi tag firewall cho cả hai
#   ./lab.sh vpn up|down bật/tắt VPN WireGuard từ máy này vào lab (NetworkManager, kết nối "lab")
#   ./lab.sh ssh <máy|ip> [lệnh]  SSH tới máy trong lab (k8s-master-01, k8s-worker-01, infra-01, siem-01, edge-01, jump-01), xuyên qua jump server
#   ./lab.sh scp <nguồn> <đích>   chép file qua jump, vd. ./lab.sh scp app.tar k8s-master-01:/tmp/  (file out/ssh_config dùng được cho rsync)
#   ./lab.sh tunnel up|down  SOCKS 127.0.0.1:1080 qua jump: trình duyệt (Grafana, Harbor...) và kubectl
#   ./lab.sh browser     mở Chromium (profile riêng của lab) đi qua tunnel, sẵn các trang quản trị
#   ./lab.sh cluster     dựng toàn bộ, điều phối 3 team: network → platform → network (biên, khoá egress) → platform ‖ observability → backup
#   ./lab.sh network|platform|observability [tham số ansible-playbook]  chạy riêng site.yml của 1 team, vd. ./lab.sh network --tags firewall
set -euo pipefail
LAB=$(cd "$(dirname "$0")" && pwd)
OUT="$LAB/out"; mkdir -p "$OUT/logs"   # bí mật, kubeconfig, known_hosts, log
export ANSIBLE_INVENTORY="$LAB/ansible/shared/inventory"   # thư mục: hosts.yml (+ provisioned.yml)
INV="python3 -I $LAB/scripts/inventory.py get"   # mọi IP lấy từ inventory hosts.yml (nguồn duy nhất)
JUMP=$($INV jump_ip)    # jump server (bastion) trong MGMT
NM="lab"                 # tên kết nối VPN trong NetworkManager

case "${1:-}" in
  fw-config)
    # Config bootstrap của OPNsense sinh từ cấu hình mặc định của đúng phiên bản + hosts.yml + IP public hiện tại của máy admin
    # (luật BOOTSTRAP chỉ cho IP này gọi API biên qua WAN; Ansible xoá luật khi VPN đã chạy). Máy admin khác: ADMIN_IP=… ./lab.sh fw-config
    F="$OUT/factory-config-26.7.xml"   # khuôn config OPNsense (cache, mất thì tự tải lại)
    command -v wg >/dev/null || { echo "!! cần wireguard-tools (lệnh wg) để sinh khoá VPN của máy admin"; exit 1; }
    [ -s "$OUT/wg-admin.key" ] || (umask 077; wg genkey > "$OUT/wg-admin.key"; wg pubkey < "$OUT/wg-admin.key" > "$OUT/wg-admin.pub")
    [ -s "$F" ] || curl -fsSL -o "$F" https://raw.githubusercontent.com/opnsense/core/26.7/src/etc/config.xml.sample
    python3 -I "$LAB/scripts/inventory.py" check || exit 1   # hosts.yml sai (IP ngoài dải, trùng, quá số card) → dừng
    ADMIN_IP=${ADMIN_IP:-$(curl -fsS https://api.ipify.org)}
    for R in edge core; do python3 -I "$LAB/scripts/opnsense-bootstrap.py" "$F" "$OUT" "$ADMIN_IP" $R; done
    echo "Nạp 2 file trên vào firewall (GCP: make provision · máy dựng tay: USB /conf/config.xml hoặc console), rồi: make bootstrap" ;;
  fw-bootstrap)
    # 2 firewall đã nạp config bootstrap: biên dựng VPN qua IP public → bật VPN → cấu hình đủ cả hai qua VPN.
    # Toàn bộ nằm trong ansible/network/site.yml (tag bootstrap chỉ chạy khi gọi đích danh) — xem network/00-firewall-bootstrap.yml
    cd "$LAB/ansible"
    ansible-playbook network/site.yml --tags bootstrap,firewall ;;
  vpn)
    case "${2:-up}" in
      up)
        # Endpoint = IP VPN của biên (vpn_public_ip); AllowedIPs = các vùng trong + dải VPN
        # nmcli đặt tên kết nối theo tên file → file tên lab.conf (dùng được cả cho wg-quick / máy khác)
        CONF="$OUT/$NM.conf"; umask 077
        # /25 thay cho /24: cụ thể hơn route của lab local (virbr20...) nên đi qua VPN khi VPN bật, tắt VPN là lab local dùng lại bình thường
        cat > "$CONF" <<EOF
[Interface]
PrivateKey = $(cat "$OUT/wg-admin.key")
Address = $($INV vpn_admin)/32

[Peer]
PublicKey = $(cat "$OUT/wg-server.pub")
Endpoint = $($INV public_vpn):$($INV vpn_port)
AllowedIPs = $($INV vpn_allowed_ips)
PersistentKeepalive = 25
EOF
        nmcli connection delete "$NM" >/dev/null 2>&1 || true
        nmcli connection import type wireguard file "$CONF" >/dev/null
        nmcli connection modify "$NM" connection.autoconnect no ipv4.dns "$($INV dns)" ipv4.dns-search "~$($INV domain)"
        nmcli connection up "$NM"
        ;;
      down) nmcli connection down "$NM" ;;
    esac ;;
  ssh|scp)
    # VPN chỉ mở SSH tới jump server; máy khác đi xuyên qua jump (ProxyCommand), known_hosts riêng của môi trường cho cả 2 chặng.
    # Sinh out/ssh_config từ hosts.yml: tên ngắn (k8s-master-01, infra-01...) dùng được cho ssh, scp, rsync -e "ssh -F …".
    C="$OUT/ssh_config"; KH="$OUT/known_hosts"
    {
      echo "# Sinh bởi lab.sh — đừng sửa tay"
      echo "Host *"
      echo "  User ubuntu"
      echo "  UserKnownHostsFile $KH"
      echo "  StrictHostKeyChecking accept-new"
      echo "Host jump-01 $JUMP"
      echo "  HostName $JUMP"
      $INV ssh_hosts | while read -r n ip; do
        [ "$n" = jump-01 ] && continue
        echo "Host $n $ip"
        echo "  HostName $ip"
        echo "  ProxyCommand ssh -F $C -W %h:%p -q jump-01"
      done
    } > "$C"
    if [ "$1" = scp ]; then exec scp -F "$C" "${@:2}"; fi
    exec ssh -F "$C" "${2:?cần tên máy hoặc IP, vd. ./lab.sh ssh k8s-master-01}" "${@:3}" ;;
  tunnel)
    # SOCKS5 qua jump server: trình duyệt đặt proxy socks5://127.0.0.1:1080 (DNS qua proxy) để mở Grafana, Harbor...;
    # kubectl dùng proxy-url trong out/kubeconfig
    SOCK="$OUT/tunnel.sock"
    case "${2:-up}" in
      up)
        if ss -ltn | grep -q '127.0.0.1:1080 '; then echo "tunnel đã chạy (127.0.0.1:1080)"; exit 0; fi
        ssh -f -N -M -S "$SOCK" -D 127.0.0.1:1080 -o ExitOnForwardFailure=yes \
          -o UserKnownHostsFile="$OUT/known_hosts" -o StrictHostKeyChecking=accept-new "ubuntu@$JUMP"
        kubectl config --kubeconfig "$OUT/kubeconfig" set "clusters.$(kubectl config --kubeconfig "$OUT/kubeconfig" view -o jsonpath='{.clusters[0].name}').proxy-url" socks5://127.0.0.1:1080 >/dev/null
        echo "SOCKS 127.0.0.1:1080 qua jump $JUMP — export KUBECONFIG=$OUT/kubeconfig" ;;
      down) ssh -S "$SOCK" -O exit "ubuntu@$JUMP" ;;
    esac ;;
  browser)
    # Profile riêng (out/browser): proxy SOCKS chỉ áp cho cửa sổ này, trình duyệt chính không bị ảnh hưởng.
    # Chromium gửi tên miền cho SOCKS5 → tên nội bộ được phân giải ở phía jump (DNS của OPNsense).
    ss -ltn | grep -q '127.0.0.1:1080 ' || "$LAB/lab.sh" tunnel up
    B=$(command -v chromium || command -v google-chrome-stable || command -v google-chrome) || { echo "!! cần chromium hoặc google-chrome"; exit 1; }
    D=$($INV domain)
    nohup "$B" --user-data-dir="$OUT/browser" --proxy-server=socks5://127.0.0.1:1080 \
      --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" --no-first-run \
      $(for ip in $($INV fw_gui); do echo "https://$ip"; done) "https://harbor.$D" "http://mon.$D:3000" "http://mon.$D:8025" \
      "https://prometheus.$($INV gw_domain internal)" >/dev/null 2>&1 &
    echo "Đã mở trình duyệt lab (profile $OUT/browser)" ;;
  network|platform|observability)
    cd "$LAB/ansible"
    exec ansible-playbook "$1/site.yml" "${@:2}" ;;
  cluster)
    # Dựng toàn bộ trên VM: thứ tự GIỮA 3 team nằm ở đây, thứ tự trong 1 team nằm ở <team>/site.yml. Dừng ở bước lỗi đầu tiên.
    #   1) network mở egress TẠM (Harbor chưa có cache) → 2) platform dựng cluster, Harbor, app, cert vùng biên
    #   → 3) nạp cache Harbor → 4) network dựng vùng biên + khoá egress → 5) 2 nhánh song song → 6) Velero
    cd "$LAB/ansible"
    ansible-playbook network/site.yml --tags firewall -e egress_temp_open=true
    ansible-playbook platform/site.yml --tags kubernetes,addons,services,apps -e egress_temp_open=true
    ansible-playbook platform/site.yml --tags prewarm
    ansible-playbook network/site.yml --tags edge,firewall -e egress_temp_open=false
    # 2 nhánh: k8s = platform security (khởi động lại kube-apiserver) → metrics, tuần tự vì Helm không được chạy lúc đó;
    #          ops = observability: SIEM + agent mọi máy (không đụng cluster)
    L="$OUT/logs"; mkdir -p "$L"
    echo "== song song: nhánh k8s ($L/lane-k8s.log) | nhánh ops ($L/lane-ops.log)"
    ansible-playbook platform/site.yml --tags security,metrics > "$L/lane-k8s.log" 2>&1 & PK=$!
    ansible-playbook observability/site.yml > "$L/lane-ops.log" 2>&1 & PO=$!
    RK=0; RO=0; wait $PK || RK=$?; wait $PO || RO=$?
    for n in k8s ops; do grep -A12 "^PLAY RECAP" "$L/lane-$n.log" | tail -n +2 | sed "s/^/[$n] /" | grep . || true; done
    [ $RK = 0 ] && [ $RO = 0 ] || { echo "!! nhánh lỗi (k8s=$RK ops=$RO), xem log ở trên"; exit 1; }
    ansible-playbook platform/site.yml --tags backup ;;
  *) sed -n "2,13p" "$LAB/lab.sh" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
