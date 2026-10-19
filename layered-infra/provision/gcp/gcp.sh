#!/usr/bin/env bash
# BỘ TẠO MÁY cho GCP — TUỲ CHỌN. Xoá cả provision/gcp/ thì lớp cấu hình (make bootstrap/cluster/test) vẫn chạy với máy tạo cách khác.
# Hợp đồng với lớp cấu hình (giống mọi bộ tạo máy, kể cả tạo tay):
#   1) máy chạy đúng tên/IP/card trong envs/gcp/plan.yml
#   2) 2 firewall đã nạp out/gcp/opnsense-<edge|core>-bootstrap.xml (make fw-config sinh trước)
#   3) IP public của biên ghi vào envs/gcp/provisioned.yml (public: web, vpn)
#   gcp.sh image [26.7]   dựng golden image OPNsense (bản nano gốc) ngay trên GCP bằng VM tạm
#   gcp.sh plan           xem trước thay đổi hạ tầng
#   gcp.sh up             tofu apply (hỏi xác nhận) → ghi provisioned.yml → nạp config bootstrap vào firewall MỚI qua console
#   gcp.sh console [edge|core]  console nối tiếp của firewall (cứu hộ khi mất VPN)
#   gcp.sh stop|start [máy…]    TẮT/BẬT VM (giữ nguyên cấu hình, ~0,07 USD/giờ khi tắt); không ghi máy = cả lab theo đúng thứ tự
#   gcp.sh down           XOÁ SẠCH mọi tài nguyên (hỏi xác nhận) — dùng xong là xoá để không tốn credit
#   gcp.sh cost           liệt kê tài nguyên còn trong project
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LAB=$(cd "$HERE/../.." && pwd)
export LAB_ENV=gcp
OUT="$LAB/out/gcp"; mkdir -p "$OUT"
cd "$HERE"
PROJECT=$(awk -F'"' '/^project_id/{print $2}' terraform.tfvars)
ZONE=$(awk -F'"' '/^zone/{print $2}' terraform.tfvars)
REGION=$(awk -F'"' '/^region/{print $2}' terraform.tfvars)
IMAGE=opnsense-26-7-nano
PLAN="python3 -I $LAB/scripts/plan.py get"

G() { gcloud compute instances "$1" "${@:2}" --zone "$ZONE" --project "$PROJECT" --quiet; }   # G <lệnh> <máy…>

load_config() {  # load_config <firewall>: console → đăng nhập mặc định → tải config từ metadata → khởi động lại
  # tải config qua card vtnet1 (card thứ 2 trong plan.yml) → cần gateway VPC của vùng chứa card đó
  local gw
  gw=$(python3 - "$LAB/scripts" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import plan
p = plan.load(); print(p["zones"][p["firewalls"][sys.argv[2]]["nics"][1]["zone"]]["gateway"])
PY
)
  python3 -I "$HERE/fw-load-config.py" "$1" "$ZONE" "$PROJECT" "$gw"
}

case "${1:-}" in
  image)
    # Golden image = bản nano chính thức của OPNsense, dựng ngay trên GCP bằng VM tạm (kiểu Packer): không tải qua máy này
    V=${2:-26.7}; B=lab-imgbuild
    gcloud compute instances create $B --project "$PROJECT" --zone "$ZONE" --machine-type e2-small \
      --subnet lab-wan --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
      --create-disk name=$B-out,size=10,type=pd-balanced,auto-delete=no,device-name=out \
      --metadata opn-version="$V" --metadata-from-file startup-script="$HERE/build-opnsense-image.sh"
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
    for R in edge core; do
      [ -s "$OUT/opnsense-$R-bootstrap.xml" ] || { echo "!! thiếu $OUT/opnsense-$R-bootstrap.xml — chạy make fw-config trước"; exit 1; }
    done
    # khoá gcloud cho serial console (không passphrase, tránh kẹt prompt)
    [ -s ~/.ssh/google_compute_engine ] || ssh-keygen -t rsa -b 3072 -N "" -q -f ~/.ssh/google_compute_engine
    tofu init -input=false >/dev/null && tofu apply "${@:2}"
    # (3) IP public do GCP cấp → lớp cấu hình đọc qua plan.py (public.web, public.vpn)
    cat > "$LAB/envs/gcp/provisioned.yml" <<EOF
