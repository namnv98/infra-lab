#!/bin/bash
set -e

# ==== Kiểm tra quyền root ====
[ "$EUID" -ne 0 ] && { echo "❌ Chạy bằng sudo!"; exit 1; }

# ==== Kiểm tra VBoxManage ====
command -v VBoxManage >/dev/null || { echo "❌ VBoxManage không tồn tại"; exit 1; }

# ==== Thông số adapter ====
ADAPTER="vboxnet0"
HOST_IP="10.10.0.1"
NETMASK="255.255.255.0"
NETWORK_PREFIX="10.10.0."

# ==== Xóa các adapter linkdown đang dùng dải 10.10.0.x ====
while read -r LINE; do
  NAME=$(echo "$LINE" | awk -F': ' '{print $2}')
  IP=$(VBoxManage list hostonlyifs | grep -A3 "Name: $NAME" | grep "IPAddress" | awk '{print $2}')
  STATUS=$(VBoxManage list hostonlyifs | grep -A3 "Name: $NAME" | grep "Status" | awk '{print $2}')

  if [[ $IP == $NETWORK_PREFIX* && "$STATUS" == "Down" ]]; then
    echo "⚠️ Xóa adapter $NAME với IP $IP và trạng thái $STATUS..."
    VBoxManage hostonlyif remove "$NAME"
  fi
done < <(VBoxManage list hostonlyifs | grep "^Name:")

# ==== Tạo adapter mới nếu chưa có ====
if ! VBoxManage list hostonlyifs | grep -q "$ADAPTER"; then
  echo "🆕 Tạo host-only adapter $ADAPTER..."
  VBoxManage hostonlyif create
fi

# ==== Gán IP cho host ====
VBoxManage hostonlyif ipconfig "$ADAPTER" --ip "$HOST_IP" --netmask "$NETMASK"

# ==== Bật adapter UP ====
ip link set "$ADAPTER" up

# ==== Tắt DHCP ====
VBoxManage dhcpserver remove --ifname "$ADAPTER" 2>/dev/null || true

echo "✅ Adapter $ADAPTER sẵn sàng:"
echo "   Host IP: $HOST_IP"
echo "   Subnet: $NETMASK"
echo "Bây giờ VM có thể dùng IP tĩnh trong dải 10.10.0.x"
