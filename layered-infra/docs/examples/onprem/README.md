# Ví dụ: chạy lab trên on-prem

Ansible không quan tâm máy chạy ở đâu — chỉ đọc **một** inventory `ansible/shared/inventory/hosts.yml`. Thư mục này là **ví dụ**
(Ansible không đọc tới) cho topology on-prem: VLAN, transit riêng giữa 2 firewall, 3 master + 2 worker. IP là minh hoạ.

## Chuyển lab sang on-prem

```bash
cp docs/examples/onprem/hosts.yml ansible/shared/inventory/hosts.yml                 # sửa IP/card/VLAN cho đúng hệ thống thật
cp docs/examples/onprem/firewall-*.yml ansible/network/host_vars/                   # luật 2 firewall theo topology on-prem
rm -f ansible/shared/inventory/provisioned.yml                                     # IP public on-prem ghi thẳng trong hosts.yml
make lint                                                                          # kiểm tra IP trong dải, không trùng…
cd ansible && ansible-inventory --graph
```

Không dùng bộ tạo máy GCP nữa: xoá `provision/gcp/` (hoặc bỏ qua `make provision`), tự tạo máy đúng `hosts.yml`.

| File ở đây | Chép đè lên | Nội dung |
|---|---|---|
| `hosts.yml` | `ansible/shared/inventory/hosts.yml` | Vùng/VLAN, 2 firewall (card, IP, `dev` nếu không phải virtio), VM (IP, vai trò), route, VPN, VIP/Gateway K8s, card mạng + dhcp/static + NTP của VM, IP public của biên, `lab_hosting: onprem` |
| `firewall-*.yml` | `ansible/network/host_vars/` | Luật của 2 firewall (tên card khác GCP) — team network |

Mọi thứ còn lại (`ansible/shared/`, playbook, role của 3 team) dùng y nguyên.

## Khác GCP

| | GCP | On-prem (ví dụ này) |
|---|---|---|
| Vùng | VPC, gateway .1 do Google giữ, firewall .253 | VLAN trên switch, **firewall là gateway .1** |
| Biên ↔ core | DMZ kiêm transit (giới hạn số card theo vCPU) | **VLAN transit riêng** 10.30.0.0/29 |
| K8s | 1 master + 1 worker (quota) | **3 master + 2 worker** (HA) |
| VIP/Gateway | alias IP do GCP định tuyến | kube-vip/MetalLB trả lời ARP thật |
| IP public | IP tĩnh GCP + protocol forwarding cho VPN | IP nhà mạng cấp trên WAN |
| Tạo máy | `make provision` (provision/gcp, tuỳ chọn) | tự tạo (Proxmox/VMware/máy thật) — `make provision` (không có bộ tạo máy) in ra việc cần làm |

## Dùng được ngay

- Inventory: nhóm theo vai trò, `ansible_host`, `zone` của từng máy.
- Biến dùng chung tự ra đúng giá trị on-prem: `zone_fw` (.1), `proxy_no` (đủ 3 master + 2 worker), alias firewall
  (vd. `fw_core_dmz` = card transit của core), DNS nội bộ, Squid, SSH qua jump.
- Các role chạy trong cluster/dịch vụ (K8s, Harbor, Squid, SIEM, Velero, WAF…) không phụ thuộc GCP.

## Đã làm cho on-prem

- **Bootstrap firewall — giống hệt GCP**: `make fw-config` sinh khoá WireGuard admin + config bootstrap vào `out/`;
  bạn chép USB (`/conf/config.xml`) / nạp qua IPMI-iLO; rồi `make bootstrap`: biên dựng VPN qua IP WAN, máy admin bật
  VPN (`lab`), cấu hình đủ 2 firewall.
- **`scripts/opnsense-bootstrap.py`**: on-prem không dùng mẹo GCP (far gateway, route /25 qua .1); chỉ default gateway +
  gateway sang core qua IP transit, route vào LAN/MGMT theo `extra_routes`.
- **Luật 2 firewall** (`firewall-*.yml` ở đây): biên `lan`=transit, `opt1`=DMZ (DMZ vào trong đi qua biên nên biên lọc thêm
  #13-15); core `wan`=transit, syslog từ biên dùng alias `fw_edge_in` (card biên nối sang core — dùng chung 2 môi trường).

```bash
make fw-config      # → out/opnsense-<edge|core>-bootstrap.xml
make bootstrap      # sau khi 2 firewall đã nạp config
```

- **Mạng + NTP của VM** (role `node_network` của network): `node_network_mode: static` → IP tĩnh từ `hosts.yml`, gateway = firewall
  của VLAN, MTU từ `lab_mtu`; `ntp_client: systemd-timesyncd` → NTP = OPNsense. `quiet_os` (observability) chỉ tắt agent Google nếu máy có.
- **MTU** khai báo 1 chỗ (`lab_mtu` trong `hosts.yml`): card OPNsense, VM, WireGuard (= mtu − 80).
- **Máy cần có sẵn**: Ubuntu 24.04, user `ubuntu` sudo không hỏi mật khẩu, khoá SSH của máy admin, Python 3.

## Phải làm thêm trước khi chạy thật

| # | Việc | Vì sao |
|---|---|---|
| 1 | VPN admin luôn đi qua biên (IP public) | Máy admin on-prem ngồi trong LAN văn phòng có thể vào thẳng MGMT, không cần VPN |
| 2 | StorageClass `standard`: đổi local-path → Longhorn/Ceph (≥3 worker, dữ liệu nhân bản giữa node) — app không phải sửa | local-path chỉ hợp lab 1 worker |
| 3 | HA firewall (CARP), DB zone, HSM… theo sơ đồ hệ thống thật | Ngoài phạm vi bản mẫu |