# Sinh bởi provision/gcp/gcp.sh sau tofu apply — đừng sửa tay (gcp.sh down xoá file này)
public: { web: $(tofu output -raw fw_public_ip), vpn: $(tofu output -raw vpn_public_ip) }
EOF
    # (2) firewall MỚI (id VM chưa có dấu "đã nạp"): nạp config song song; firewall đã nạp (kể cả sau stop/start) thì bỏ qua
    PIDS=()
    for fw in $($PLAN fw_names); do
      ID=$(G describe "$fw" --format='value(id)')
      [ -e "$OUT/.config-loaded-$fw-$ID" ] && continue
      echo "== $fw: nạp config bootstrap qua console"
      (load_config "$fw" > "$OUT/logs-console-$fw.txt" 2>&1 && touch "$OUT/.config-loaded-$fw-$ID") & PIDS+=($!)
    done
    for p in "${PIDS[@]}"; do wait "$p" || { echo "!! nạp config lỗi, xem $OUT/logs-console-*.txt"; exit 1; }; done
    echo "Máy đã sẵn sàng theo plan. Tiếp: make bootstrap" ;;
  console) gcloud compute connect-to-serial-port "firewall-${2:-edge}-01" --zone "$ZONE" --project "$PROJECT" ;;
  stop|start)
    # Tắt/bật theo tầng (plan.py start_order): firewall → jump → infra → master → worker → còn lại; tắt thì ngược lại.
    # Máy tắt: không tính tiền CPU/RAM, vẫn tính đĩa + IP tĩnh + forwarding rule (~0,07 USD/giờ thay vì ~0,33).
    wait_for() {  # wait_for <mô tả> <lệnh> — thử 5 giây/lần, tối đa 5 phút
      local i; for i in $(seq 60); do eval "$2" >/dev/null 2>&1 && { echo "   ✓ $1"; return 0; }; sleep 5; done
      echo "   ✗ $1: quá 5 phút — xem $0 console core"; return 1; }
    if [ $# -gt 1 ]; then echo "== $1: ${*:2}"; G "$1" "${@:2}"; exit; fi   # chỉ các máy ghi tên
    mapfile -t TIERS < <($PLAN start_order)
    if [ "$1" = stop ]; then
      for ((i = ${#TIERS[@]} - 1; i >= 0; i--)); do echo "== tắt: ${TIERS[i]}"; G stop ${TIERS[i]}; done
      nmcli connection down lab-gcp >/dev/null 2>&1 || true
      echo "Đã tắt cả lab (bật lại: make gcp-start)."; exit
    fi
    for t in "${TIERS[@]}"; do
      echo "== bật: $t"; G start $t
      if [[ $t == *firewall-* ]]; then        # VPN đi qua firewall biên; API core trả lời = định tuyến + DNS đã sẵn sàng
        nmcli -t connection show --active | grep -q '^lab-gcp:' || "$LAB/lab.sh" vpn up >/dev/null
        wait_for "firewall core trả lời qua VPN" "curl -sk -m 4 -o /dev/null https://$($PLAN dns)"
      elif [[ " $t " == *" $($PLAN group_hosts bastion) "* ]]; then
        wait_for "jump-01 mở SSH" "timeout 4 bash -c '</dev/tcp/$($PLAN jump_ip)/22'"
      elif [[ " $t " == *" $($PLAN group_hosts k8s_control_plane | cut -d' ' -f1) "* ]]; then
        MASTER=$($PLAN group_ip k8s_control_plane)
        wait_for "K8s API sẵn sàng" "'$LAB/lab.sh' ssh $MASTER 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz'"
      fi
    done
    # Pod chạy lại sau khi node bật: chờ không còn pod nào khác Running/Completed (thường 2–4 phút)
    MASTER=$($PLAN group_ip k8s_control_plane)
    wait_for "mọi pod chạy lại" "[ \"\$('$LAB/lab.sh' ssh $MASTER 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --no-headers' 2>/dev/null | awk '\$4!=\"Running\" && \$4!=\"Completed\"' | wc -l)\" = 0 ]"
    echo "Đã bật cả lab. Tunnel: ./lab.sh tunnel up · kiểm tra: make test" ;;
  down)
    tofu destroy
    rm -f "$LAB/envs/gcp/provisioned.yml" "$OUT"/.config-loaded-*
    echo "== Kiểm tra còn sót gì không =="; "$0" cost ;;
  cost)
    echo "== Project $PROJECT: tài nguyên còn lại =="
    gcloud compute instances list --project "$PROJECT" --format="table(name,zone.basename(),status,machineType.basename())"
    gcloud compute addresses list --project "$PROJECT" --format="table(name,address,status)"
    gcloud compute disks list --project "$PROJECT" --format="table(name,zone.basename(),sizeGb)"
    gcloud compute images list --project "$PROJECT" --no-standard-images --format="table(name,diskSizeGb)"
    echo "(image OPNsense giữ lại để lần sau dựng nhanh, ~0,05 USD/GB/tháng; xoá: gcloud compute images delete $IMAGE)"
    ;;
  *) sed -n "2,13p" "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
