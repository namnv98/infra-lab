#!/usr/bin/env bash
# BỘ TẠO MÁY cho máy nhà (KVM/libvirt) — TUỲ CHỌN. Xoá cả provision/libvirt/ thì lớp cấu hình vẫn chạy với máy tạo cách khác.
# Hợp đồng với lớp cấu hình (giống provision/gcp):
#   1) máy chạy đúng tên/IP/card trong ansible/shared/inventory/hosts.yml — CHUNG với GCP (mạng + VM sinh từ file này)
#   2) 2 firewall đã nạp out/opnsense-<edge|core>-bootstrap.xml (make fw-config sinh trước)
#   3) IP "public" của biên (cố định trên mạng lab-wan) + biến riêng máy nhà: provisioned.yml cạnh đây → chép vào inventory
#   libvirt.sh use          chuyển lab sang máy nhà: chép provisioned.yml cạnh đây vào inventory, cất out/ cũ (không sửa file git)
#   libvirt.sh restore      quay về môi trường trước khi use (vd. GCP): trả lại provisioned.yml + out/ đã cất
#   libvirt.sh image        tải 1 lần: OPNsense nano + Ubuntu 24.04 cloud image (kiểm tra SHA256) vào lab_image_dir
#   libvirt.sh up           tạo mạng + VM còn thiếu → nạp config bootstrap vào firewall MỚI qua console nối tiếp
#   libvirt.sh console [edge|core]  console nối tiếp của firewall (cứu hộ khi mất VPN; thoát: Ctrl+])
#   libvirt.sh stop|start [máy…]    tắt/bật theo tầng (giữ nguyên đĩa); không ghi máy = cả lab theo đúng thứ tự
#   libvirt.sh status       VM + mạng của lab
#   libvirt.sh down         XOÁ VM, đĩa, mạng của lab (hỏi xác nhận)
#   libvirt.sh purge        GỠ SẠCH: down + kết nối VPN + trạng thái máy nhà trong out/ (hỏi xác nhận)
#   (cả hai GIỮ image OS gốc trong lab_image_dir — dựng lại không tải lại; xoá hẳn: rm -r thư mục đó)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LAB=$(cd "$HERE/../.." && pwd)
OUT="$LAB/out"; mkdir -p "$OUT"
INVDIR="$LAB/ansible/shared/inventory"
POOL=${LIBVIRT_POOL_DIR:-/var/lib/libvirt/images}   # thư mục của pool "default"; đĩa VM: <máy>.qcow2
INV="python3 -I $LAB/scripts/inventory.py get"
# Luôn đọc hosts.yml + provisioned.yml cạnh đây: dọn/tắt máy nhà được cả khi ansible/ đã restore về GCP
export LAB_PROVISIONED="$HERE/provisioned.yml"
IMG=$($INV lab_image_dir)   # image OS gốc (lớp nền của đĩa VM) — down/purge không xoá
OPN_V=26.7
OPN_IMG="$IMG/opnsense-$OPN_V-nano.qcow2"
UBU_IMG="$IMG/noble-server-cloudimg-amd64.img"
FILES=(ansible/shared/inventory/provisioned.yml)   # phần riêng của 1 môi trường trong ansible/ (gitignore)
V() { LC_ALL=C virsh -c qemu:///system "$@"; }   # LC_ALL=C: grep chữ tiếng Anh (running, shut off)
exists() { V dominfo "$1" >/dev/null 2>&1; }
net() { echo "lab-$1"; }                                   # tên mạng libvirt = tên bridge (≤ 15 ký tự)
SW=lab-sw                                                  # switch Open vSwitch khi lab_vlan_trunk: mỗi vùng 1 VLAN
TRUNK=$($INV vlan_trunk)
declare -A VLAN; while read -r Z _ _ T; do VLAN[$Z]=$T; done < <($INV zone_list)
on_sw() { [ "$TRUNK" = yes ] && [ "${VLAN[$1]}" != - ]; }  # vùng này nằm trên switch VLAN?
port() {  # port <vùng|trunk-<firewall>>: tham số --network của virt-install (cổng access/trunk trên switch, hoặc mạng riêng)
  case "$1" in trunk-*) echo "network=$SW,portgroup=$1" ;; *) on_sw "$1" && echo "network=$SW,portgroup=$1" || echo "network=$(net "$1")" ;; esac; }
