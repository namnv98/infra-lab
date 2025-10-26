Dưới đây là **các bước hoàn chỉnh** để giúp bạn từ Internet **truy cập được VM1** (trong DevStack, IP `172.24.4.61`)
thông qua IP public của VM GCP (`35.197.146.206`), ví dụ để SSH hoặc expose HTTP.

---

## 🧱 Kiến trúc

```
[ Bạn (laptop) ]
       ↓ (Internet)
[IP public GCP VM: 34.x.x.x]
       ↓ NAT / Port forward
[DevStack VM trên GCP] – Floating IP: 172.24.4.X (public net OpenStack)
       ↓
[Instance nội bộ OpenStack]: 192.168.X.X

```

---

## 🎯 Mục tiêu:

* Truy cập được `ssh debian@35.197.146.206`
* Gửi request đến `http://35.197.146.206:8080` sẽ tới `VM1:80`

---

## ✅ Bước 1: Đảm bảo VM1 đã gắn Floating IP

```bash
openstack server add floating ip VM1 172.24.4.61
```

Kiểm tra lại:

```bash
openstack server list
```

---

## ✅ Bước 2: Bật IP Forwarding trên GCP VM (DevStack host)

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

> Bật vĩnh viễn:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## ✅ Bước 3: Thêm rule iptables để NAT traffic

### 🔐 SSH (port 22 → 172.24.4.61:22)

```bash
sudo iptables -t nat -A PREROUTING -d 10.148.0.41 -p tcp --dport 22 -j DNAT --to-destination 172.24.4.61:22
```

### 🌐 HTTP (port 8080 → 172.24.4.61:80)

```bash
sudo iptables -t nat -A PREROUTING -d 10.148.0.41 -p tcp --dport 8080 -j DNAT --to-destination 172.24.4.61:80
```

### 🔁 Cho phép POSTROUTING

```bash
sudo iptables -t nat -A POSTROUTING -s 172.24.4.0/24 -j MASQUERADE
```

### ✅ FORWARD traffic đến VM1

```bash
sudo iptables -A FORWARD -p tcp -d 172.24.4.61 --dport 22 -j ACCEPT
sudo iptables -A FORWARD -p tcp -d 172.24.4.61 --dport 80 -j ACCEPT
```

---

## ✅ Bước 4: Cấu hình tường lửa GCP (nếu có)

Truy cập **GCP Console → VPC → Firewall rules**, tạo rule:

| Field           | Value                |
|-----------------|----------------------|
| Name            | `allow-devstack-ssh` |
| Direction       | Ingress              |
| Target          | GCP VM (DevStack)    |
| Source IP       | `0.0.0.0/0`          |
| Protocols/Ports | TCP: `22`, `8080`    |

---

## ✅ Bước 5: SSH vào VM1 từ bên ngoài

```bash
ssh -i mykey.pem debian@35.197.146.206
```

> Nếu chưa được: Kiểm tra `cloud-init` trong VM1 có inject đúng SSH key chưa.

---

## 🧪 Kiểm tra HTTP:

Chạy trong VM1:

```bash
sudo apt update && sudo apt install -y nginx
```

Truy cập từ laptop:

```
http://35.197.146.206:8080
```

---

## 📌 Ghi chú:

* Bạn có thể thêm rule `iptables` cho nhiều port/VM khác nhau tương tự.
* Để **lưu iptables vĩnh viễn**, cài `iptables-persistent`:

```bash
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

---

Nếu bạn cần mình viết **script shell tự động** tất cả bước trên, hoặc cấu hình cho nhiều VM (VM2, VM3...), chỉ cần nói
nhé.
