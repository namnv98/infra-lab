# Các thành phần OpenStack — giải thích qua chính lab này

Tài liệu này giải thích từng service OpenStack làm gì, chạy như thế nào, và
liên hệ với nhau ra sao — dùng đúng giá trị thật tra được trên VM lab
(`192.168.122.139` tại thời điểm viết). Phần mạng (Neutron) đã có riêng
[NETWORKING.md](NETWORKING.md), tài liệu này tập trung vào các service còn lại
và bức tranh tổng thể.

## 0. Cách các service nói chuyện với nhau

Trước khi vào từng service, cần hiểu bộ khung chung — mọi service OpenStack
đều dùng lại đúng 3 thứ này:

1. **Keystone làm gốc xác thực cho tất cả.** Mọi lời gọi API (kể cả giữa các
   service với nhau, không chỉ từ user) đều cần 1 **token** xin từ Keystone
   trước.
2. **Mỗi service có 1 database riêng** trong cùng MySQL (`nova`, `nova_api`,
   `cinder`, `neutron`, `glance`, `trove`...) — services không đọc thẳng DB
   của nhau, luôn qua API.
3. **RabbitMQ (message queue)** dùng cho giao tiếp **nội bộ** giữa các tiến
   trình của cùng 1 service (ví dụ `nova-api` → `nova-scheduler` →
   `nova-conductor` → `nova-compute`) — không dùng cho giao tiếp *giữa* các
   service khác nhau (cái đó luôn qua REST API + token).

Trong lab, mọi API (trừ Swift) đi qua chung **1 cổng 80**, do Apache
(`ProxyPass`) chuyển tiếp vào đúng service phía sau qua **Unix socket** hoặc
1 cổng TCP nội bộ (`127.0.0.1:...`) — đây là lý do bạn gọi
`http://192.168.122.139/compute/...`, `/volume/...`, `/image/...` mà không
cần nhớ cổng riêng của từng service. Xem `/etc/apache2/sites-enabled/` trong
VM để thấy từng `ProxyPass` cụ thể — đúng cơ chế đã dùng để debug lỗi Swift
413 trước đó.

## 1. Keystone — Identity (danh tính & xác thực)

**Việc nó làm:** quản lý **project** (còn gọi tenant — 1 "không gian" cô lập
tài nguyên, ví dụ `admin`, `demo`), **user**, **role** (quyền: `admin`,
`member`...), và phát hành **token** khi đăng nhập đúng. Mọi service khác
tin tưởng token do Keystone ký, không tự làm xác thực riêng.

Keystone cũng giữ **service catalog** — danh sách URL của mọi service khác
(`openstack endpoint list`). Đây chính là nơi bạn từng thấy lỗi thật: catalog
đăng ký toàn bộ endpoint bằng hostname `devstack` thay vì IP, khiến link tải
backup không mở được từ máy ngoài VM.

```bash
openstack token issue          # xin 1 token thật
openstack project list         # xem project (admin, demo, service...)
openstack endpoint list        # xem URL từng service
```

## 2. Nova — Compute (quản lý VM)

**Việc nó làm:** tạo/xoá/resize VM (gọi là **instance**), chọn compute node
nào đủ tài nguyên để đặt VM (scheduling), theo dõi trạng thái VM.

**4 tiến trình chính** (đã thấy trong `ps` khi debug lab):
- `nova-api` — nhận request từ user/CLI.
- `nova-scheduler` — chọn compute node phù hợp.
- `nova-conductor` — trung gian giữa API/scheduler và database (để
  `nova-compute` không cần quyền truy cập DB trực tiếp, an toàn hơn).
- `nova-compute` — chạy trên từng compute node, **gọi thẳng xuống
  hypervisor** để thực sự tạo VM.

**Điểm quan trọng nhất — đúng thứ bạn đã tự tay làm quen:** trong lab này,
Nova cấu hình `compute_driver = libvirt.LibvirtDriver` (`/etc/nova/nova.conf`)
— nghĩa là mỗi khi bạn `openstack server create`, `nova-compute` **tự gọi
`libvirt` giúp bạn**, làm đúng việc `virt-install`/`virsh` bạn từng gõ tay ở
`vm/create-vm.sh`. Nova không tự ảo hoá — nó **điều phối** hypervisor có sẵn
(KVM/libvirt ở đây; có thể là VMware, Hyper-V, hoặc Ironic cho bare-metal ở
nơi khác).

**Flavor** = cấu hình cứng (RAM/CPU/disk) cho 1 VM, giống "gói dịch vụ":
```
m1.tiny    512MB RAM,  1GB disk
m1.small   2GB   RAM, 20GB disk
m1.medium  4GB   RAM, 40GB disk
```

## 3. Placement — theo dõi tài nguyên còn trống