mac() { local IFS=.; set -- $1; printf '52:54:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4"; }   # MAC theo IP: dựng lại không đổi
stash() { find "$1" -mindepth 1 -maxdepth 1 -exec mv -t "$2" {} +; }   # stash <từ> <tới>: chuyển nội dung thư mục
is_home() { grep -qsE '^ *lab_provisioner: *libvirt( |$)' "$INVDIR/provisioned.yml"; }   # ansible/ đang dùng máy nhà?

wait_for() {  # wait_for <mô tả> <lệnh> — thử 5 giây/lần, tối đa 5 phút
  local i; for i in $(seq 60); do eval "$2" >/dev/null 2>&1 && { echo "   ✓ $1"; return 0; }; sleep 5; done
  echo "   ✗ $1: quá 5 phút — xem $0 console core"; return 1; }

fetch() {  # fetch <url> <url file SHA256> <file đích>: tải về, chỉ giữ khi đúng checksum
  local f; f=$(basename "$1")
  curl -fL --progress-bar -o "$3.part" "$1"
  curl -fsSL "$2" | grep -E "(\(|\*| )$f\)?( |$)" | sed -E 's/^SHA256 \(.*\) = //; s/ .*//' | head -1 > "$3.sha"
  [ "$(sha256sum "$3.part" | cut -d' ' -f1)" = "$(cat "$3.sha")" ] || { rm -f "$3.part" "$3.sha"; echo "!! sai checksum: $1"; exit 1; }
  mv "$3.part" "$3"; rm -f "$3.sha"
}

load_config() {  # load_config <firewall>: console → đăng nhập mặc định → chép config từ đĩa LABCFG → khởi động lại
  # Bản nano lần boot đầu (cấu hình mặc định): trả lời câu hỏi gán card, đăng nhập root/opnsense, mục 8 (shell).
  # Chuỗi báo thành công ghép 2 nửa (BOOT""STRAP) để không trùng với chính dòng lệnh vừa gõ trên màn hình.
  local S="fwcon-$1" tail last="" poked=0 a end=$((SECONDS + 900))
  local CMD="sh -c 'D=/dev/msdosfs/LABCFG; [ -e \$D ] || D=/dev/vtbd1; mount_msdosfs \$D /mnt && cp /mnt/config.xml /conf/config.xml && umount /mnt && echo BOOT\"\"STRAP-OK' && reboot"
  send() { tmux send-keys -t "$S" -l "$1"; tmux send-keys -t "$S" Enter; }
  tmux kill-session -t "$S" 2>/dev/null || true
  tmux new-session -d -s "$S" -x 200 -y 50 "virsh -c qemu:///system console $1 --force"
  tmux set-option -t "$S" history-limit 5000 >/dev/null
  while [ $SECONDS -lt $end ]; do
    SCR=$(tmux capture-pane -p -t "$S" -S -8 | grep -v '^[[:space:]]*$' || true)
    if grep -q 'BOOTSTRAP-OK' <<< "$SCR"; then
      echo "== đã nạp config bootstrap, OPNsense đang khởi động lại"; sleep 5; tmux kill-session -t "$S"; return 0
    fi
    tail=$(tail -n1 <<< "$SCR"); tail=${tail%"${tail##*[![:space:]]}"}   # dòng cuối, bỏ khoảng trắng cuối
    case "$tail" in
      root@*'#' | root@*'%' | '#') a=CMD ;;
      *'LAGGs now? [y/N]' | *'VLANs now? [y/N]') a=n ;;
      # gán tạm (config.xml chép sau sẽ thay): card đầu là WAN, không LAN — core VLAN chỉ có 1 card trunk
      *'Enter the WAN interface name'*) a=vtnet0 ;;
      *'Enter the LAN interface name'*) a="" ;;
      *'Enter the Optional interface 1 name'*) a="" ;;
      *'Do you want to proceed? [y/N]') a=y ;;
      *login:) a=root ;;
      *Password:) a=opnsense ;;
      *'Enter an option:') a=8 ;;
      *) a=NONE ;;
    esac
    if [ "$a" = CMD ]; then
      [ "$last" = CMD ] || { echo "== shell: chép config từ đĩa LABCFG"; send "$CMD"; last=CMD; }
    elif [ "$a" != NONE ]; then
      [ "$tail" = "$last" ] || { echo "  '${tail:0:60}' → ${a:-<ENTER>}"; send "$a"; last=$tail; }
    else
      # dấu nhắc lạ / console mở sau khi máy đã in dấu nhắc: thỉnh thoảng gõ Enter để in lại
      poked=$((poked + 1)); [ $((poked % 15)) = 0 ] && send ""
    fi
    sleep 2
  done
  echo "!! hết giờ, màn hình cuối:"; tmux capture-pane -p -t "$S" -S -15; tmux kill-session -t "$S"; return 1
}

