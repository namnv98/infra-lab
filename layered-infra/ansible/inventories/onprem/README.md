# Môi trường on-prem (BẢN MẪU)

Cùng playbook, cùng role với lab GCP — chỉ khác inventory. IP trong `envs/onprem/plan.yml` là minh hoạ; khi có hệ thống thật, sửa file đó
rồi kiểm tra:

```bash
LAB_ENV=onprem python3 scripts/plan.py check
cd ansible && ansible-inventory -i inventories/onprem/inventory.py --graph
ansible-playbook -i inventories/onprem/inventory.py site.yml --tags …
```

## Mỗi môi trường chỉ có 3 thứ riêng

| File | Nội dung |
|---|---|
| `envs/onprem/plan.yml` (gốc dự án) | Vùng/VLAN, 2 firewall (card, IP), VM (IP, vai trò), route, VPN, VIP/Gateway K8s — nguồn IP duy nhất |
| `group_vars/all/platform.yml` | Đặc thù nền tảng: card mạng (`enp1s0`), cách cấu hình mạng/NTP, cách bootstrap firewall |
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
| Tạo máy | tofu | hypervisor (Proxmox/VMware) — ngoài phạm vi repo |

## Dùng được ngay

- Inventory: nhóm theo vai trò + vùng, `ansible_host`, sinh từ `plan.yml`.
- Biến dùng chung tự ra đúng giá trị on-prem: `zone_fw` (.1), `proxy_no` (đủ 3 master + 2 worker), alias firewall
  (vd. `fw_core_dmz` = card transit của core), DNS nội bộ, Squid, SSH qua jump.
- Các role chạy trong cluster/dịch vụ (K8s, Harbor, Squid, SIEM, Velero, WAF…) không phụ thuộc GCP.

## Đã làm cho on-prem

- **Bootstrap firewall** (`00-firewall-bootstrap.yml`, nhánh `plan.platform != gcp`): sinh khoá WireGuard admin + config bootstrap
  vào `out/onprem/`, dừng chờ chép USB (`/conf/config.xml`) / nạp qua IPMI-iLO, sau đó như GCP: biên dựng VPN qua IP WAN,
  sinh `out/onprem/wg-admin.conf`, chờ admin bật VPN, cấu hình đủ 2 firewall. Bí mật on-prem nằm riêng `out/onprem/` (`lab_out`).
- **`scripts/opnsense-bootstrap.py`**: on-prem không dùng mẹo GCP (far gateway, route /25 qua .1); chỉ default gateway +
  gateway sang core qua IP transit, route vào LAN/MGMT theo `extra_routes`.
- **Luật 2 firewall** (`host_vars/firewall-*.yml`): biên `lan`=transit, `opt1`=DMZ (DMZ vào trong đi qua biên nên biên lọc thêm
  #13-15); core `wan`=transit, syslog từ biên dùng alias `fw_edge_in` (card biên nối sang core — dùng chung 2 môi trường).

```bash
ansible-playbook -i inventories/onprem/inventory.py site.yml --tags bootstrap,network
```

## Phải làm thêm trước khi chạy thật

| # | Việc | Vì sao |
|---|---|---|
| 1 | Role `base/network`: nhánh IP tĩnh + gateway + VLAN theo `node_network_mode` | Hiện chỉ đổi DNS, giả định DHCP + route của VPC (GCP) |
| 2 | Role `base/network`: NTP theo `ntp_client` (timesyncd) | Hiện ghi `/etc/chrony/chrony.conf` (image GCP dùng chrony) |
| 3 | `lab.sh` (vpn, tunnel, browser…) đang gắn với GCP (`tofu output`) | Máy admin on-prem có thể ngồi trong LAN văn phòng |
| 4 | HA firewall (CARP), DB zone, HSM… theo sơ đồ hệ thống thật | Ngoài phạm vi bản mẫu |
