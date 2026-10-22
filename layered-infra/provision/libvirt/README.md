# provision/libvirt — dựng lab trên máy nhà (KVM/libvirt)

Bộ tạo máy **tuỳ chọn**, cùng hợp đồng với `provision/gcp/`: máy chạy đúng `hosts.yml`, 2 firewall đã nạp config bootstrap,
IP "public" của biên biết trước. Chỉ dùng lệnh có sẵn: `virsh`, `virt-install`, `qemu-img`, `xorriso`, `mtools`, `tmux`.
Lớp cấu hình (`make bootstrap cluster test`) chạy y như GCP.

**Cùng IP với GCP.** Máy nhà dùng chung `ansible/shared/inventory/hosts.yml` và luật firewall `ansible/network/host_vars/`
với GCP: cùng vùng, cùng IP máy, firewall `.253`, DMZ kiêm đường nối biên ↔ core, VPN có IP riêng. Phần khác nằm trong
`provisioned.yml` (gitignore) — chuyển qua lại không sửa file nào trong git.

| File | Nội dung |
|---|---|
| `provisioned.yml` | Phần riêng máy nhà: IP public (10.99.0.2 web, 10.99.0.3 VPN), `lab_hosting: onprem`, IP tĩnh, timesyncd, thư mục image |
| `libvirt.sh` | `use` · `restore` · `image` · `up` · `console` · `stop`/`start` · `status` · `down` · `purge` |
| `provision.mk` | `make provision-libvirt`, `make libvirt-*` |

Cỡ VM (`vcpus`, `ram_mb`, `disk_gb`) ghi trong `hosts.yml` cạnh `machine_type` của GCP (~20GB RAM tổng).

## Dựng từ đầu

```bash
make libvirt-use     # chép provisioned.yml này vào ansible/shared/inventory/, cất out/ cũ → out-gcp/
make fw-config       # config bootstrap 2 OPNsense (admin = 10.99.0.1, lấy từ admin_public_ip)
make provision       # lab_provisioner: libvirt → tải image (lần đầu) → mạng + 8 VM → nạp config firewall qua console
make bootstrap cluster test
make libvirt-stop    # tắt theo tầng, giữ đĩa · make libvirt-start: bật lại, chờ firewall → jump → K8s
make libvirt-restore # quay lại GCP: trả provisioned.yml + out/ của GCP (trạng thái máy nhà cất ở out-libvirt/)
```

Cùng dải IP nên **không bật VPN tới cả hai cùng lúc**: tắt lab máy nhà (`make libvirt-stop`) trước khi nối VPN tới GCP.

## Dọn dẹp

| Lệnh | Xoá | Giữ |
|---|---|---|
| `make libvirt-down` | 8 VM + đĩa của chúng, mạng `lab-wan` + các switch Open vSwitch (`sw-dmz`, `sw-core`, `sw-access`) + dây uplink (veth), namespace quản trị `sw-core` | image OS gốc (`/data/lab-images/`), `out/` |
| `make libvirt-purge` | như `down` + kết nối VPN `lab` + trạng thái máy nhà (`out/` hoặc `out-libvirt/`) | đang ở máy nhà thì chạy thêm `make libvirt-restore` |

Cả hai đọc `hosts.yml` + `provisioned.yml` cạnh đây, nên chạy được cả sau khi đã `restore` về GCP. Chỉ xoá đúng tên trong
đó, không đụng VM/mạng libvirt khác (vd. `default`).

Image OS gốc (OPNsense nano ~2GB, Ubuntu cloud image ~600MB) nằm ở `lab_image_dir` (`/data/lab-images/`): tải 1 lần, mọi
đĩa VM là lớp qcow2 mỏng trên đó. Không lệnh nào xoá thư mục này; muốn xoá hẳn: `rm -r /data/lab-images` (khi không còn VM).

