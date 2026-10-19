# Tài nguyên trong Dashboard — mọi mục bạn thấy trong menu Horizon/Skyline

`OPENSTACK-COMPONENTS.md` giải thích theo **service** (Nova, Cinder, Neutron...).
Tài liệu này giải thích theo **menu bạn thấy khi mở dashboard** — Compute,
Volumes, Network — vì nhiều mục (Key Pairs, Server Groups, Volume Groups...)
là 1 *loại tài nguyên* bên trong 1 service, không phải bản thân 1 service, nên
không có chỗ đứng rõ ràng trong tài liệu kia. Mọi ví dụ dưới đây là tài nguyên
**thật** đã tạo trên VM lab để minh hoạ — mở dashboard, bạn sẽ thấy đúng chúng.

## Compute

### Instances, Images
Đã giải thích ở `OPENSTACK-COMPONENTS.md` (mục 2, 4) — instance là VM đang
chạy (Nova), image là "khuôn" cài OS sẵn (Glance).

### Key Pairs — SSH public key đăng ký sẵn với Nova

**Vấn đề nó giải quyết:** VM mới tạo chưa có mật khẩu bạn biết trước — làm
sao đăng nhập lần đầu? Thay vì đặt mật khẩu (không an toàn, dễ đoán), Nova
**tiêm sẵn 1 SSH public key vào VM lúc boot** (qua cloud-init/config-drive,
đúng cơ chế `ssh_authorized_keys` bạn đã dùng ở `vm/cloud-init.yaml.tmpl`) —
bạn chỉ cần giữ đúng private key tương ứng để đăng nhập, không cần mật khẩu.

```bash
openstack keypair create mykey > mykey.pem   # Nova tạo cặp key, trả về private key
chmod 600 mykey.pem
openstack server create --key-name mykey ...  # gắn public key vào VM lúc tạo
ssh -i mykey.pem ubuntu@<IP>
```

Đã tạo thật trong lab (`mykey`, fingerprint `c4:7f:12:e5:8f:ea:ca:74:...`) —
xem `openstack keypair list`. **Lưu ý:** Nova chỉ giữ **public key**; private
key chỉ hiện ra đúng 1 lần lúc tạo, mất là phải tạo cặp mới, không lấy lại
được — giống hệt cách `ssh-keygen` hoạt động bạn đã quen ở `~/.ssh/`.

### Server Groups — quy tắc đặt VM cạnh nhau hay tách xa nhau

**Vấn đề nó giải quyết:** bạn chạy 3 VM cùng 1 ứng dụng để chịu lỗi
(high-availability) — nếu cả 3 vô tình bị Nova xếp chung 1 compute host, host
đó chết là mất cả 3. **Server Group** ra lệnh cho `nova-scheduler` 1 chính
sách khi đặt VM:

| Policy | Ý nghĩa |
|---|---|
| `anti-affinity` | Các VM trong nhóm **không được** cùng 1 compute host — cho HA |
| `affinity` | Các VM trong nhóm **bắt buộc** cùng 1 compute host — cho hiệu năng (giảm độ trễ mạng giữa chúng) |
| `soft-anti-affinity` / `soft-affinity` | Giống trên nhưng chỉ là **ưu tiên**, không bắt buộc — nếu không đủ host thì vẫn tạo được VM, không báo lỗi |

```bash
openstack server group create --policy anti-affinity my-group
openstack server create --hint group=<group-id> ...   # tạo VM, gắn vào group
```

Đã tạo thật (`my-group`, policy `anti-affinity`) — trong lab 1 compute node
duy nhất, policy này không có tác dụng thực tế (không có host thứ 2 để tách
ra), nhưng cú pháp/khái niệm giống hệt production nhiều node.

## Volumes

### Volumes, Backups
Đã giải thích ở `OPENSTACK-COMPONENTS.md` mục 5.

### Volume Types & QoS — chọn "loại ổ đĩa", giới hạn tốc độ

