#!/bin/bash
set -euo pipefail

# Bật lại VM (tên "devstack"); nếu có trạng thái đã lưu bởi stop-vm.sh thì
# khôi phục nguyên trạng. Chỉ quản lý VM, không đụng gì tới DevStack/Ansible.

export LIBVIRT_DEFAULT_URI=qemu:///system
NAME=devstack

if ! virsh dominfo $NAME &>/dev/null; then
  echo "VM $NAME không tồn tại. Chạy ./create-vm.sh trước." >&2
  exit 1
fi

if [ "$(virsh domstate $NAME)" = "running" ]; then
  echo "VM $NAME đang chạy."
else
  virsh start $NAME
fi

echo "Chờ VM lấy IP..."
for _ in $(seq 1 30); do
  IP=$(virsh domifaddr $NAME | awk '/ipv4/ {sub(/\/.*/, "", $4); print $4; exit}')
  [ -n "${IP:-}" ] && break
  sleep 2
done

virsh domifaddr $NAME
[ -n "${IP:-}" ] && echo "SSH: ssh ubuntu@$IP"