Cần: `libvirt` (qemu:///system, user trong nhóm `libvirt`), `openvswitch` (`ovs-vswitchd` chạy, `sudo` để tạo switch), `virt-install`, `xorriso`, `mtools`, `dosfstools`, `tmux`,
`wireguard-tools`, khoá `~/.ssh/id_ed25519`.

## Mạng — như on-prem thật: 3 switch, mỗi vùng 1 VLAN

```
 Internet ── NAT libvirt (lab-wan 10.99.0.0/24, máy này .1) ── vtnet1 WAN  firewall-edge-01
                                                                          │ vtnet0 (DMZ, không tag)
 ┌──────── sw-dmz (VLAN 10, không nối switch nào) ────────┐               │
 │ cổng 1 firewall-edge-01 · cổng 2 firewall-core-01 vtnet1 · cổng 3 edge-01 │
 └──────────────────────────────┬──────────────────────────┘
                     firewall-core-01 vtnet1 (DMZ .252)   vtnet0 trunk 20, 40 (vtnet0_vlan20 / _vlan40)
                                                                  │
 ┌──────── sw-core (phân phối, gốc RSTP) ────────────────────────┴──┐
 │ trunk firewall core · siem-01, jump-01 (access 40)                  │
 │ core-mgmt 10.40.0.250 (IP quản trị, VLAN 40) ── sFlow 1/128 → siem-01:6343 │
 └──────────┬──────────┬──────────────────────────────────────────────┘
            │ 2 dây    │ lag-sw-access: LACP gộp core-access1 + core-access2, trunk CHỈ VLAN 20
 ┌──────────┴──────────┴─ sw-access (tủ K8s) ──────────────────────────┐
 │ k8s-master-01 · k8s-worker-01 · infra-01 (access 20)                 │
 └──────────────────────────────────────────────────────────────────────┘
```

| Thành phần | Cấu hình |
|---|---|
| `lab-wan` | mạng NAT libvirt, tách khỏi switch (như đường lên nhà mạng): biên 10.99.0.2 = IP web, 10.99.0.3 = IP VPN (Virtual IP) |
| `lab_switches` | trong `provisioned.yml`: mỗi switch khai `fw` (vùng mà card firewall cắm vào), `hosts` (vùng mà VM cắm vào), `uplink` (switch kia: VLAN cho qua, số dây), `stp_priority`, `mgmt` (IP quản trị) |
| Switch | 1 bridge Open vSwitch + mạng libvirt cùng tên; portgroup `<vùng>` = cổng access, `trunk-<firewall>` = cổng trunk |
| Uplink | mỗi dây 1 cặp veth (`core-access1` ↔ `access-core1`), cắm cổng cố định cuối switch (47, 48 — như uplink switch 48 cổng; cổng VM OVS cấp từ 1 theo thứ tự cắm), `vlan_mode=trunk`, `trunks` = đúng VLAN khai (cắt VLAN thừa). `links: 2` = 2 dây gộp LACP (`lag-<switch kia>`, `balance-tcp`, LACP nhanh 1 giây); thêm `lacp: false` = 2 dây riêng, RSTP chặn 1 dây |
| RSTP | bật trên mọi switch; `stp_priority: 4096` cho sw-core = gốc (mặc định 32768). Cổng VM tự thành cổng biên (không nhận BPDU) |
| IP quản trị | `mgmt: 10.40.0.250`: card `core-mgmt` (cổng access VLAN 40) nằm trong network namespace `sw-core` — mạng quản trị tách riêng như switch thật, máy này vẫn không có IP trong vùng nào. Ping được từ jump-01 |
| sFlow | switch có `mgmt` gửi mẫu 1/128 gói về siem-01:6343 (goflow2 → Loki `{app="sflow"}`, dashboard *Lab · Bảo mật*). ovs-vswitchd gửi vào namespace qua veth `core-sfl` (169.254.101.x); namespace chỉ cho UDP 6343 tới siem-01 đi ra, nguồn = IP quản trị |
| VLAN ID | `vlan` của từng vùng trong `hosts.yml` (GCP bỏ qua) |
| Firewall | mỗi switch 1 card: ≥ 2 vùng trên cùng switch → card trunk, OPNsense tạo interface `vtnet<i>_vlan<tag>`; 1 vùng → card thường. Biên: vtnet0 DMZ + vtnet1 WAN; core: vtnet0 trunk 20/40 + vtnet1 DMZ |
| VM | cổng access, không biết VLAN: card `ens4` (máy i440fx, khe PCI 4 như GCP) |

`make lint` kiểm tra: mỗi vùng chỉ ở 1 switch cho firewall và 1 cho VM; VM ở switch khác firewall thì phải có uplink
nối thẳng cho VLAN đó đi qua; IP quản trị nằm trong 1 vùng có trên switch, không trùng IP khác. Xem switch:
`make libvirt-status` (cổng, tag/trunks, vai RSTP, trạng thái LACP, IP quản trị) · `sudo ovs-vsctl show` ·
`sudo ovs-appctl fdb/show sw-access` (bảng MAC) · `sudo ovs-appctl bond/show lag-sw-access` · `sudo ovs-appctl rstp/show sw-access`.
Bỏ `lab_switches` thì mỗi vùng 1 bridge riêng (`lab-dmz`, `lab-lan`, `lab-mgmt`), firewall mỗi vùng 1 card.

Thử rút 1 dây uplink (đang ping từ jump-01 tới master): `sudo ip link set core-access1 down` → LACP dồn sang dây còn lại,
không mất gói; cắm lại: `... up`. Đã đo trên lab: cả 2 chế độ (LACP, RSTP) đều 0/100 gói mất.

Khác switch thật (giới hạn của Open vSwitch 4.0):
- OVS không chạy RSTP trên cổng LACP: ở chế độ LACP cổng gộp đứng ngoài RSTP, 2 switch không trao BPDU nên switch nào cũng
  tự là gốc (switch thật chạy STP trên port-channel). Muốn thấy bầu gốc + chặn dây thì dùng `lacp: false`.
- Cổng bond thêm vào lúc RSTP đang bật bị bỏ gói đến khi bật lại RSTP → `up`/`start` luôn bật RSTP sau cùng (mạng ngắt vài giây).
- veth và namespace quản trị mất khi máy này khởi động lại: `make libvirt-start` dựng lại.

- GCP có router `.1` của VPC; máy nhà không có → `lab_hosting: onprem`: máy trỏ gateway thẳng vào firewall `.253` của vùng,
  `extra_routes` (DMZ → LAN/MGMT qua core `.252`) thành route tĩnh trên máy trong DMZ và trên firewall biên. Core tắt
  reply-to (trả lời máy DMZ đi thẳng, không vòng qua biên). Địa chỉ `.1` bỏ trống.
- MAC lấy theo IP (`52:54:0a:14:00:0b` = 10.20.0.11; card trunk theo IP đầu tiên): dựng lại VM không đổi MAC.
- VM Linux: lớp qcow2 trên Ubuntu 24.04 cloud image + cloud-init (user `ubuntu`, khoá SSH, IP tĩnh + route giống role
  `node_network`).
- Firewall: lớp qcow2 trên bản nano gốc + đĩa FAT `LABCFG` chứa `config.xml` (như cắm USB); `up` đăng nhập qua console nối
  tiếp, chép vào `/conf/config.xml`, khởi động lại, rồi gỡ đĩa. Log: `out/logs-console-<firewall>.txt`.
- `up` dừng nếu máy này có route trùng dải lab (mạng libvirt cũ, VPN khác…).

## Khác GCP (chỉ trong `provisioned.yml`)

| | GCP | Máy nhà |
|---|---|---|
| IP public | IP tĩnh GCP (gcp.sh ghi) | 10.99.0.2 / 10.99.0.3 trên `lab-wan` |
| Gateway của máy | `.1` của VPC (route VPC trỏ vào firewall) | firewall `.253` trực tiếp + route tĩnh |
| IP máy | DHCP của VPC | IP tĩnh (cloud-init, rồi netplan) |
| NTP client | chrony | systemd-timesyncd |
| Máy admin | IP public thật | 10.99.0.1 (`admin_public_ip`) — WAN của biên không chặn dải private |
