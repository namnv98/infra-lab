#!/usr/bin/env bash
# Lab on-prem dựng trên GCP (OPNsense + DMZ + K8s kubeadm + Harbor/Squid + SIEM, giống ~/k8s-lab).
#   ./lab.sh image [26.7] dựng golden image OPNsense (bản nano gốc) ngay trên GCP bằng VM tạm
#   ./lab.sh plan        xem trước thay đổi hạ tầng
#   ./lab.sh up          sinh config bootstrap OPNsense + tạo/cập nhật hạ tầng bằng OpenTofu (hỏi xác nhận)
#   ./lab.sh fw-bootstrap  2 firewall mới: nạp config qua console, Ansible dựng VPN ở biên, rồi tag network cho cả hai qua VPN
#   ./lab.sh vpn up|down bật/tắt VPN WireGuard từ máy này vào lab (NetworkManager, kết nối "gcp-lab")
#   ./lab.sh ssh <máy|ip> [lệnh]  SSH tới máy trong lab (k8s-master-01, k8s-worker-01, infra-01, siem-01, edge-01, jump-01), xuyên qua jump server
#   ./lab.sh scp <nguồn> <đích>   chép file qua jump, vd. ./lab.sh scp app.tar k8s-master-01:/tmp/  (file out/ssh_config dùng được cho rsync)
#   ./lab.sh tunnel up|down  SOCKS 127.0.0.1:1080 qua jump: trình duyệt (Grafana, Harbor...) và kubectl
#   ./lab.sh browser     mở Chromium (profile riêng của lab) đi qua tunnel, sẵn các trang quản trị
#   ./lab.sh cluster     Ansible dựng toàn bộ theo ansible/site.yml: mạng → K8s → addon → dịch vụ → app → bảo mật ‖ SIEM → backup
#   ./lab.sh console [edge|core]  console nối tiếp của firewall (cứu hộ khi mất VPN)
#   ./lab.sh stop|start [máy…]  TẮT/BẬT VM (giữ nguyên cấu hình, ~0,07 USD/giờ khi tắt); không ghi máy = cả lab theo đúng thứ tự
#   ./lab.sh down        XOÁ SẠCH mọi tài nguyên (hỏi xác nhận) — dùng xong là xoá để không tốn credit
#   ./lab.sh cost        liệt kê tài nguyên còn trong project
set -euo pipefail
LAB=$(cd "$(dirname "$0")" && pwd)
cd "$LAB/tofu/envs/gcp"   # môi trường GCP (module dùng chung ở tofu/modules/)
PROJECT=$(awk -F'"' '/^project_id/{print $2}' terraform.tfvars)
ZONE=$(awk -F'"' '/^zone/{print $2}' terraform.tfvars)
REGION=$(awk -F'"' '/^region/{print $2}' terraform.tfvars)
IMAGE=opnsense-26-7-nano
PLAN="python3 -I $LAB/scripts/plan.py get"   # IP lấy từ envs/gcp/plan.yml (nguồn duy nhất)
JUMP=$($PLAN jump_ip)    # jump server (bastion) trong MGMT