Lab có sẵn 2 volume type:
```bash
openstack volume type list
# lvmdriver-1    ← backend LVM thật đang chạy trong lab
# __DEFAULT__    ← dùng nếu không chỉ định type nào
```

Volume Type là "nhãn" chọn backend lưu trữ (production thường có nhiều loại:
Ceph SSD nhanh-đắt, Ceph HDD chậm-rẻ...). Gắn thêm được **QoS spec**
(`openstack volume qos create`, extension `qos-specs-manage` — đã xác nhận
có trong lab) để giới hạn **IOPS/băng thông tối đa** cho volume dùng type đó,
tách "loại lưu trữ nào" khỏi "nhanh bao nhiêu". Đây là **Cinder QoS** (giới
hạn tốc độ ổ đĩa) — khác **Network QoS** của Neutron (giới hạn băng thông
mạng, xem mục Network bên dưới), 2 tính năng của 2 service khác nhau, chỉ
trùng tên.

### Volume Snapshots — điểm khôi phục nhanh, cùng pool lưu trữ

Khác **Backup** (copy hẳn ra Swift, tách biệt hoàn toàn — mục 5), **Snapshot**
là bản ghi "trạng thái tại 1 thời điểm" ngay **trong cùng backend** (LVM
trong lab này), tạo gần như tức thì nhờ cơ chế *copy-on-write* (chỉ ghi lại
phần **thay đổi** so với volume gốc, không copy toàn bộ).

```bash
openstack volume snapshot create --volume test-vol test-vol-snap
openstack volume create --snapshot test-vol-snap new-vol   # tạo volume mới từ snapshot
```

Đã tạo thật (`test-vol` 1GB → snapshot `test-vol-snap`, status `available`).
**Đánh đổi:** nhanh và rẻ, nhưng nếu backend LVM/Ceph gốc hỏng, **mất luôn cả
volume gốc lẫn snapshot** — đây là lý do backup (tách hẳn sang Swift) vẫn cần
thiết dù đã có snapshot, không thể thay thế nhau.

### Volume Groups — snapshot/backup nhiều volume cùng lúc, đảm bảo đồng bộ

**Vấn đề nó giải quyết:** 1 ứng dụng dùng 2 volume riêng (ví dụ: 1 volume
chứa data database, 1 volume chứa log) — nếu snapshot từng volume riêng lẻ ở
2 thời điểm hơi lệch nhau, dữ liệu khôi phục có thể **không khớp nhau** (data
mới hơn log, hoặc ngược lại). **Volume Group** gộp nhiều volume lại,
snapshot/backup **cùng 1 thời điểm chính xác** cho cả nhóm.

```bash
openstack volume group type list                      # cần group type trước
openstack volume group create --name my-group --volume-type <type> <group-type>
openstack volume group snapshot create --volume-group my-group my-group-snap
```

## Network

Router, Floating IP, Security Group, Network Topology — đã giải thích đầy đủ
trong [NETWORKING.md](NETWORKING.md) (mục 2, 4, 5, 6). Tóm tắt 1 dòng mỗi
mục để tra nhanh khi lướt dashboard:

| Mục trong dashboard | 1 dòng nhắc lại | Xem chi tiết |
|---|---|---|
| **Networks** | Network do bạn tự tạo (tenant) hoặc admin tạo sẵn (provider) | NETWORKING.md mục 2 |
| **Routers** | Nối tenant network với external network, làm NAT | NETWORKING.md mục 4 |
| **Floating IPs** | 1 IP từ external network gán riêng cho 1 VM, nhận traffic từ ngoài vào | NETWORKING.md mục 4 |
| **Security Groups** | Firewall theo IP+port+protocol, gắn vào từng VM (port) | NETWORKING.md mục 5 |
| **Network Topology** | Chỉ là hình vẽ trực quan hoá — không phải 1 loại tài nguyên riêng, chỉ vẽ lại Networks+Routers+Instances đã có | — |

