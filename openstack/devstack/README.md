# DevStack lab (KVM/libvirt)

VM chạy [DevStack](https://opendev.org/openstack/devstack) — môi trường OpenStack
để học/test, dựng bằng `virt-install` trên KVM/libvirt. Có sẵn Nova, Neutron,
Cinder (+ Cinder Backup), Glance, Keystone, Trove (Database as a Service, gồm
MySQL/MariaDB/PostgreSQL), Neutron FWaaS, và Skyline (dashboard mới, thay Horizon).

Muốn hiểu cách mạng OpenStack (Neutron) hoạt động, dùng chính lab này làm ví
dụ: xem [NETWORKING.md](NETWORKING.md). Muốn hiểu từng service OpenStack
(Nova, Cinder, Glance, Swift, Trove...) làm gì và liên hệ ra sao: xem
[OPENSTACK-COMPONENTS.md](OPENSTACK-COMPONENTS.md). Muốn hiểu từng mục trong
menu Horizon/Skyline (Key Pairs, Server Groups, Volume Snapshots, Trunks,
Application Credentials...): xem [DASHBOARD-RESOURCES.md](DASHBOARD-RESOURCES.md).

## Cấu trúc — 2 việc tách riêng

**Tạo/dừng/xoá VM là hạ tầng (bash, `virsh`/`virt-install`). Cài DevStack là
configuration management (Ansible).** Hai việc khác bản chất nên không trộn vào
một công cụ.

```
vm/                       Vòng đời VM — không biết gì về DevStack
  create-vm.sh            Dựng VM Ubuntu trống (chỉ user "stack" + package cơ bản)
  cloud-init.yaml.tmpl    Khung cloud-init, chỉ create-vm.sh dùng
  start-vm.sh             Bật VM (khôi phục managedsave nếu có)
  stop-vm.sh              Dừng VM (managedsave, trả RAM/CPU)
  destroy-vm.sh           Xoá VM + đĩa (--purge: xoá luôn cloud image gốc)

ansible/                     Cài DevStack lên MỘT HOST BẤT KỲ qua SSH — không
                             gọi virsh, không biết host chạy trên libvirt, cloud
                             hay máy vật lý, không biết gì về vm/ ở trên
  ansible.cfg
  inventory.ini.example        Ví dụ tham khảo, KHÔNG tự nạp — trỏ host qua "-i"
  group_vars/all.yml            admin_password, danh sách plugin
  roles/devstack/
    tasks/main.yml
    templates/local.conf.j2     local.conf sinh từ group_vars (Jinja2)
    files/local.sh              Script sửa mạng, stack.sh tự chạy ở cuối
  playbooks/install_devstack.yml
```

`vm/` và `ansible/` **không biết tới nhau**. `create-vm.sh` chỉ in ra IP
rồi kết thúc — không ghi file, không đụng gì trong `ansible/`. Muốn cài
DevStack lên IP đó (hoặc lên bất kỳ host Ubuntu nào khác, cloud hay vật lý),
tự trỏ Ansible vào bằng `-i` (xem "Sử dụng" bên dưới). Nhờ vậy đem riêng
`ansible/` sang máy khác, VM khác, hay pipeline CI khác vẫn chạy được, không
phải sửa gì trong nó. Muốn đổi RAM/CPU/dung lượng đĩa VM thì sửa
`vm/create-vm.sh`; muốn đổi plugin/mật khẩu DevStack thì sửa
`ansible/group_vars/all.yml`.

**Lưu ý:** chỉ chạy lại `install_devstack.yml` khi host **chưa có lần
`stack.sh` nào hoàn tất thành công**. Nếu đã "stack.sh completed" rồi mới đổi
cấu hình, phải dùng host mới — xem mục "Điều đã biết" bên dưới.

## Cài Ansible (một lần)

```bash
sudo pacman -S ansible-core   # Arch; các bản khác dùng ansible-core hoặc ansible
```

Không cần collection nào thêm — mọi module dùng đều là `ansible.builtin.*`.

## Sử dụng

```bash
# 1. Dựng VM trống (bash, không đụng Ansible) — in ra IP khi xong
./vm/create-vm.sh

# 2. Cài DevStack lên IP đó (Ansible) — "-i" là cách CHUẨN của Ansible để trỏ
#    target, không phải cơ chế riêng của project này. Trỏ vào host nào cũng
#    được, không chỉ VM tạo ở bước 1.
cd ansible
ansible-playbook -i "<IP>," playbooks/install_devstack.yml
# lỗi/cần đổi group_vars/all.yml → sửa rồi chạy lại đúng lệnh này, không cần dựng VM mới

# Thích dùng file inventory tĩnh thay vì gõ IP mỗi lần:
#   cp inventory.ini.example inventory.ini   # rồi điền IP thật
#   ansible-playbook -i inventory.ini playbooks/install_devstack.yml

# Vòng đời VM (bash, làm ở thư mục gốc)
./vm/stop-vm.sh        # dừng, trả RAM/CPU về host, giữ trạng thái
./vm/start-vm.sh       # bật lại, khôi phục đúng trạng thái lúc dừng
./vm/destroy-vm.sh          # xoá VM + đĩa, giữ cloud image gốc
./vm/destroy-vm.sh --purge  # xoá luôn cloud image gốc
./vm/destroy-vm.sh --fw     # kèm gỡ 2 rule iptables cho virbr0 (xem dưới)
```

Yêu cầu một lần: thư mục ảnh phải cho user ghi được (không cần `sudo` mỗi lần):
```bash
sudo chgrp libvirt /var/lib/libvirt/images
sudo chmod g+ws /var/lib/libvirt/images
```

## Truy cập sau khi cài xong

```bash
virsh -c qemu:///system domifaddr devstack   # lấy IP (create-vm.sh cũng in ra lúc tạo)
```

| | |
|---|---|
| SSH | `ssh ubuntu@<IP>` (mật khẩu `ubuntu`) |
| Horizon (dashboard cũ) | `http://<IP>/dashboard` — `admin` / `admin` |
| Skyline (dashboard mới) | `http://<IP>:9999` — `admin` / `admin` |
| CLI trong VM | `cd /opt/stack/devstack && source openrc admin admin` |

## Theo dõi tiến trình cài

```bash
tail -f /opt/stack/logs/stack.sh.log      # log chi tiết của stack.sh
tail -f /opt/stack/stack-run.log          # output thô của tiến trình chạy nền
pgrep -af stack.sh || echo "đã dừng"      # còn chạy không
cloud-init status --long                  # bước tạo user/clone code trước khi stack.sh chạy
```

Nhận biết kết quả trong `stack.sh.log`:
- **Thành công:** có dòng `This is your host IP address: ...`, `Horizon is now
  available at http://...`, `stack.sh completed in ... seconds.`
- **Lỗi:** có `[ERROR] ...` hoặc `stack.sh failed`. Xem chi tiết:
  `grep -n -i "error\|failed" /opt/stack/logs/stack.sh.log | tail -20`

Sau khi cài xong, kiểm tra dịch vụ:
```bash
cd /opt/stack/devstack && source openrc admin admin
openstack service list
systemctl list-units 'devstack@*' --no-pager | grep -v running   # dịch vụ nào không chạy
```

## Backup — 3 khái niệm khác nhau

| | Backup gì | Lưu ở đâu | Cần gì |
|---|---|---|---|
| **Nova instance backup** (`openstack server backup create`) | Toàn bộ đĩa 1 VM → Glance image | Glance (filesystem, mặc định) | Không cần Swift |
| **Cinder volume backup** (`openstack volume backup create`) | 1 volume, kiểu incremental | Swift (driver mặc định) | Cần service `c-bak` + Swift |
| **Trove database backup** (`openstack database backup create`) | Data trong 1 Trove instance | Swift | Cần Swift |

VM snapshot (`virsh snapshot-create-as`) là khái niệm khác hẳn — backup **toàn bộ
VM hạ tầng** (RAM + đĩa + mọi service bên trong), dùng để rollback nhanh khi thử
nghiệm, không phải tính năng của OpenStack.

## Điều đã biết — tránh lặp lại

- **Không dùng `virsh snapshot-revert` để "quay lại rồi thêm plugin".** OVN (backend
  mạng Neutron) lưu trạng thái riêng ngoài MySQL. Revert về mốc đã có network rồi
  chạy lại `stack.sh` sẽ luôn lỗi `No project network is available for allocation`.
  **Đổi plugin/service = dựng VM mới**, không re-stack VM cũ.
- **`group_vars/all.yml` (qua `local.conf.j2`) phải luôn bật Swift** nếu dùng
  Trove backup hoặc Cinder backup (`c-bak`) — cả hai đều mặc định lưu vào Swift.
- **Plugin Trove tự cài `trove-tempest-plugin`** ở bước `test-config` dù đã tắt
  tempest (bug của plugin.sh) — role `devstack` đã clone sẵn repo đó trước khi
  `stack.sh` chạy, không phải chạy `stack.sh` 2 lần để né lỗi này.
- **Tạo database PostgreSQL qua Trove: không truyền `--collate`/`--character_set`.**
  Giá trị mặc định `utf8_general_ci` là collation kiểu MySQL, PostgreSQL không hiểu,
  lỗi `invalid LC_COLLATE locale name`. Bỏ trống để dùng default của datastore.
- **Gateway mạng `trove-mgmt` có thể rơi đúng đầu/cuối dải IP** (`.10` hoặc `.200`)
  — `local.sh` đã xử lý edge case này (chỉ thêm nửa allocation-pool còn hợp lệ).
- **Bật Swift (`s-proxy`) bắt buộc phải có `SWIFT_HASH`** trong `local.conf` —
  thiếu thì `stack.sh` hỏi tương tác "ENTER A RANDOM SWIFT HASH", treo vô hạn
  khi chạy qua Ansible (không có stdin).
- **Bật Swift còn cần `SWIFT_MAX_FILE_SIZE`** lớn hơn mặc định (1GB) — mặc
  định thấp hơn cả ảnh guest Trove (~1.4GB do `TROVE_EMBED_DATASTORE_IMAGES`),
  gây lỗi `413 Request Entity Too Large` khi Glance (tự đổi sang lưu Swift
  lúc Swift bật) upload ảnh.
- **Clone `trove-tempest-plugin` qua Ansible KHÔNG được dùng `depth: 1`** —
  shallow clone của module `git` Ansible không fetch tag, làm `pbr` lỗi
  "Versioning for this project requires ... upstream git repository" khi
  `pip install`. `git clone --depth 1` dòng lệnh thường thì không bị (có fetch
  tag), đây là khác biệt riêng của module Ansible.
- **Mọi endpoint API đăng ký bằng hostname `devstack`**, không phải IP (VM đặt
  `hostname: devstack` trong cloud-init, `SERVICE_HOST` không mặc định dùng
  `HOST_IP` như kỳ vọng). Trong VM tự phân giải được (`/etc/hosts` tự trỏ
  `127.0.0.1`), nhưng máy ngoài/browser thì không — mọi link trực tiếp từ
  catalog (như link tải backup) cần thêm `<IP> devstack` vào `/etc/hosts` máy
  đó mới mở được.
- **Tính năng lịch backup của Trove (`schedule_create`, dựa vào Mistral)
  không dùng được** — workflow `trove.backup_create` nó cần không tồn tại ở
  bất kỳ đâu trong code hiện tại (đã kiểm tra cả `mistral-extra` lẫn `trove`).
  Muốn lịch backup thật, dùng cron gọi `openstack database backup create`.
- **Network Trunk/QoS (`q-trunk`, `q-qos`) không bật theo mặc định** — đã
  thêm vào `local.conf.j2`, nhưng chỉ VM dựng **sau** khi thêm dòng đó mới có;
  VM cũ không tự có tính năng này.
