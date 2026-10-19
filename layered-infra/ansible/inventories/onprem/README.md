# Môi trường on-prem (BẢN MẪU)

Cùng playbook, cùng role với lab GCP — chỉ khác inventory. IP trong `envs/onprem/plan.yml` là minh hoạ; khi có hệ thống thật, sửa file đó
rồi kiểm tra:

```bash
LAB_ENV=onprem python3 scripts/plan.py check
cd ansible && ansible-inventory -i inventories/onprem/inventory.py --graph
ansible-playbook -i inventories/onprem/inventory.py site.yml --tags …
```

## Mỗi môi trường chỉ có 2 thứ riêng

| File | Nội dung |
|---|---|
| `envs/onprem/plan.yml` (gốc dự án) | Vùng/VLAN, 2 firewall (card, IP, `dev` nếu không phải virtio), VM (IP, vai trò), route, VPN, VIP/Gateway K8s, `node` (card mạng, dhcp/static, NTP), `public` (IP public của biên) — nguồn duy nhất |
| `host_vars/firewall-*.yml` | Luật của 2 firewall (tên card khác GCP) |

Mọi thứ còn lại (`ansible/group_vars/`, playbook, role, `plan_inventory.py`) dùng chung.

## Khác GCP

| | GCP | On-prem (plan mẫu) |
|---|---|---|
| Vùng | VPC, gateway .1 do Google giữ, firewall .253 | VLAN trên switch, **firewall là gateway .1** |
| Biên ↔ core | DMZ kiêm transit (giới hạn số card theo vCPU) | **VLAN transit riêng** 10.30.0.0/29 |
| K8s | 1 master + 1 worker (quota) | **3 master + 2 worker** (HA) |
| VIP/Gateway | alias IP do GCP định tuyến | kube-vip/MetalLB trả lời ARP thật |
| IP public | IP tĩnh GCP + protocol forwarding cho VPN | IP nhà mạng cấp trên WAN |
| Tạo máy | `make provision` (provision/gcp, tuỳ chọn) | tự tạo (Proxmox/VMware/máy thật) — `make provision ENV=onprem` in ra việc cần làm |

## Dùng được ngay

- Inventory: nhóm theo vai trò + vùng, `ansible_host`, sinh từ `plan.yml`.
- Biến dùng chung tự ra đúng giá trị on-prem: `zone_fw` (.1), `proxy_no` (đủ 3 master + 2 worker), alias firewall
  (vd. `fw_core_dmz` = card transit của core), DNS nội bộ, Squid, SSH qua jump.
- Các role chạy trong cluster/dịch vụ (K8s, Harbor, Squid, SIEM, Velero, WAF…) không phụ thuộc GCP.

## Đã làm cho on-prem

- **Bootstrap firewall — giống hệt GCP**: `make fw-config ENV=onprem` sinh khoá WireGuard admin + config bootstrap vào `out/onprem/`;
  bạn chép USB (`/conf/config.xml`) / nạp qua IPMI-iLO; rồi `make bootstrap ENV=onprem`: biên dựng VPN qua IP WAN, máy admin bật
  VPN (`lab-onprem`), cấu hình đủ 2 firewall. Bí mật on-prem nằm riêng `out/onprem/` (`lab_out`).
- **`scripts/opnsense-bootstrap.py`**: on-prem không dùng mẹo GCP (far gateway, route /25 qua .1); chỉ default gateway +
  gateway sang core qua IP transit, route vào LAN/MGMT theo `extra_routes`.
- **Luật 2 firewall** (`host_vars/firewall-*.yml`): biên `lan`=transit, `opt1`=DMZ (DMZ vào trong đi qua biên nên biên lọc thêm
  #13-15); core `wan`=transit, syslog từ biên dùng alias `fw_edge_in` (card biên nối sang core — dùng chung 2 môi trường).

```bash
make fw-config ENV=onprem      # → out/onprem/opnsense-<edge|core>-bootstrap.xml
make bootstrap ENV=onprem      # sau khi 2 firewall đã nạp config
```

- **Mạng + NTP của VM** (`base/network`, theo `node` trong `plan.yml`): `network: static` → IP tĩnh từ `plan.yml`, gateway = firewall
  của VLAN, MTU từ `plan.yml`; `ntp: systemd-timesyncd` → NTP = OPNsense. `base/quiet_os` chỉ tắt agent Google nếu máy có.
- **MTU** khai báo 1 chỗ (`mtu` trong `plan.yml`): card OPNsense, VM, WireGuard (= mtu − 80).
- **Máy cần có sẵn**: Ubuntu 24.04, user `ubuntu` sudo không hỏi mật khẩu, khoá SSH của máy admin, Python 3.

## Phải làm thêm trước khi chạy thật

| # | Việc | Vì sao |
|---|---|---|
| 1 | VPN admin luôn đi qua biên (IP public) | Máy admin on-prem ngồi trong LAN văn phòng có thể vào thẳng MGMT, không cần VPN |
| 2 | StorageClass `standard`: đổi local-path → Longhorn/Ceph (≥3 worker, dữ liệu nhân bản giữa node) — app không phải sửa | local-path chỉ hợp lab 1 worker |
| 3 | HA firewall (CARP), DB zone, HSM… theo sơ đồ hệ thống thật | Ngoài phạm vi bản mẫu |