**Load Balancers** (mục có thể thấy trên dashboard 1 số bản OpenStack) cần
service **Octavia** — chưa cài trong lab này (xem
`OPENSTACK-COMPONENTS.md` mục 10).

### RBAC (network) — chia sẻ network/subnet-pool cho project khác

Mặc định 1 network chỉ project tạo ra nó thấy được (trừ network `public` do
admin đánh dấu "shared"). Mục **RBAC** trong Network cho phép chia sẻ **1
network cụ thể** (hoặc subnet pool) cho **1 project cụ thể khác**, không
public cho tất cả như cờ "shared".

```bash
openstack network rbac list
```
Lab đã có sẵn 4 rule thật (DevStack tự tạo khi setup network `public`) —
2 rule chia sẻ network `public`/`private` (cho phép project khác dùng làm
external network), 2 rule chia sẻ subnet pool tương ứng.

### Trunk & QoS (network) — đã bật và test thật

Lúc kiểm tra ban đầu **chưa bật** trong lab (API trả `404 Not Found`) — đã
thêm `enable_service q-trunk q-qos` vào `ansible/roles/devstack/templates/
local.conf.j2`, dựng VM mới, test tạo thật cả 2 thành công (không chỉ hết
lỗi 404 — tạo được resource, resource chuyển `ACTIVE`).

- **Network Trunk**: gắn **nhiều network** vào **1 port duy nhất** của VM,
  phân biệt bằng VLAN tag — để 1 VM tự xử lý nhiều VLAN bên trong nó (dùng
  cho VM chạy switch/router ảo, hoặc container network bên trong VM). Đây là
  khái niệm **"trunk port" ở mức Neutron port**, khác trunk port của switch
  vật lý đã nói ở NETWORKING.md mục 0.14 (2 khái niệm cùng tên "trunk" nhưng
  áp cho 2 tầng khác nhau — data center switch thật vs Neutron port ảo).
  ```bash
  openstack port create --network private test-port
  openstack network trunk create --parent-port <port-id> test-trunk
  # sau đó gắn thêm sub-port (network khác, có VLAN ID riêng):
  openstack network trunk set --subport port=<sub-port-id>,segmentation-type=vlan,segmentation-id=101 test-trunk
  ```
  Đã tạo thật (`test-trunk`, status `ACTIVE`, parent port `test-port`).

- **Network QoS Policy**: giới hạn băng thông tối đa cho 1 port/network cụ
  thể (khác **Cinder QoS** ở mục Volume Type bên trên — đó là giới hạn IOPS
  ổ đĩa, đây là giới hạn băng thông mạng, 2 tính năng độc lập của 2 service
  khác nhau dùng chung chữ "QoS"). Tạo policy xong phải gắn thêm **rule**
  (policy trống không giới hạn gì), rồi gắn policy vào port cần áp:
  ```bash
  openstack network qos policy create test-qos
  openstack network qos rule create --type bandwidth-limit \
    --max-kbps 10000 --max-burst-kbits 1000 test-qos
  openstack port set --qos-policy test-qos <port-id>
  ```
  Đã tạo thật (`test-qos`, rule giới hạn 10Mbps/burst 1Mbps, direction
  `egress` — chỉ giới hạn chiều **ra**, không giới hạn chiều vào).

## Instance Snapshot — dễ nhầm với Volume Snapshot, nhưng khác hẳn

**Volume Snapshot** (ở trên) chỉ chụp 1 volume rời (Cinder). **Instance
Snapshot** (nút "Create Snapshot" ở trang Instances, lệnh
`openstack server image create`) chụp lại **toàn bộ đĩa boot của 1 VM đang
chạy**, biến nó thành **1 Glance image mới** — dùng để tạo VM khác giống hệt,
hoặc làm bản backup "đóng băng" trạng thái hiện tại của VM.

```bash
openstack server image create --name app-test-snapshot <server-id>
openstack image list   # image mới xuất hiện, tạo VM mới từ nó y hệt VM cũ
```