seed() {  # seed <máy> <ISO>: cloud-init NoCloud — user ubuntu + khoá SSH máy admin, IP tĩnh như role node_network ghi sau này
  local d IF ADDR GW DNS RT=""; d=$(mktemp -d)
  read -r ADDR GW DNS <<< "$($INV host_net "$1")"; IF=$($INV node_interface)
  while read -r TO VIA; do [ -n "$TO" ] && RT+=", { to: $TO, via: $VIA }"; done < <($INV host_routes "$1")   # = route VPC
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$1" "$1" > "$d/meta-data"
  cat > "$d/user-data" <<EOF
#cloud-config
hostname: $1
fqdn: $1.$($INV domain)
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat ~/.ssh/id_ed25519.pub)"]
ssh_pwauth: false
package_update: false
package_upgrade: false
EOF
  cat > "$d/network-config" <<EOF
version: 2
ethernets:
  $IF:
    match: { macaddress: "$(mac "${ADDR%/*}")" }
    set-name: $IF
    addresses: [$ADDR]
    routes: [{ to: default, via: $GW }$RT]
    nameservers: { addresses: [$DNS], search: [$($INV domain)] }
    mtu: $($INV mtu)
EOF
  xorriso -as mkisofs -quiet -volid cidata -joliet -rock -o "$2" "$d"/user-data "$d"/meta-data "$d"/network-config 2>/dev/null
  rm -rf "$d"
}

case "${1:-}" in
  use)
    is_home && { echo "Đang dùng máy nhà rồi (sửa $HERE/provisioned.yml thì chép lại: cp $HERE/provisioned.yml $INVDIR/)."; exit 0; }
    PREV=$(sed -n 's/^ *lab_provisioner: *\([a-z0-9_-]*\).*/\1/p' "$INVDIR/provisioned.yml" 2>/dev/null || true)
    PREV=${PREV:-$(sed -n 's/^ *lab_hosting: *\([a-z0-9_-]*\).*/\1/p' "$INVDIR/hosts.yml")}
    S="$LAB/out-$PREV"
    [ -e "$S" ] && { echo "!! ${S#$LAB/}/ đã có (lần use trước chưa restore?) — xem rồi xoá/đổi tên trước"; exit 1; }
    # out/ là trạng thái của 1 môi trường (bí mật, known_hosts, kubeconfig — cùng IP nhưng khác máy): cất đi, không dùng lẫn
    mkdir -p "$S/inventory"
    stash "$OUT" "$S"
    for f in "${FILES[@]}"; do
      if [ -e "$LAB/$f" ]; then (cd "$LAB" && cp --parents "$f" "$S/inventory/"); fi
    done
    if [ -d "$LAB/out-libvirt" ]; then stash "$LAB/out-libvirt" "$OUT"; rmdir "$LAB/out-libvirt"; fi   # trạng thái máy nhà lần trước
    cp "$HERE/provisioned.yml" "$INVDIR/provisioned.yml"
    echo "Đã chuyển sang máy nhà (môi trường '$PREV' cất ở ${S#$LAB/}/). Tiếp: make fw-config provision bootstrap cluster test"
    echo "Quay lại: make libvirt-restore" ;;
  restore)
    mapfile -t SS < <(find "$LAB" -maxdepth 1 -name 'out-*' -type d ! -name out-libvirt)
    [ ${#SS[@]} = 1 ] || { echo "!! cần đúng 1 thư mục out-<môi trường>/ (do make libvirt-use cất), đang có ${#SS[@]}"; exit 1; }
    S=${SS[0]}
    cmp -s "$HERE/provisioned.yml" "$INVDIR/provisioned.yml" \
      || { echo "!! $INVDIR/provisioned.yml khác bản máy nhà (sửa tay?) — gộp vào $HERE/provisioned.yml trước"; exit 1; }
    mkdir -p "$LAB/out-libvirt"; stash "$OUT" "$LAB/out-libvirt"
    rm -f "$INVDIR/provisioned.yml"
    (cd "$S/inventory" && find . -type f -exec cp --parents {} "$LAB/" \;)
    rm -rf "$S/inventory"; stash "$S" "$OUT"; rmdir "$S"
    echo "Đã quay lại '${S#$LAB/out-}' (trạng thái máy nhà cất ở out-libvirt/; VM vẫn còn — tắt: make libvirt-stop)" ;;
  image)
    # 1 lần: image gốc của hãng, không sửa gì (golden image = bản gốc) — dựng lại lab không tải lại
    if [ ! -s "$OPN_IMG" ]; then
      B="https://pkg.opnsense.org/releases/$OPN_V"; F="OPNsense-$OPN_V-nano-amd64.img.bz2"
      echo "== tải OPNsense $OPN_V nano"
      fetch "$B/$F" "$B/OPNsense-$OPN_V-checksums-amd64.sha256" "$POOL/$F"
      bunzip2 -c "$POOL/$F" > "$POOL/.opn.raw" && qemu-img convert -O qcow2 "$POOL/.opn.raw" "$OPN_IMG"
      rm -f "$POOL/.opn.raw" "$POOL/$F"
    fi
    if [ ! -s "$UBU_IMG" ]; then
      B=https://cloud-images.ubuntu.com/noble/current
      echo "== tải Ubuntu 24.04 cloud image"
      fetch "$B/$(basename "$UBU_IMG")" "$B/SHA256SUMS" "$UBU_IMG"
    fi
    ls -lh "$OPN_IMG" "$UBU_IMG" ;;
  up)
    is_home || { echo "!! ansible/ chưa dùng máy nhà (provisioned.yml có lab_provisioner: libvirt): chạy make libvirt-use trước"; exit 1; }
    python3 -I "$LAB/scripts/inventory.py" check
    for R in edge core; do
      [ -s "$OUT/opnsense-$R-bootstrap.xml" ] || { echo "!! thiếu $OUT/opnsense-$R-bootstrap.xml — chạy make fw-config trước"; exit 1; }
    done
    # Route của máy này trùng dải lab (mạng libvirt/VPN cũ) → gói đi nhầm chỗ; route của chính lab (lab-*, VPN "lab") thì bỏ qua
    C=$($INV zone_list | while read -r _ CIDR _; do
          { ip -4 route show root "$CIDR"; ip -4 route show match "$CIDR"; } | grep -v '^default' | grep -vE 'dev lab(-| |$)' || true
        done | sort -u)
    [ -z "$C" ] || { echo "!! route của máy này trùng dải lab (xoá mạng libvirt cũ: virsh net-destroy/net-undefine):"; echo "$C"; exit 1; }
    [ -s "$OPN_IMG" ] && [ -s "$UBU_IMG" ] || "$0" image
    # (1) mạng: wan = NAT ra Internet (máy này là gateway, như đường lên nhà mạng). Vùng trong: lab_vlan_trunk → 1 switch
    #     Open vSwitch, mỗi vùng 1 VLAN (portgroup = cổng access; trunk-<firewall> = cổng trunk các VLAN firewall đó giữ);
    #     không trunk → mỗi vùng 1 bridge riêng. Máy này không có IP trong các vùng trong
    ZONE=""; systemctl is-active -q firewalld && ZONE=" zone='trusted'"   # firewalld: không lọc gói giữa các VM trên bridge
    if [ "$TRUNK" = yes ] && ! V net-info "$SW" >/dev/null 2>&1; then
      command -v ovs-vsctl >/dev/null || { echo "!! cần Open vSwitch: sudo pacman -S openvswitch && sudo systemctl enable --now ovs-vswitchd"; exit 1; }
      sudo ovs-vsctl --may-exist add-br "$SW"
      X="<network><name>$SW</name><forward mode='bridge'/><bridge name='$SW'/><virtualport type='openvswitch'/>"   # MTU: VM/OPNsense tự đặt lab_mtu (libvirt không nhận <mtu> cho bridge)
      for Z in "${!VLAN[@]}"; do on_sw "$Z" && X+="<portgroup name='$Z'><vlan><tag id='${VLAN[$Z]}'/></vlan></portgroup>"; done
      for fw in $($INV fw_names); do
        read -r _ _ ZS _ < <($INV fw_ports "$fw" | grep ' trunk ') || continue
        X+="<portgroup name='trunk-$fw'><vlan trunk='yes'>"
        for Z in ${ZS//,/ }; do X+="<tag id='${VLAN[$Z]}'/>"; done
        X+="</vlan></portgroup>"
      done
      V net-define <(echo "$X</network>") >/dev/null && echo "== switch $SW (Open vSwitch): $(for Z in "${!VLAN[@]}"; do on_sw "$Z" && printf '%s=VLAN %s ' "$Z" "${VLAN[$Z]}"; done)"
    fi
    if [ "$TRUNK" = yes ]; then
      V net-info "$SW" | grep '^Active: *yes' >/dev/null || V net-start "$SW" >/dev/null
      V net-autostart "$SW" >/dev/null
    fi
    while read -r Z CIDR GW _; do
      on_sw "$Z" && continue
      N=$(net "$Z")
      if ! V net-info "$N" >/dev/null 2>&1; then
        X="<network><name>$N</name><bridge name='$N' stp='off'$ZONE/><mtu size='$($INV mtu)'/>"
        [ "$Z" = wan ] && X+="<forward mode='nat'/><ip address='$GW' prefix='${CIDR#*/}'/>"
        V net-define <(echo "$X</network>") >/dev/null && echo "== mạng $N"
      fi
      V net-info "$N" | grep '^Active: *yes' >/dev/null || V net-start "$N" >/dev/null
      V net-autostart "$N" >/dev/null
    done < <($INV zone_list)
    # (2) VM còn thiếu: đĩa = lớp qcow2 trên image gốc. libvirt xếp card vào khe PCI trước đĩa, đúng thứ tự khai báo:
    #     firewall (i440fx) slot 2,3,4 = vtnet0..n theo card vật lý (inventory.py fw_ports: trunk + card riêng)
    #     VM Linux: i440fx, card ở slot 4 = ens4 (giống hệt GCP). MAC theo IP đầu tiên trên card
    while read -r N KIND CPU MEM DISK ZS IPS; do
      exists "$N" && continue
      NETS=()
      if [ "$KIND" = fw ]; then
        while read -r _ PK PZ PI; do
          [ "$PK" = trunk ] && P="trunk-$N" || P=$PZ
          NETS+=(--network "$(port "$P"),model=virtio,mac=$(mac "${PI%%,*}")")
        done < <($INV fw_ports "$N")
      else
        NETS+=(--network "$(port "$ZS"),model=virtio,mac=$(mac "$IPS"),address.type=pci,address.domain=0,address.bus=0,address.slot=4")
      fi
      if [ "$KIND" = fw ]; then
        qemu-img create -q -f qcow2 -F qcow2 -b "$OPN_IMG" "$POOL/$N.qcow2" "${DISK}G"
        # đĩa FAT nhãn LABCFG chứa config.xml — như cắm USB; load_config chép vào /conf rồi gỡ ra
        rm -f "$POOL/$N-config.img"; truncate -s 8M "$POOL/$N-config.img"
        mkfs.vfat -n LABCFG "$POOL/$N-config.img" >/dev/null
        mcopy -i "$POOL/$N-config.img" "$OUT/opnsense-$($INV fw_role "$N")-bootstrap.xml" ::config.xml
        DISKS=(--disk "path=$POOL/$N.qcow2,bus=virtio" --disk "path=$POOL/$N-config.img,format=raw,bus=virtio")
        OS=freebsd14.3; MACH=()
      else
        qemu-img create -q -f qcow2 -F qcow2 -b "$UBU_IMG" "$POOL/$N.qcow2" "${DISK}G"
        seed "$N" "$POOL/$N-seed.iso"
        DISKS=(--disk "path=$POOL/$N.qcow2,bus=virtio" --disk "path=$POOL/$N-seed.iso,device=cdrom,bus=sata")
        OS=ubuntu24.04; MACH=(--machine pc)
      fi
      echo "== VM $N ($CPU vCPU, $MEM MiB, ${DISK}GB, $ZS)"
      virt-install --connect qemu:///system --name "$N" --vcpus "$CPU" --memory "$MEM" --cpu host-passthrough \
        --osinfo "$OS" "${MACH[@]}" --import "${DISKS[@]}" "${NETS[@]}" \
        --graphics none --console pty,target_type=serial --noautoconsole --quiet
    done < <($INV vm_list)
    # (3) firewall MỚI (uuid chưa có dấu "đã nạp"): nạp config song song qua console; đã nạp thì bỏ qua
    PIDS=()
    for fw in $($INV fw_names); do
      ID=$(V domuuid "$fw")
      [ -e "$OUT/.config-loaded-$fw-$ID" ] && continue
      V domstate "$fw" | grep running >/dev/null || V start "$fw" >/dev/null
      echo "== $fw: nạp config bootstrap qua console (log: out/logs-console-$fw.txt)"
      (load_config "$fw" > "$OUT/logs-console-$fw.txt" 2>&1 \
        && V detach-disk "$fw" vdb --config >/dev/null && rm -f "$POOL/$fw-config.img" \
        && touch "$OUT/.config-loaded-$fw-$ID") & PIDS+=($!)
    done
    for p in "${PIDS[@]}"; do wait "$p" || { echo "!! nạp config lỗi, xem $OUT/logs-console-*.txt"; exit 1; }; done
    echo "Máy đã sẵn sàng theo hosts.yml. Tiếp: make bootstrap" ;;
  console) V console "firewall-${2:-edge}-01" ;;
  stop|start)
    # Tắt/bật theo tầng (inventory.py start_order): firewall → jump → infra → master → worker → còn lại; tắt thì ngược lại
    act() {  # act <stop|start> <máy…>
      local n i
      for n in "${@:2}"; do
        if [ "$1" = start ]; then V domstate "$n" | grep running >/dev/null || V start "$n" >/dev/null
        elif V domstate "$n" | grep running >/dev/null; then V shutdown "$n" >/dev/null; fi
      done
      [ "$1" = start ] && return
      for n in "${@:2}"; do   # chờ tắt hẳn (ACPI), quá 2 phút thì rút điện
        for i in $(seq 24); do V domstate "$n" | grep 'shut off' >/dev/null && break; sleep 5; done
        V domstate "$n" | grep 'shut off' >/dev/null || { echo "   $n không tự tắt → destroy"; V destroy "$n" >/dev/null; }
      done
    }
    if [ $# -gt 1 ]; then echo "== $1: ${*:2}"; act "$1" "${@:2}"; exit; fi   # chỉ các máy ghi tên
    mapfile -t TIERS < <($INV start_order)
    if [ "$1" = stop ]; then
      for ((i = ${#TIERS[@]} - 1; i >= 0; i--)); do echo "== tắt: ${TIERS[i]}"; act stop ${TIERS[i]}; done
      nmcli connection down lab >/dev/null 2>&1 || true
      echo "Đã tắt cả lab (bật lại: make libvirt-start)."; exit
    fi
    for t in "${TIERS[@]}"; do
      echo "== bật: $t"; act start $t
      if [[ $t == *firewall-* ]]; then        # VPN đi qua firewall biên; API core trả lời = định tuyến + DNS đã sẵn sàng
        nmcli -t connection show --active | grep '^lab:' >/dev/null || "$LAB/lab.sh" vpn up >/dev/null
        wait_for "firewall core trả lời qua VPN" "curl -sk -m 4 -o /dev/null https://$($INV dns)"
      elif [[ " $t " == *" $($INV group_hosts bastion) "* ]]; then
        wait_for "jump-01 mở SSH" "timeout 4 bash -c '</dev/tcp/$($INV jump_ip)/22'"
      elif [[ " $t " == *" $($INV group_hosts k8s_control_plane | cut -d' ' -f1) "* ]]; then
        MASTER=$($INV group_ip k8s_control_plane)
        wait_for "K8s API sẵn sàng" "'$LAB/lab.sh' ssh $MASTER 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz'"
      fi
    done
    echo "Đã bật cả lab. Tunnel: ./lab.sh tunnel up · kiểm tra: make test" ;;
  status)
    V list --all | grep -E "Name|---|$($INV vm_list | cut -d' ' -f1 | paste -sd'|')" || true
    echo; V net-list --all | grep -E 'Name|---|lab-' || true
    if [ "$TRUNK" = yes ] && V net-info "$SW" >/dev/null 2>&1; then
      echo; echo "Cổng trên switch $SW (VLAN: tag = access, trunks = trunk):"
      sudo ovs-vsctl --columns=name,tag,trunks list port 2>/dev/null | paste - - - - | awk '{print "  "$3, $6, $9}' | grep -v "^  \"$SW\"" || true
    fi ;;
  purge)
    # Gỡ SẠCH dấu vết lab trên máy này: down + kết nối VPN + trạng thái máy nhà (out/ hoặc out-libvirt/). Giữ image OS gốc
    read -rp "GỠ SẠCH lab máy nhà (VM, đĩa, mạng, VPN, bí mật trong out/)? Gõ purge: " a; [ "$a" = purge ] || exit 1
    echo yes | "$0" down >/dev/null
    nmcli connection delete lab >/dev/null 2>&1 && echo "== đã xoá kết nối VPN lab" || true
    for s in $($INV fw_names); do tmux kill-session -t "fwcon-$s" 2>/dev/null || true; done
    V pool-refresh default >/dev/null 2>&1 || true
    # trạng thái máy nhà: out/ nếu đang dùng máy nhà, out-libvirt/ nếu đã restore về môi trường khác
    if is_home; then
      find "$OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; echo "== đã xoá out/ (trạng thái máy nhà)"
      echo "Inventory vẫn là bản máy nhà — quay lại môi trường cũ: make libvirt-restore"
    else
      rm -rf "$LAB/out-libvirt" && echo "== đã xoá out-libvirt/"
    fi ;;
  down)
    read -rp "XOÁ mọi VM, đĩa và mạng của lab trên máy này? Gõ yes: " a; [ "$a" = yes ] || exit 1
    while read -r N _; do
      exists "$N" || continue
      V destroy "$N" >/dev/null 2>&1 || true
      V undefine "$N" >/dev/null
      rm -f "$POOL/$N.qcow2" "$POOL/$N-seed.iso" "$POOL/$N-config.img"
      echo "== đã xoá $N"
    done < <($INV vm_list)
    for N in $($INV zone_list | while read -r Z _; do net "$Z"; done) "$SW"; do
      V net-info "$N" >/dev/null 2>&1 || continue
      V net-destroy "$N" >/dev/null 2>&1 || true; V net-undefine "$N" >/dev/null; echo "== đã xoá mạng $N"
    done
    if command -v ovs-vsctl >/dev/null && sudo ovs-vsctl br-exists "$SW" 2>/dev/null; then
      sudo ovs-vsctl del-br "$SW" && echo "== đã xoá switch Open vSwitch $SW"
    fi
    V pool-refresh default >/dev/null 2>&1 || true
    nmcli connection down lab >/dev/null 2>&1 || true
    rm -f "$OUT"/.config-loaded-*
    echo "(giữ image OS gốc trong $IMG/ để dựng lại không tải lại)" ;;
  *) sed -n "2,16p" "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
