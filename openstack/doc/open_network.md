
---

## 🎯 Mục tiêu:

Tạo được 1 hệ thống mạng riêng cho `myproject`, có thể gán Floating IP cho VM của project này.

---

## ✅ Quy trình chuẩn từ đầu (toàn bộ dùng `myproject`):

### 👉 Bước 0: `source` đúng credentials

```bash
source /opt/stack/devstack/openrc admin my-project
```

> Nếu user tên khác (`demo`, `user1`,...) thì thay bằng đúng user của bạn.

---

### 👉 Bước 1: Tạo network & subnet mới cho project `myproject`

```bash
openstack network create my-net
openstack subnet create --network my-net \
  --subnet-range 10.10.0.0/24 \
  --dns-nameserver 8.8.8.8 \
  my-subnet
```

⚠️ my-net là mạng nội bộ (private), public là mạng external do DevStack tạo sẵn để ra Internet/gán Floating IP.

---

### 👉 Bước 2: Tạo router trong project `myproject`

```bash
openstack router create my-router
openstack router set my-router --external-gateway public
openstack router add subnet my-router my-subnet
```

---

### 👉 Bước 3: Tạo VM trong `my-net`

Ví dụ:

```bash
openstack server create \
  --flavor m1.tiny \
  --image cirros-0.6.3-x86_64-disk \
  --nic net-id=$(openstack network show -f value -c id my-net) \
  --key-name mykey \
  my-vm
```

---

### 👉 Bước 4: Gán Floating IP

```bash
openstack floating ip create public
```

Ví dụ kết quả:

```text
+---------------------+---------------+
| Field               | Value         |
+---------------------+---------------+
| floating_ip_address | 172.24.4.140  |
+---------------------+---------------+
```

Gán IP vào VM:

```bash
openstack server add floating ip my-vm 172.24.4.140
```

---

### 👉 Bước 5: Mở security group để cho SSH/ping

```bash
openstack security group rule create --proto icmp default
openstack security group rule create --proto tcp --dst-port 22 default
```

---

## ✅ Tổng kết nhanh

| Tài nguyên                        | Thuộc project `myproject`    |
| --------------------------------- | ---------------------------- |
| Network `my-net`                  | ✅                            |
| Subnet `my-subnet` (10.10.0.0/24) | ✅                            |
| Router `my-router`                | ✅                            |
| VM `my-vm`                        | ✅                            |
| Floating IP                       | ✅                            |
| Kết nối router đến `public`       | ✅ (qua `--external-gateway`) |


---


openstack server show vm-from-api -f value -c addresses  
{'my-net': ['10.10.0.58', '172.24.4.150']}  

ssh cirros@172.24.4.150  

gocubsgo  


