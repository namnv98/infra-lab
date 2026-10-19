#!/bin/bash
# Không dùng "set -u": openrc/functions của DevStack tham chiếu biến chưa khai báo
# nên sẽ lỗi "_DEVSTACK_FUNCTIONS: unbound variable" và làm stack.sh thất bại.
set -eo pipefail
TOP_DIR=$(cd $(dirname "$0") && pwd)
source $TOP_DIR/openrc admin admin

# 1. DNS cho subnet private.
#    Subnet mặc định của DevStack không có DNS nên guest không phân giải
#    được tên miền (lỗi "lookup quay.io ... server misbehaving").
# "|| true": script này có thể chạy lại (ví dụ khi bước sau lỗi phải fix và rerun),
# nên bỏ qua lỗi "Duplicate nameserver" nếu DNS đã được set từ lần chạy trước.
openstack subnet set --dns-nameserver 8.8.8.8 --dns-nameserver 1.1.1.1 private-subnet || true

# 2. Gateway cho mạng quản lý trove-mgmt.
#    Khi chuẩn bị DB, guest tắt NIC của mạng người dùng (network_isolation)
#    và chỉ còn mạng trove-mgmt để tải image docker từ quay.io. DevStack tạo
#    mạng này KHÔNG có gateway (TROVE_MGMT_GATEWAY=none) nên guest không ra
#    được internet. Ta dùng chính VM này làm gateway (nó có IP trên cổng
#    trove-mgmt). Neutron không cho gateway nằm trong allocation pool, nên
#    phải chia lại pool để loại IP đó ra.
GW=$(ip -4 -o addr show trove-mgmt | awk '{print $4}' | cut -d/ -f1)
PREFIX=${GW%.*}
LAST=${GW##*.}
# GW có thể rơi ngay đầu (10) hoặc cuối (200) dải mặc định, khi đó nửa dải
# tương ứng sẽ có end < start (ví dụ start=10,end=9) và Neutron từ chối.
# Chỉ thêm nửa dải nào còn hợp lệ (có khoảng trống thực sự).
POOLS=()
[ $LAST -gt 10 ]  && POOLS+=(--allocation-pool start=$PREFIX.10,end=$PREFIX.$((LAST - 1)))
[ $LAST -lt 200 ] && POOLS+=(--allocation-pool start=$PREFIX.$((LAST + 1)),end=$PREFIX.200)
openstack subnet set \
  --no-allocation-pool \
  "${POOLS[@]}" \
  --gateway $GW trove-mgmt-subnet

# 3. Tắt port security trên cổng trove-mgmt của VM này.
#    Cổng này bị giới hạn security group và anti-spoofing (chỉ cho gói có
#    source IP = IP của nó), nên chặn traffic guest đi qua làm gateway và
#    các gói trả về có source là IP internet (ví dụ 8.8.8.8).
#    Phải gỡ security group trước thì Neutron mới cho tắt port security.
PORT=$(openstack port list --network trove-mgmt --fixed-ip ip-address=$GW -f value -c ID)
openstack port set --no-security-group --disable-port-security $PORT

# 4. NAT cho mạng trove-mgmt ra internet, tạo thành service để giữ sau reboot
#    (rule iptables thường mất khi khởi động lại). Không ghim tên NIC uplink
#    mà dùng "! -d" (chỉ NAT gói đi ra ngoài mạng này) cho chắc.
sudo tee /etc/systemd/system/trove-mgmt-nat.service > /dev/null << UNIT
[Unit]
Description=NAT for Trove management network
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s $PREFIX.0/24 ! -d $PREFIX.0/24 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $PREFIX.0/24 ! -d $PREFIX.0/24 -j MASQUERADE'

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now trove-mgmt-nat.service
