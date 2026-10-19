#!/bin/bash
set -euo pipefail

# Dựng VM Ubuntu trống từ cloud image, chỉ chuẩn bị user "stack" + package cơ bản
# (git, qemu-guest-agent). KHÔNG cài DevStack ở đây, và KHÔNG biết gì về việc
# cài DevStack sẽ dùng công cụ gì (Ansible hay khác) — script này chỉ có một
# việc: dựng VM rồi in ra IP. Việc trỏ công cụ cài đặt vào IP đó là của người
# dùng/script gọi tiếp theo, không phải của create-vm.sh.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export LIBVIRT_DEFAULT_URI=qemu:///system
NAME=devstack
IMG_DIR=/var/lib/libvirt/images
BASE=$IMG_DIR/noble-server-cloudimg-amd64.img
DISK=$IMG_DIR/$NAME.qcow2
WORK=$(mktemp -d)

# SSH key của bạn (tạo nếu chưa có)
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
SSHKEY=$(cat ~/.ssh/id_ed25519.pub)

# 1. Tải cloud image (chỉ tải lần đầu)
# Thư mục $IMG_DIR cần chgrp libvirt + chmod g+ws để user thường ghi được, không
# phải sudo mỗi lần: sudo chgrp libvirt /var/lib/libvirt/images && sudo chmod g+ws /var/lib/libvirt/images
[ -f "$BASE" ] || wget -O "$BASE" \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# 2. Tạo đĩa 100GB dựa trên image gốc
rm -f "$DISK"
qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" 100G

# 3. cloud-init user-data — chỉ cần thay __SSHKEY__, không còn nội dung nhiều dòng
# nên dùng sed là đủ an toàn (không cần python templating như trước).
sed "s|__SSHKEY__|$SSHKEY|" "$SCRIPT_DIR/cloud-init.yaml.tmpl" > "$WORK/user-data"
echo "instance-id: $NAME" > $WORK/meta-data

# 4. Tạo và chạy VM
virt-install \
  --name $NAME \
  --memory 12288 --vcpus 6 \
  --cpu host-passthrough \
  --disk path=$DISK,bus=virtio \
  --import \
  --network network=default,model=virtio \
  --os-variant ubuntu24.04 \
  --cloud-init user-data=$WORK/user-data,meta-data=$WORK/meta-data \
  --noautoconsole

echo "Chờ VM lấy IP..."
IP=""
for i in $(seq 1 30); do
  IP=$(virsh domifaddr $NAME | awk '/ipv4/ {sub(/\/.*/, "", $4); print $4; exit}')
  [ -n "$IP" ] && break
  sleep 5
done
[ -n "$IP" ] || { echo "Không lấy được IP sau 150s." >&2; exit 1; }
echo "IP: $IP"

# 5. Tháo ổ CD cloud-init ngay khi VM đã boot xong giai đoạn đầu.
#    virt-install gắn ISO cloud-init vào VM đang chạy rồi tự xoá file ISO sau đó.
#    Nếu ổ CD vẫn còn tham chiếu tới file đã mất thì "virsh managedsave" lưu lại
#    tham chiếu này và lần "virsh start" sau sẽ lỗi "Unable to restore from managed state".
#    cloud-init đã đọc user-data từ ISO ở giai đoạn boot đầu nên tháo ra là an toàn.
#    Dùng update-device với ổ CD trống; "virsh change-media --eject" bị crash trên bản libvirt này.
cat > $WORK/eject-cdrom.xml << 'XML'
<disk type='file' device='cdrom'>
  <driver name='qemu' type='raw'/>
  <target dev='sda' bus='sata'/>
  <readonly/>
</disk>
XML
virsh update-device $NAME $WORK/eject-cdrom.xml --live --config

echo
echo "VM đã sẵn sàng."
echo "  IP:  $IP"
echo "  SSH: ssh ubuntu@$IP"
