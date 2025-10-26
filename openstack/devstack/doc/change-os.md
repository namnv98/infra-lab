Để **đổi OS từ CirrOS → Debian 12** cho instance OpenStack **và giữ lại floating IP** (ví dụ: `172.24.4.61`), bạn có
thể làm theo các bước sau:

---

## 🎯 Mục tiêu:

* **Cirros instance cũ**: `my-vm`
* **Floating IP đang dùng**: `172.24.4.61`
* **Image mới**: `debian-12`
* **Giữ nguyên keypair, network, security group...**

---

## ✅ Cách làm (tạo lại instance mới và gán lại IP)

### Bước 1: Gỡ floating IP khỏi VM cũ

```bash
openstack server remove floating ip my-vm 172.24.4.61
```

---

### Bước 2: Xoá VM CirrOS (nếu không cần giữ lại)

```bash
openstack server delete my-vm
```

> Nếu bạn vẫn muốn giữ VM CirrOS thì bỏ qua bước này.

---

### Bước 3: Tạo VM mới từ Debian 12

```bash
openstack server create \
  --image debian-12 \
  --flavor m1.small \
  --network shared \
  --key-name mykey \
  vm-debian12
```

> ⚠️ Bạn có thể thay `shared` bằng tên network nội bộ phù hợp với hệ thống của bạn
> ⚠️ `mykey` là tên SSH keypair đã tạo (dùng để SSH vào VM Debian)

---

### Bước 4: Gán lại Floating IP 172.24.4.61

```bash
openstack server add floating ip vm-debian12 172.24.4.61
```

---

### Bước 5: Kiểm tra trạng thái

```bash
openstack server list
openstack floating ip list
```

Đảm bảo VM mới đang ở trạng thái `ACTIVE` và IP `172.24.4.61` đã gắn đúng.

---

## 🎉 Giờ bạn có thể SSH vào Debian 12

```bash
ssh -i ~/.ssh/mykey.pem debian@<floating-ip>
# hoặc nếu cloud image Debian có user mặc định là 'admin' hoặc 'ubuntu'
```

> Debian cloud image mặc định thường dùng user `debian`, không có mật khẩu — chỉ dùng SSH key.

---

Nếu bạn chưa có keypair sẵn, cần tạo lại, hoặc chưa có network phù hợp, mình có thể hướng dẫn thêm phần đó. Bạn muốn
mình hỗ trợ thêm phần nào không?
