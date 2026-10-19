#!/usr/bin/env bash
# Kiểm thử đầu-cuối trên lab ĐANG CHẠY (sau make cluster). Cần VPN bật (make vpn). Không đổi gì trên lab.
# Không quan tâm máy chạy ở đâu: mọi IP từ ansible/shared/inventory/hosts.yml, không hỏi bộ tạo máy.
# Mỗi dòng: tên kiểm thử, mong đợi, thực tế → ĐẠT/LỖI. Thoát mã 1 nếu có kiểm thử lỗi (dùng được trong CI).
#   ./test/smoke.sh            # chạy hết
#   ./test/smoke.sh web        # chỉ nhóm có tên chứa "web" (web, vpn, egress, edge, cluster, siem)
set -uo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd); cd "$LAB"
OUT="out"
INV="python3 -I $LAB/scripts/inventory.py get"
SSH="$LAB/lab.sh ssh"
FILTER=${1:-}

WEB_IP=$($INV public_web) || exit 1
APP="whoami.$($INV gw_domain public)"
JUMP=$($INV jump_ip); MASTER=$($INV group_ip k8s_control_plane); SIEM=$($INV group_ip siem)
read -r GUI_EDGE GUI_CORE <<<"$($INV fw_gui)"; DNS=$($INV dns); DOMAIN=$($INV domain)
PASS=0; FAIL=0

check() {  # check <nhóm> <tên> <mong đợi> <thực tế>
  [[ -n $FILTER && $1 != *"$FILTER"* ]] && return
  local name="$2$(printf '%*s' $((46 - ${#2})) '')"   # đệm theo số KÝ TỰ (printf %-Ns đếm byte, lệch với tiếng Việt)
  if [[ $4 == "$3" ]]; then printf '  \e[32mĐẠT\e[0m  %-7s %s %s\n' "$1" "$name" "$4"; PASS=$((PASS + 1))
  else printf '  \e[31mLỖI\e[0m  %-7s %s mong đợi %s, thực tế %s\n' "$1" "$name" "$3" "${4:-<rỗng>}"; FAIL=$((FAIL + 1)); fi
}
want() { [[ -z $FILTER || $1 == *"$FILTER"* ]]; }                         # nhóm này có chạy không
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }    # mã HTTP, 000 = không kết nối được
tcp() { timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo mở || echo chặn; }
remote_tcp() { $SSH "$1" "timeout 5 bash -c '</dev/tcp/$2/$3' 2>/dev/null && echo mở || echo chặn" 2>/dev/null | tail -1; }
kubectl() { $SSH "$MASTER" "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf $*" 2>/dev/null; }

echo "== Kiểm thử đầu-cuối · IP web $WEB_IP"