case "${1:-plan}" in
  image)
    # Golden image = bản nano chính thức của OPNsense, dựng ngay trên GCP bằng VM tạm (kiểu Packer): không tải qua máy này
    V=${2:-26.7}; B=lab-imgbuild
    gcloud compute instances create $B --project "$PROJECT" --zone "$ZONE" --machine-type e2-small \
      --subnet lab-wan --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
      --create-disk name=$B-out,size=10,type=pd-balanced,auto-delete=no,device-name=out \
      --metadata opn-version="$V" --metadata-from-file startup-script="$LAB/scripts/build-opnsense-image.sh"
    echo "== chờ VM tạm tải + ghi image (tự tắt khi xong)"
    for i in $(seq 90); do
      [ "$(gcloud compute instances describe $B --zone "$ZONE" --project "$PROJECT" --format='value(status)')" = TERMINATED ] && break
      [ "$i" = 90 ] && { echo "!! quá 15 phút chưa xong, xem: gcloud compute instances get-serial-port-output $B --zone $ZONE"; exit 1; }
      sleep 10
    done
    # script chỉ tự tắt máy khi checksum đúng và ghi xong; lỗi thì VM vẫn chạy (xem log: get-serial-port-output)
    gcloud compute instances delete $B --zone "$ZONE" --project "$PROJECT" --quiet
    gcloud compute images delete "$IMAGE" --project "$PROJECT" --quiet 2>/dev/null || true
    gcloud compute images create "$IMAGE" --project "$PROJECT" --source-disk $B-out --source-disk-zone "$ZONE" \
      --storage-location "$REGION" --description "OPNsense $V nano (bản gốc của hãng, chưa cấu hình)"
    gcloud compute disks delete $B-out --zone "$ZONE" --project "$PROJECT" --quiet
    ;;
  plan) python3 -I "$LAB/scripts/plan.py" check && tofu init -input=false >/dev/null && tofu plan ;;
  up)
    # config bootstrap của OPNsense sinh từ cấu hình mặc định của đúng phiên bản + IP public hiện tại của máy admin
    F="$LAB/out/factory-config-26.7.xml"; mkdir -p "$LAB/out/logs"   # khuôn config OPNsense (cache, mất thì tự tải lại)
    # máy admin mới: khoá WireGuard admin (giữ nếu đã có) + khoá gcloud cho serial console (không passphrase, tránh kẹt prompt)
    [ -s "$LAB/out/wg-admin.key" ] || (umask 077; wg genkey > "$LAB/out/wg-admin.key"; wg pubkey < "$LAB/out/wg-admin.key" > "$LAB/out/wg-admin.pub")
    [ -s ~/.ssh/google_compute_engine ] || ssh-keygen -t rsa -b 3072 -N "" -q -f ~/.ssh/google_compute_engine
    [ -s "$F" ] || curl -fsSL -o "$F" https://raw.githubusercontent.com/opnsense/core/26.7/src/etc/config.xml.sample
    python3 -I "$LAB/scripts/plan.py" check || exit 1   # plan.yml sai (IP ngoài dải, trùng, quá số card) → dừng trước khi đụng GCP
    ADMIN_IP=$(curl -fsS https://api.ipify.org)
    for R in edge core; do python3 -I "$LAB/scripts/opnsense-bootstrap.py" "$F" "$LAB/out" "$ADMIN_IP" $R; done   # 2 firewall
    tofu init -input=false >/dev/null && tofu apply "${@:2}" ;;
  fw-bootstrap)
    # 2 firewall mới tạo: console → biên dựng VPN qua IP public → bật VPN → cấu hình đủ cả hai qua VPN.
    # Toàn bộ nằm trong ansible/site.yml (tag bootstrap chỉ chạy khi gọi đích danh) — xem 00-firewall-bootstrap.yml
    cd "$LAB/ansible"
    ansible-playbook site.yml --tags bootstrap,network ;;
  vpn)
    case "${2:-up}" in
      up)
        # Endpoint = IP VPN riêng (protocol forwarding → firewall biên); IP web chỉ còn 80/443
        FW=$(tofu output -raw vpn_public_ip)
        CONF="$LAB/out/gcp-lab.conf"; umask 077
        # /25 thay cho /24: cụ thể hơn route của lab local (virbr20...) nên đi qua VPN khi VPN bật, tắt VPN là lab local dùng lại bình thường
        cat > "$CONF" <<EOF
[Interface]
PrivateKey = $(cat "$LAB/out/wg-admin.key")
Address = $($PLAN vpn_admin)/32

