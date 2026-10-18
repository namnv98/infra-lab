#!/usr/bin/env bash
# Làm nóng cache Harbor: kéo trước qua Harbor mọi image cluster đang dùng, để node không phải chờ
# Harbor tải lần đầu từ Internet (dễ timeout khi mạng chậm). Chạy TRƯỚC khi siết egress, và sau mỗi
# lần nâng cấp/thêm app.
#   scripts/harbor-prewarm.sh            # lấy danh sách từ cluster
#   scripts/harbor-prewarm.sh img1 img2  # hoặc chỉ định
set -uo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd)
PLAN="python3 -I $LAB/scripts/plan.py get"   # IP từ envs/gcp/plan.yml
SVC=ubuntu@$($PLAN group_ip infra)
CP=ubuntu@$($PLAN group_ip k8s_control_plane)
JUMP=ubuntu@$($PLAN jump_ip)
HARBOR=harbor.lab.internal
# máy admin chỉ SSH được tới jump server → đi xuyên qua nó (known_hosts riêng của lab cho cả 2 chặng)
KH="-o BatchMode=yes -o UserKnownHostsFile=$LAB/out/known_hosts -o StrictHostKeyChecking=accept-new"
rssh() { local h=$1; shift; ssh $KH -o ProxyCommand="ssh -W %h:%p -q $KH $JUMP" "$h" "$@"; }

if [ $# -gt 0 ]; then images=("$@"); else
  mapfile -t images < <(rssh $CP sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A \
    -o "jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{range .spec.initContainers[*]}{.image}{\"\\n\"}{end}{end}'" \
    | grep -v ':latest$' | sort -u)
  images+=(registry.k8s.io/pause:3.10.1 registry.k8s.io/pause:3.10.2)
fi

# registry ngoài → project proxy-cache trong Harbor
to_harbor() {
  local i=$1
  case $i in
    registry.k8s.io/*) echo "$HARBOR/k8s/${i#registry.k8s.io/}" ;;
    quay.io/*)         echo "$HARBOR/quay/${i#quay.io/}" ;;
    ghcr.io/*)         echo "$HARBOR/ghcr/${i#ghcr.io/}" ;;
    docker.io/*)       echo "$HARBOR/dockerhub/${i#docker.io/}" ;;
    */*)               echo "$HARBOR/dockerhub/$i" ;;            # traefik/whoami
    *)                 echo "$HARBOR/dockerhub/library/$i" ;;    # nginx
  esac
}

ok=0; fail=0
for i in "${images[@]}"; do
  h=$(to_harbor "$i")      # image ghim digest (name:tag@sha256:...) giữ nguyên phần @digest
  for try in 1 2 3; do
    t0=$(date +%s)
    # Kéo qua Harbor (Harbor tải từ Internet và giữ lại), rồi xoá bản trên infra-01 cho đỡ tốn đĩa
    if rssh $SVC "sudo timeout 900 docker pull -q '$h' >/dev/null 2>&1"; then
      rssh $SVC "sudo docker rmi '$h' >/dev/null 2>&1" || true
      printf "OK   %4ss  %s\n" "$(( $(date +%s)-t0 ))" "$i"; ok=$((ok+1)); break
    fi
    if [ $try -eq 3 ]; then printf "LỖI        %s\n" "$i"; fail=$((fail+1)); else sleep 10; fi
  done
done
echo "Xong: $ok OK, $fail lỗi"