**Việc nó làm:** tách riêng từ Nova (trước đây nằm trong `nova-scheduler`) —
chỉ giữ 1 việc: biết mỗi compute node còn bao nhiêu CPU/RAM/disk trống.
`nova-scheduler` hỏi Placement "node nào đủ chỗ cho flavor này" trước khi
quyết định đặt VM vào đâu. Tách riêng để nhiều service khác (không chỉ Nova)
đều dùng chung 1 nguồn thông tin tài nguyên chính xác.

## 4. Glance — Image (ảnh cài đặt OS)

**Việc nó làm:** lưu trữ **image** — file `.qcow2`/`.raw` chứa OS đã cài sẵn,
dùng làm "khuôn" để Nova tạo VM mới (boot từ image, không cài Linux lại từ
đầu mỗi lần).

```bash
openstack image list
# cirros-0.6.3-x86_64-disk       ← image test nhỏ (~20MB), có sẵn mặc định
# trove-guest-ubuntu-noble        ← Trove tự build, dùng làm VM chạy database
```

**Bài học thật từ lab:** Glance không tự lưu file — nó lưu vào 1 **backend**
cấu hình sẵn (`[glance_store] default_store`), mặc định là đĩa cục bộ
(`file`). Khi bạn bật Swift, Glance **tự động đổi sang lưu vào Swift** —
hành vi ngầm định này chính là nguyên nhân gốc của lỗi 413 (ảnh 1.4GB vượt
giới hạn `max_file_size` mặc định của Swift, không phải giới hạn của Glance).

## 5. Cinder — Block Storage (ổ đĩa rời)

**Việc nó làm:** tạo **volume** — 1 "ổ cứng ảo" độc lập, gắn (attach) được
vào bất kỳ VM nào, tháo ra gắn sang VM khác được, dữ liệu giữ nguyên (khác
đĩa boot mặc định của VM — đĩa đó biến mất khi xoá VM).

**Tiến trình chính:**
- `cinder-api`, `cinder-scheduler` — giống vai trò của Nova.
- `cinder-volume` — thực sự tạo volume, gọi xuống backend lưu trữ (LVM trong
  lab này — `VOLUME_BACKING_FILE_SIZE=30G` trong `local.conf` chính là đặt
  kích thước cho backend LVM đó; production thật thường dùng Ceph/SAN/NAS).
- `cinder-backup` — dịch vụ **riêng** để backup volume (mục 8 README, đã bật
  trong lab qua `enable_service c-bak`), lưu vào Swift.

**Phân biệt 3 khái niệm hay nhầm:**
| | Volume | Snapshot | Backup |
|---|---|---|---|
| Là gì | 1 ổ đĩa ảo | Điểm khôi phục *trong cùng* pool lưu trữ | Bản sao tách hẳn ra ngoài (Swift) |
| Tốc độ tạo | — | Nhanh (copy-on-write) | Chậm hơn (copy toàn bộ dữ liệu) |
| An toàn nếu pool gốc hỏng | — | **Mất theo** (cùng pool) | **Còn** (backend khác hẳn) |

## 6. Neutron — Networking

Đã có tài liệu riêng đầy đủ: [NETWORKING.md](NETWORKING.md) — từ khái niệm
mạng cơ bản (IP, subnet, VLAN...) tới kiến trúc Neutron thật (provider
network, OVN, floating IP, security group, FWaaS).

## 7. Swift — Object Storage

**Việc nó làm:** lưu trữ dạng "object" — không phải file trong thư mục
(như Cinder/ổ đĩa), không phải block thô, mà là **cặp key-value** (tên object
+ dữ liệu), truy cập qua HTTP, không "mount" được như ổ đĩa thường.

**Cấu trúc:** `Account` (ứng với 1 project) → `Container` (giống "thư mục",
nhưng phẳng, không lồng nhau) → `Object` (file thật). URL bạn đã thấy khi
debug backup:
```
http://<host>:8080/v1/AUTH_<project_id>/database_backups/<id>.tar.gz
                    └─ account ─┘        └── container ──┘  └object┘
```

**Swift không phải "1 dịch vụ đứng riêng"** — nó thường là **nơi các service
khác gửi dữ liệu vào**, đúng như 3 trường hợp bạn đã tự trải nghiệm trong lab
này: Glance dùng làm nơi lưu image (khi bật Swift), Cinder Backup dùng làm
nơi lưu backup volume, Trove dùng làm nơi lưu backup database.

**Ring** (khái niệm nâng cao, không cần sâu cho lab 1 node): bảng ánh xạ
"object này nằm ở ổ đĩa vật lý nào, có mấy bản sao (replica)" — cho phép
Swift scale ra hàng trăm ổ đĩa/node mà vẫn tìm đúng dữ liệu nhanh.

## 8. Trove — Database as a Service (DBaaS)

**Việc nó làm:** tự động hoá việc chạy database (MySQL/MariaDB/PostgreSQL)
— user chỉ cần `openstack database instance create`, không cần tự cài
MySQL, tự cấu hình network, tự lo backup.