Khác biệt cốt lõi: Volume Snapshot ở lại trong Cinder (nhanh, rẻ, gắn với
backend gốc); Instance Snapshot trở thành 1 Image độc lập trong Glance (nặng
hơn, nhưng tách khỏi VM/volume gốc hoàn toàn — xoá VM gốc, image vẫn còn).

## Object Store (Swift) — Containers

Khi bật Swift, dashboard có thêm mục **Containers** — đúng khái niệm
"container" đã giải thích ở `OPENSTACK-COMPONENTS.md` mục 7 (giống thư mục
phẳng chứa object). Bạn có thể tự upload file qua dashboard vào 1 container,
y hệt cách Trove/Cinder Backup/Glance tự động làm phía sau.

## Database (Trove) — 2 mục ngoài Instances/Backups

### Configuration Groups — 1 bộ tham số áp cho nhiều database cùng lúc

Thay vì sửa tay `max_connections`, `work_mem`... trên từng database instance,
tạo **1 configuration group** chứa sẵn các tham số, rồi gắn vào nhiều
instance cùng lúc — sửa 1 chỗ, áp dụng hàng loạt.

```bash
openstack database configuration create my-pg-config '{"max_connections": 200}' \
  --datastore postgresql --datastore-version 18
openstack database instance attach-configuration <instance> <config-group-id>
```
Đã tạo thật trong lab (`my-pg-config`, `max_connections=200`).

### Clusters — nhiều database instance hoạt động như 1 cụm

Trove hỗ trợ tạo **cluster** (`openstack database cluster create`) — nhiều
instance cùng datastore, tự cấu hình replication/sharding giữa chúng (tuỳ
datastore, ví dụ MySQL Galera cluster, MongoDB replica set). Lab chưa tạo
cluster nào (`openstack database cluster list` rỗng, nhưng lệnh tồn tại và
chạy được — tính năng có sẵn, chỉ chưa dùng tới).

## Identity — Project, User, Application Credentials

Đa số mục trong nhóm **Identity** chỉ admin thấy đầy đủ (Projects, Users,
Roles) — nhưng có 2 mục user thường cũng thấy trong Project menu của mình:

### Application Credentials — "chìa khoá phụ" để tự động hoá gọi API

**Vấn đề nó giải quyết:** script/Ansible của bạn hiện đăng nhập bằng
`ADMIN_PASSWORD` thật (`admin`/`admin`) — lộ file là lộ **toàn quyền admin**,
đổi được cả mật khẩu chính. Application Credential là 1 "chìa khoá phụ" giới
hạn quyền, thu hồi riêng lẻ được mà không ảnh hưởng tài khoản gốc.

```bash
openstack application credential create my-automation --description "..."
# → trả id + secret (secret chỉ hiện 1 lần, giống Key Pair)
openstack --os-auth-type v3applicationcredential \
  --os-application-credential-id <id> --os-application-credential-secret <secret> \
  server list
```
Đã tạo thật (`my-automation`, roles kế thừa từ user tạo: `admin, manager,
member, reader`). **Áp dụng thực tế cho chính project này:**
`ansible/group_vars/all.yml` đang dùng mật khẩu admin gốc — nên đổi Ansible
sang xác thực bằng Application Credential thay vì mật khẩu admin.

### API Access — tab hiện sẵn URL từng service + tải file đăng nhập

Tab **API Access** trong Project menu liệt kê URL thật của mọi service (giống
`openstack catalog list`), và cho tải sẵn file `openrc`/`clouds.yaml` để dùng
CLI — chính là file bạn đã dùng suốt (`source openrc admin admin`), chỉ khác
là tab này cho **tải trực tiếp qua giao diện**, không cần biết nó nằm ở
`/opt/stack/devstack/openrc`.

### Groups — gom nhiều user, gán role 1 lần cho cả nhóm

