#!/bin/bash
set -euo pipefail

# Dừng VM (tên "devstack") và trả RAM/CPU về host. Trạng thái RAM được lưu ra
# đĩa, dùng start-vm.sh để quay lại đúng như lúc dừng. Chỉ quản lý VM, không
# đụng gì tới DevStack/Ansible.

export LIBVIRT_DEFAULT_URI=qemu:///system
NAME=devstack

if ! virsh dominfo $NAME &>/dev/null; then
  echo "VM $NAME không tồn tại." >&2
  exit 1
fi

if [ "$(virsh domstate $NAME)" != "running" ]; then
  echo "VM $NAME không chạy."
  exit 0
fi

virsh managedsave $NAME
echo "Đã dừng $NAME. Chạy ./start-vm.sh để bật lại."