**Cách hoạt động thật (đã thấy khi debug):** mỗi Trove instance = **1 VM
Nova bình thường** (boot từ image `trove-guest-ubuntu-noble` Trove tự build),
bên trong VM đó chạy **Docker** container database (MySQL/PostgreSQL), cộng
1 **guest agent** riêng của Trove (`trove-guestagent`) làm cầu nối giữa
Trove control plane và container database — nhận lệnh "tạo user", "tạo
database", "backup" rồi thực thi bên trong VM.

**3 tiến trình control plane:**
- `trove-api` — nhận request.
- `trove-taskmanager` — thực hiện tác vụ dài (tạo instance, backup...).
- `trove-conductor` — nhận heartbeat/trạng thái từ guest agent bên trong VM.

**Giới hạn đã phát hiện qua debug thật:** tính năng lịch backup tự động
(`schedule_create`) phụ thuộc Mistral và 1 workflow tên `trove.backup_create`
— workflow đó **không tồn tại** trong code hiện tại (đã kiểm tra cả
`mistral-extra` lẫn `trove`), nên tính năng này không dùng được dù có cài
Mistral. Lịch backup thật phải tự làm bằng cron gọi API (xem README).

## 9. Horizon vs Skyline — Dashboard

Cả 2 chỉ là **giao diện web gọi lại đúng các API ở trên** — không tự thêm
tính năng gì mới, không phải trung gian bắt buộc (mọi thứ Horizon làm được,
CLI `openstack` cũng làm được).

| | Horizon | Skyline |
|---|---|---|
| Tuổi | Từ khi OpenStack ra đời | Mới hơn, dần thay Horizon |
| Công nghệ | Django (Python, render HTML phía server) | React/Ant Design (SPA, gọi API bằng JS) |
| Cảm giác dùng | Load lại trang khi chuyển mục | Mượt hơn, không load lại trang |
| Trong lab | `http://<IP>/dashboard` | `http://<IP>:9999` |

## 10. Các service KHÔNG có trong lab này nhưng nên biết tên

OpenStack có hàng chục service, lab này chỉ bật những cái cần cho mục tiêu
học. Biết tên để không bỡ ngỡ khi gặp trong tài liệu/công việc thật:

| Service | Việc nó làm |
|---|---|
| **Heat** | Orchestration — định nghĩa cả cụm hạ tầng (VM+network+volume...) bằng 1 file YAML, tạo/xoá cả cụm cùng lúc (giống Terraform, nhưng là 1 phần của OpenStack) |
| **Mistral** | Workflow engine (đã kiểm tra ở lab này) — chạy chuỗi tác vụ nhiều bước theo lịch/điều kiện |
| **Manila** | File share dùng chung (NFS/CIFS) — giống Cinder nhưng nhiều VM gắn cùng lúc, khác Cinder chỉ 1 VM dùng 1 lúc |
| **Ironic** | Quản lý **bare-metal** (máy vật lý thật) qua cùng API như quản lý VM ảo — Nova gọi Ironic thay vì libvirt khi cần |
| **Octavia** | Load Balancer as a Service |
| **Barbican** | Quản lý key/secret (mã hoá, chứng chỉ TLS) tập trung |
| **Ceilometer/Telemetry** | Thu thập số liệu dùng tài nguyên (để tính phí, giám sát) |
| **Designate** | DNS as a Service |

## 11. Bảng tra nhanh

| Service | Tiến trình chính trong lab | Config chính |
|---|---|---|
| Keystone | `keystoneuWSGI` (uwsgi riêng, Apache proxy vào) | `/etc/keystone/keystone.conf` |
| Nova | `nova-api`, `nova-scheduler`, `nova-conductor`, `nova-compute` | `/etc/nova/nova.conf` |
| Placement | `placement` (uwsgi qua Apache) | `/etc/placement/placement.conf` |
| Glance | `glance-api` (uwsgi, `127.0.0.1:60999`) | `/etc/glance/glance-api.conf` |
| Cinder | `cinder-api`, `cinder-scheduler`, `cinder-volume`, `cinder-backup` | `/etc/cinder/cinder.conf` |
| Neutron | `neutron-api`, `neutron-ovn-agent`, `neutron-rpc-server` | `/etc/neutron/neutron.conf` |
| Swift | `swift-proxy-server` (cổng `8080`, không qua Apache) | `/etc/swift/proxy-server.conf` |
| Trove | `trove-api`, `trove-taskmanager`, `trove-conductor` | `/etc/trove/trove.conf` |
| Horizon | Apache `mod_wsgi` | `/opt/stack/horizon/openstack_dashboard/local/local_settings.py` |
| Skyline | `gunicorn` (cổng `9999`) | `/etc/skyline/skyline.yaml` |

Xem trạng thái tất cả service đang chạy thật:
```bash
systemctl list-units 'devstack@*' --no-pager
```