if want web; then  # Internet → firewall biên → HAProxy + WAF → Gateway → app
  C=(--resolve "$APP:443:$WEB_IP" --cacert "$OUT/lab-ca.crt")
  check web "Internet → app qua HTTPS"           200 "$(code "${C[@]}" "https://$APP/")"
  check web "WAF chặn SQL injection"            403 "$(code "${C[@]}" "https://$APP/?id=1%27%20OR%20%271%27=%271")"
  check web "WAF chặn XSS"                      403 "$(code "${C[@]}" "https://$APP/?q=%3Cscript%3Ealert(1)%3C/script%3E")"
  check web "WAF chặn đọc file (LFI)"           403 "$(code "${C[@]}" "https://$APP/?f=../../../../etc/passwd")"
  check web "WAF chặn công cụ quét (sqlmap)"    403 "$(code "${C[@]}" -A sqlmap/1.8 "https://$APP/")"
  check web "HTTP chuyển sang HTTPS"            301 "$(code "http://$WEB_IP/")"
  ME=$(curl -s --max-time 10 https://api.ipify.org)
  RIP=$(curl -s --max-time 10 "${C[@]}" "https://$APP/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-real-ip"{print $2}')
  # mạng quán/văn phòng có thể ra Internet bằng nhiều IP liền nhau → so cùng dải /24
  check web "App thấy IP thật của client (cùng /24)" "${ME%.*}" "${RIP%.*}"
  check web "SSH qua IP web bị chặn"            chặn "$(tcp "$WEB_IP" 22)"
fi

if want vpn; then  # VPN quản trị chỉ tới jump-01 + GUI 2 firewall
  check vpn "VPN → jump-01:22"                  mở   "$(tcp "$JUMP" 22)"
  check vpn "VPN → master:22 bị chặn"           chặn "$(tcp "$MASTER" 22)"
  check vpn "VPN → Grafana trực tiếp bị chặn"   chặn "$(tcp "$SIEM" 3000)"
  check vpn "VPN → GUI firewall biên"           200  "$(code -k "https://$GUI_EDGE/")"
  check vpn "VPN → GUI firewall core"           200  "$(code -k "https://$GUI_CORE/")"
  check vpn "DNS nội bộ phân giải harbor"       "$($INV group_ip infra)" "$(dig +short +time=3 @"$DNS" "harbor.$DOMAIN")"
fi

if want egress; then  # đi ra Internet: chỉ infra-01 trực tiếp, máy khác qua Squid có allowlist
  PROXY="http://proxy.$DOMAIN:3128"
  check egress "master ra thẳng Internet bị chặn"   000 "$($SSH "$MASTER" "curl -s -o /dev/null -w %{http_code} --max-time 8 https://dl.k8s.io/" 2>/dev/null | tail -1)"
  check egress "master qua Squid, tên miền được phép" 200 "$($SSH "$MASTER" "curl -s -o /dev/null -w %{http_code} --max-time 10 -x $PROXY https://dl.k8s.io/" 2>/dev/null | tail -1)"
  check egress "master qua Squid, tên miền ngoài danh sách" 000 "$($SSH "$MASTER" "curl -s -o /dev/null -w %{http_code} --max-time 10 -x $PROXY https://example.com/" 2>/dev/null | tail -1)"
  check egress "infra-01 ra Internet, NAT bằng IP web" "$WEB_IP" "$($SSH "$($INV group_ip infra)" "curl -s --max-time 10 https://api.ipify.org" 2>/dev/null | tail -1)"
fi

if want edge; then  # edge-01 (DMZ) chỉ tới Gateway public và SIEM
  EDGE=$($INV group_ip edge)
  check edge "edge-01 → master:22 bị chặn"      chặn "$(remote_tcp "$EDGE" "$MASTER" 22)"
  check edge "edge-01 → siem-01 syslog"         mở   "$(remote_tcp "$EDGE" "$SIEM" 1514)"
  check edge "edge-01 đồng bộ giờ từ firewall"  có   "$($SSH "$EDGE" "chronyc -n sources 2>/dev/null | grep -q '^\^\*' && echo có || echo không" 2>/dev/null | tail -1)"
fi

if want cluster; then
  BAD=$(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l)
  check cluster "Pod không Running/Completed"   0 "$BAD"
  check cluster "Node Ready"                    "$(kubectl get nodes --no-headers | wc -l)" "$(kubectl get nodes --no-headers | grep -cw Ready)"
  check cluster "Velero: kho backup sẵn sàng"   Available "$(kubectl -n velero get backupstoragelocation -o 'jsonpath={.items[0].status.phase}')"
fi

if want prod; then  # chuẩn production (docs/thiet-ke-k8s-production.md)
  check prod "metrics-server: kubectl top đủ node"     "$(kubectl get nodes --no-headers | wc -l)" "$(kubectl top nodes --no-headers | wc -l)"
  check prod "StorageClass mặc định"                    standard "$(kubectl get sc --no-headers | awk '/\(default\)/{print $1}')"
  check prod "HPA whoami đọc được CPU"                  có "$(kubectl -n demo get hpa whoami -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -q '[0-9]' && echo có || echo không)"
  check prod "PDB whoami cho phép drain 1 pod"          1 "$(kubectl -n demo get pdb whoami -o jsonpath='{.status.disruptionsAllowed}')"
  BAD='{"apiVersion":"v1","kind":"Pod","metadata":{"name":"t","namespace":"demo"},"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"harbor.'"$DOMAIN"'/dockerhub/library/busybox:latest","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
  check prod "Kyverno chặn image :latest ở app"         chặn "$(OUT=$(echo "$BAD" | $SSH "$MASTER" 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply --dry-run=server -f - 2>&1' 2>/dev/null); [[ $OUT == *cam-tag-latest* ]] && echo chặn || echo cho qua)"
  WORKER=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' | awk 'NR==1{print $1}')
  WLIM=$(kubectl describe node "$WORKER" | awk '/Allocated resources/{f=1} f && $1=="memory"{gsub(/[()%]/,"",$5); print $5; exit}')
  check prod "Limit RAM worker không vượt RAM thật (≤100%)" có "$([[ ${WLIM:-999} -le 100 ]] && echo có || echo "không (${WLIM}%)")"
  NS_NP=$(kubectl get cnp -A --no-headers | awk '$2=="baseline"' | wc -l)
  check prod "Namespace có NetworkPolicy mặc định chặn"  9 "$NS_NP"
  BENCH=$(grep -h '^\[FAIL\]' "$OUT"/kube-bench-*.txt | grep -vE '^\[FAIL\] (1\.1\.12|4\.3\.1) ' | wc -l)
  check prod "kube-bench: không FAIL ngoài ngoại lệ"    0 "$BENCH"
fi

if want siem; then  # log 2 firewall về Loki trên siem-01 (truy vấn từ container Grafana)
  Q='http://loki:3100/loki/api/v1/query?query=count(count_over_time(%7Bhost%3D~%22firewall.*%22%7D%5B1h%5D))%20by%20(host)'
  N=$($SSH "$SIEM" "sudo docker exec mon-grafana-1 wget -qO- '$Q'" 2>/dev/null | grep -o '"host"' | wc -l)
  check siem "Loki có log của 2 firewall (1 giờ qua)" 2 "$N"
fi

echo "== $PASS đạt, $FAIL lỗi"
[[ $FAIL -eq 0 ]]
