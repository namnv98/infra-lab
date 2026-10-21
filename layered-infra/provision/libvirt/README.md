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
| `make libvirt-down` | 8 VM + đĩa của chúng, 4 mạng `lab-*` | image OS gốc (`/data/lab-images/`), `out/` |
| `make libvirt-purge` | như `down` + kết nối VPN `lab` + trạng thái máy nhà (`out/` hoặc `out-libvirt/`) | đang ở máy nhà thì chạy thêm `make libvirt-restore` |

Cả hai đọc `hosts.yml` + `provisioned.yml` cạnh đây, nên chạy được cả sau khi đã `restore` về GCP. Chỉ xoá đúng tên trong
đó, không đụng VM/mạng libvirt khác (vd. `default`).

Image OS gốc (OPNsense nano ~2GB, Ubuntu cloud image ~600MB) nằm ở `lab_image_dir` (`/data/lab-images/`): tải 1 lần, mọi
đĩa VM là lớp qcow2 mỏng trên đó. Không lệnh nào xoá thư mục này; muốn xoá hẳn: `rm -r /data/lab-images` (khi không còn VM).

Cần: `libvirt` (qemu:///system, user trong nhóm `libvirt`), `virt-install`, `xorriso`, `mtools`, `dosfstools`, `tmux`,
`wireguard-tools`, khoá `~/.ssh/id_ed25519`.

## Mạng

| Mạng libvirt | Dải | Máy này | Ghi chú |
|---|---|---|---|
| `lab-wan` | 10.99.0.0/24 | 10.99.0.1 (NAT ra Internet) | "Internet" của lab: biên 10.99.0.2 = IP web, 10.99.0.3 = IP VPN (Virtual IP) |
| `lab-dmz` · `lab-lan` · `lab-mgmt` | 10.10.10/24 · 10.20.0/24 · 10.40.0/24 | — | máy này không có IP → chỉ vào được qua VPN, như on-prem thật |

- GCP có router `.1` của VPC; máy nhà không có → `lab_hosting: onprem`: máy trỏ thẳng gateway vào firewall `.253` của vùng,
  `extra_routes` (DMZ → LAN/MGMT qua core `.252`) thành route tĩnh trên máy trong DMZ và trên firewall biên. Địa chỉ `.1`
  bỏ trống.
- VM Linux: máy i440fx, card ở khe PCI 4 → tên `ens4` như GCP. Firewall: card theo thứ tự khai báo = `vtnet0..n`.
- MAC lấy theo IP (`52:54:0a:14:00:0b` = 10.20.0.11): dựng lại VM không đổi MAC.
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
