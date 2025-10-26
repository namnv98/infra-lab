Sau khi bạn đã **gán Floating IP** thành công cho VM, để SSH vào VM, cần đảm bảo đủ 3 điều kiện sau:

---

## ✅ Điều kiện để SSH được vào VM Cirros:

| Điều kiện                              | Kiểm tra                                                                   |
| -------------------------------------- | -------------------------------------------------------------------------- |
| 1. **VM có Floating IP**               | `openstack server show <vm-name>` → field `addresses` có IP `172.24.4.xxx` |
| 2. **Mở port 22 trong Security Group** | `openstack security group rule list`                                       |
| 3. **Có keypair & biết user/password** | Cirros dùng `cirros/gocubsgo`, nếu không có keypair                        |

---

## 👨‍💻 1. Xác định IP Floating VM

```bash
openstack server show my-vm -f value -c addresses
```

Ví dụ: `my-net=10.10.0.10, 172.24.4.140`

---

## 🧱 2. Mở port SSH (nếu chưa)

```bash
openstack security group rule create --proto tcp --dst-port 22 default
```

---

## 🔐 3. SSH vào Cirros

### Nếu **không dùng keypair** (Cirros image mặc định)

Cirros dùng user/pass:

```bash
ssh cirros@172.24.4.140
# password: gocubsgo
```

> Lưu ý: Có thể phải chạy `ssh -o StrictHostKeyChecking=no`

---

### Nếu dùng image Ubuntu hoặc CentOS

* Bạn cần chỉ định keypair khi tạo VM:

```bash
--key-name mykey
```

* Và SSH:

```bash
ssh -i mykey.pem ubuntu@<floating-ip>
# hoặc: centos@... hay cloud-user@... tùy distro
```

---

## ❗ Nếu vẫn không SSH được:

Bạn hãy kiểm tra từ máy DevStack host:

```bash
ping 172.24.4.140
nc -zv 172.24.4.140 22
```

---

## 📌 Gợi ý kiểm tra nhanh

1. Floating IP được gán chưa?

```bash
openstack server show my-vm -f value -c addresses
```

2. Có port 22 mở chưa?

```bash
openstack security group rule list --long
```

3. Có ssh được từ DevStack host chưa?

```bash
ssh cirros@172.24.4.140
```

---

Bạn gửi mình:

```bash
openstack server show <vm-name>
```

và nội dung lỗi SSH nếu có, mình sẽ giúp bạn xử lý chính xác.