Thay vì gán role cho từng user riêng lẻ, gom vào **Group** rồi gán role cho
group — thêm/bớt user khỏi group là đủ, không cần sửa role từng người. Lab có
sẵn 2 group DevStack tự tạo để demo: `admins`, `nonadmins`
(`openstack group list`).

## Khái niệm xuyên suốt mọi tài nguyên — không thuộc riêng menu nào

### Metadata — gắn nhãn tuỳ ý (key-value) vào tài nguyên

Hầu hết tài nguyên (instance, volume, image, network...) cho gắn thêm
**metadata** — cặp key-value tuỳ bạn đặt, OpenStack không đọc/hiểu ý nghĩa,
chỉ lưu hộ. Dùng để tự phân loại/tự động hoá (ví dụ script của bạn lọc
`env=production` để biết cái nào không được xoá nhầm).

```bash
openstack volume set --property env=test test-vol
openstack volume show test-vol -c properties   # properties: env='test'
```
Đã đặt thật lên `test-vol` trong lab.

### Quotas — giới hạn tài nguyên mỗi project được dùng

Admin đặt trần cho từng project (project = "khách hàng" trong đa số cloud) để
1 project không chiếm hết tài nguyên chung:

```bash
openstack quota show admin
```
Giá trị thật trong lab: `instances=10`, `cores=20`, `ram=51200` (MB),
`floating_ips=50`, `volumes=10`, `backups=10`... — vượt trần, lệnh tạo mới sẽ
bị từ chối dù tài nguyên vật lý vẫn còn trống.

Trang **Overview** (Compute) trên dashboard vẽ lại đúng số liệu Quota này
dạng thanh tiến trình (đã dùng bao nhiêu / trần bao nhiêu). Lệnh CLI tương
ứng `openstack usage show` bị lỗi thật trong lab khi test
(`unsupported format string passed to NoneType.__format__`) — 1 bug có sẵn
của bản DevStack này, không phải do bạn cấu hình sai; xem quota bằng
`openstack quota show` như trên vẫn hoạt động bình thường.

### Availability Zone / Host Aggregate — nhóm compute host

- **Availability Zone (AZ)**: nhóm host mà **user thấy được**, dùng để chọn
  "đặt VM vào khu vực nào" (thường ứng với 1 phòng máy/1 khu vực điện-mạng
  riêng, để lỡ mất điện 1 khu vẫn còn khu khác). Lab hiện có AZ `nova` (mặc
  định) và `internal` (dành cho service nội bộ) — `openstack availability
  zone list`.
- **Host Aggregate**: nhóm host **chỉ admin thấy**, dùng để phân loại phần
  cứng (host có SSD riêng, host có GPU riêng...) rồi cấu hình scheduler ưu
  tiên đặt đúng loại VM vào đúng nhóm host. 1 Host Aggregate có thể "lộ ra"
  thành 1 Availability Zone cho user thấy, hoặc giữ kín chỉ admin dùng nội bộ.

## Dọn tài nguyên ví dụ đã tạo (tuỳ chọn)

**Lưu ý:** các ví dụ `mykey`, `test-vol`, `test-vol-snap`, `my-group`,
`my-pg-config`, `my-automation` được tạo trên **VM trước** — VM đó đã bị xoá
khi dựng VM mới để test Trunk/QoS, nên các tài nguyên đó **không còn tồn
tại**, không phải do dọn tay. Muốn xem lại, tạo lại đúng lệnh ở từng mục
tương ứng phía trên trên VM hiện tại.

Trên **VM hiện tại** (`192.168.122.5`) chỉ còn 3 tài nguyên ví dụ vừa tạo để
test Trunk/QoS (`test-qos`, `test-trunk`, `test-port`), không tốn tài nguyên
đáng kể, có thể giữ lại để tự xem trên dashboard. Muốn dọn:

```bash
openstack network trunk delete test-trunk
openstack network qos policy delete test-qos
openstack port delete test-port
```