[Peer]
PublicKey = $(cat "$LAB/out/wg-server.pub")
Endpoint = $FW:51820
AllowedIPs = $($PLAN vpn_allowed_ips)
PersistentKeepalive = 25
EOF
        nmcli connection delete gcp-lab >/dev/null 2>&1 || true
        nmcli connection import type wireguard file "$CONF" >/dev/null
        nmcli connection modify gcp-lab connection.autoconnect no ipv4.dns "$($PLAN dns)" ipv4.dns-search "~lab.internal"
        nmcli connection up gcp-lab
        ;;
      down) nmcli connection down gcp-lab ;;
    esac ;;
  ssh|scp)
    # VPN chỉ mở SSH tới jump server; máy khác đi xuyên qua jump (ProxyCommand), known_hosts riêng của lab cho cả 2 chặng.
    # Sinh out/ssh_config từ plan.yml: tên ngắn (k8s-master-01, infra-01...) dùng được cho ssh, scp, rsync -e "ssh -F out/ssh_config".
    C="$LAB/out/ssh_config"; KH="$LAB/out/known_hosts"
    {
      echo "# Sinh bởi lab.sh — đừng sửa tay"
      echo "Host *"
      echo "  User ubuntu"
      echo "  UserKnownHostsFile $KH"
      echo "  StrictHostKeyChecking accept-new"
      echo "Host jump-01 $JUMP"
      echo "  HostName $JUMP"
      $PLAN ssh_hosts | while read -r n ip; do
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
    SOCK="$LAB/out/tunnel.sock"
    case "${2:-up}" in
      up)
        if ss -ltn | grep -q '127.0.0.1:1080 '; then echo "tunnel đã chạy (127.0.0.1:1080)"; exit 0; fi
        ssh -f -N -M -S "$SOCK" -D 127.0.0.1:1080 -o ExitOnForwardFailure=yes \
          -o UserKnownHostsFile="$LAB/out/known_hosts" -o StrictHostKeyChecking=accept-new "ubuntu@$JUMP"
        kubectl config --kubeconfig "$LAB/out/kubeconfig" set "clusters.$(kubectl config --kubeconfig "$LAB/out/kubeconfig" view -o jsonpath='{.clusters[0].name}').proxy-url" socks5://127.0.0.1:1080 >/dev/null
        echo "SOCKS 127.0.0.1:1080 qua jump $JUMP — export KUBECONFIG=$LAB/out/kubeconfig" ;;
      down) ssh -S "$SOCK" -O exit "ubuntu@$JUMP" ;;
    esac ;;
  browser)
    # Profile riêng (out/browser): proxy SOCKS chỉ áp cho cửa sổ này, trình duyệt chính không bị ảnh hưởng.
    # Chromium gửi tên miền cho SOCKS5 → *.lab.internal được phân giải ở phía jump (DNS của OPNsense).
    ss -ltn | grep -q '127.0.0.1:1080 ' || "$LAB/lab.sh" tunnel up
    B=$(command -v chromium || command -v google-chrome-stable || command -v google-chrome) || { echo "!! cần chromium hoặc google-chrome"; exit 1; }
    nohup "$B" --user-data-dir="$LAB/out/browser" --proxy-server=socks5://127.0.0.1:1080 \
      --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" --no-first-run \
      $(for ip in $($PLAN fw_gui); do echo "https://$ip"; done) https://harbor.lab.internal http://mon.lab.internal:3000 http://mon.lab.internal:8025 \
      https://prometheus.int.lab.internal >/dev/null 2>&1 &
    echo "Đã mở trình duyệt lab (profile $LAB/out/browser)" ;;
  cluster)
    # Dựng toàn bộ trên VM theo ansible/site.yml (thứ tự nằm ở đó). Dừng ở bước lỗi đầu tiên.
    #   1) egress mở TẠM (Squid chưa có) → 2) nạp cache Harbor → 3) khoá egress → 4) 2 nhánh song song → 5) Velero
    cd "$LAB/ansible"
    ansible-playbook site.yml --tags network,kubernetes,addons,services,apps -e egress_temp_open=true
    ansible-playbook site.yml --tags prewarm
    ansible-playbook site.yml --tags network -e egress_temp_open=false
    # 2 nhánh: k8s = security (khởi động lại kube-apiserver) → metrics, tuần tự vì Helm không được chạy lúc đó;
    #          ops = SIEM + agent mọi máy (không đụng cluster)
    L="$LAB/out/logs"; mkdir -p "$L"
    echo "== song song: nhánh k8s ($L/lane-k8s.log) | nhánh ops ($L/lane-ops.log)"
    ansible-playbook site.yml --tags security,metrics > "$L/lane-k8s.log" 2>&1 & PK=$!
    ansible-playbook site.yml --tags siem > "$L/lane-ops.log" 2>&1 & PO=$!
    RK=0; RO=0; wait $PK || RK=$?; wait $PO || RO=$?
    for n in k8s ops; do grep -A12 "^PLAY RECAP" "$L/lane-$n.log" | tail -n +2 | sed "s/^/[$n] /" | grep . || true; done
    [ $RK = 0 ] && [ $RO = 0 ] || { echo "!! nhánh lỗi (k8s=$RK ops=$RO), xem log ở trên"; exit 1; }
    ansible-playbook site.yml --tags backup ;;
  console) gcloud compute connect-to-serial-port "firewall-${2:-edge}-01" --zone "$ZONE" --project "$PROJECT" ;;
  stop|start)
    # Tắt/bật theo tầng (plan.py start_order): firewall → jump → infra → master → worker → còn lại; tắt thì ngược lại.
    # Máy tắt: không tính tiền CPU/RAM, vẫn tính đĩa + IP tĩnh + forwarding rule (~0,07 USD/giờ thay vì ~0,33).
    G() { gcloud compute instances "$1" "${@:2}" --zone "$ZONE" --project "$PROJECT" --quiet; }   # G stop|start <máy…>
    wait_for() {  # wait_for <mô tả> <lệnh> — thử 5 giây/lần, tối đa 5 phút
      local i; for i in $(seq 60); do eval "$2" >/dev/null 2>&1 && { echo "   ✓ $1"; return 0; }; sleep 5; done
      echo "   ✗ $1: quá 5 phút — xem ./lab.sh console core"; return 1; }
    if [ $# -gt 1 ]; then echo "== $1: ${*:2}"; G "$1" "${@:2}"; exit; fi   # chỉ các máy ghi tên
    mapfile -t TIERS < <($PLAN start_order)
    if [ "$1" = stop ]; then
      for ((i = ${#TIERS[@]} - 1; i >= 0; i--)); do echo "== tắt: ${TIERS[i]}"; G stop ${TIERS[i]}; done
      nmcli connection down gcp-lab >/dev/null 2>&1 || true
      echo "Đã tắt cả lab (bật lại: make start)."; exit
    fi
    for t in "${TIERS[@]}"; do
      echo "== bật: $t"; G start $t
      if [[ $t == *firewall-* ]]; then        # VPN đi qua firewall biên; API core trả lời = định tuyến + DNS đã sẵn sàng
        nmcli -t connection show --active | grep -q '^gcp-lab:' || "$LAB/lab.sh" vpn up >/dev/null
        wait_for "firewall core trả lời qua VPN" "curl -sk -m 4 -o /dev/null https://$($PLAN dns)"
      elif [[ " $t " == *" $($PLAN group_hosts bastion) "* ]]; then
        wait_for "jump-01 mở SSH" "timeout 4 bash -c '</dev/tcp/$JUMP/22'"
      elif [[ " $t " == *" $($PLAN group_hosts k8s_control_plane | cut -d' ' -f1) "* ]]; then
        MASTER=$($PLAN group_ip k8s_control_plane)
        wait_for "K8s API sẵn sàng" "'$LAB/lab.sh' ssh $MASTER 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz'"
      fi
    done
    # Pod chạy lại sau khi node bật: chờ không còn pod nào khác Running/Completed (thường 2–4 phút)
    MASTER=$($PLAN group_ip k8s_control_plane)
    wait_for "mọi pod chạy lại" "[ \"\$('$LAB/lab.sh' ssh $MASTER 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --no-headers' 2>/dev/null | awk '\$4!=\"Running\" && \$4!=\"Completed\"' | wc -l)\" = 0 ]"
    echo "Đã bật cả lab. Tunnel: ./lab.sh tunnel up · kiểm tra: make test" ;;
  down) tofu destroy; echo "== Kiểm tra còn sót gì không =="; "$LAB/lab.sh" cost ;;
  cost)
    echo "== Project $PROJECT: tài nguyên còn lại =="
    gcloud compute instances list --project "$PROJECT" --format="table(name,zone.basename(),status,machineType.basename())"
    gcloud compute addresses list --project "$PROJECT" --format="table(name,address,status)"
    gcloud compute disks list --project "$PROJECT" --format="table(name,zone.basename(),sizeGb)"
    gcloud compute images list --project "$PROJECT" --no-standard-images --format="table(name,diskSizeGb)"
    echo "(image OPNsense giữ lại để lần sau dựng nhanh, ~0,05 USD/GB/tháng; xoá: gcloud compute images delete $IMAGE)"
    ;;
  *) sed -n "2,16p" "$LAB/lab.sh" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
