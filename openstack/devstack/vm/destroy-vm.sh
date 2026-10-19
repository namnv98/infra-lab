#!/bin/bash
set -euo pipefail

# Gỡ VM libvirt (tên "devstack") do create-vm.sh tạo. Chỉ quản lý VM, không
# đụng gì tới DevStack/Ansible.
#   ./destroy-vm.sh          xoá VM + đĩa (giữ cloud image gốc để tạo lại nhanh)
#   ./destroy-vm.sh --purge  xoá cả cloud image gốc
#   ./destroy-vm.sh --fw     gỡ thêm rule iptables DOCKER-USER cho virbr0

export LIBVIRT_DEFAULT_URI=qemu:///system
NAME=devstack
IMG_DIR=/var/lib/libvirt/images
BASE=$IMG_DIR/noble-server-cloudimg-amd64.img
DISK=$IMG_DIR/$NAME.qcow2

PURGE=0
FW=0
for arg in "$@"; do
  case $arg in
    --purge) PURGE=1 ;;
    --fw) FW=1 ;;
    *) echo "Tham số không hợp lệ: $arg" >&2; exit 1 ;;
  esac
done

# 1. Tắt và xoá VM (kèm nvram/snapshot nếu có)
if virsh dominfo $NAME &>/dev/null; then
  virsh destroy $NAME 2>/dev/null || true
  virsh undefine $NAME --nvram --snapshots-metadata 2>/dev/null || virsh undefine $NAME
else
  echo "VM $NAME không tồn tại, bỏ qua."
fi

# 2. Xoá đĩa VM
# Không cần sudo: thư mục $IMG_DIR đã chgrp libvirt + chmod g+ws (xem README).
rm -f "$DISK"

# 3. Xoá cloud image gốc (tuỳ chọn)
[ $PURGE -eq 1 ] && rm -f "$BASE"

# 4. Gỡ rule iptables đã thêm để VM ra internet (tuỳ chọn)
if [ $FW -eq 1 ]; then
  sudo iptables -D DOCKER-USER -i virbr0 -j ACCEPT 2>/dev/null || true
  sudo iptables -D DOCKER-USER -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

# 5. Xoá host key cũ để lần tạo sau không bị cảnh báo SSH
ssh-keygen -R devstack 2>/dev/null || true

echo "Đã gỡ $NAME."
