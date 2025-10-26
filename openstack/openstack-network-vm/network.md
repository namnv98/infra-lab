```
                                             +-------------------+
                                             |     Internet      |
                                             +-------------------+
                                                     |
                                                     |
                                   (Floating IP: 172.24.4.100 / 172.24.4.101)
                                                     |
                                       +------------------------------+
                                       | External Network: `public`   |
                                       | Subnet: `public-subnet`     |
                                       | CIDR: 172.24.4.0/24          |
                                       | Gateway: 172.24.4.1          |
                                       | Type: flat, external=True    |
                                       +------------------------------+
                                                     |
                                                     | (external-gateway)
                          +------------------------------------------------------+
                          |   Router: `my-router`                                |
                          | - Project: myproject                                 |
                          | - Has gateway to `public`                            |
                          | - Connected to 2 subnets:                            |
                          |   + `my-subnet-a`,                                   |
                          |   + `my-subnet-b`                                    |
                          | - NAT tại đây (DNAT + SNAT):                         |
                          |   + DNAT: 172.24.4.x → 10.10.x.x (từ internet vào VM)|
                          |   + SNAT: 10.10.x.x → 172.24.4.1 (ra Internet)       |
                          +------------------------------------------------------+
                                        /                         \
                                       /                           \
                                      /                             \
          +----------------------------------+     +----------------------------------+
          | Internal Network A: `my-net-a`   |     | Internal Network B: `my-net-b`   |
          | Subnet: `my-subnet-a`            |     | Subnet: `my-subnet-b`            |
          | CIDR: 10.10.10.0/24              |     | CIDR: 10.10.20.0/24              |
          | DNS: 8.8.8.8                     |     | DNS: 8.8.8.8                     |
          +----------------------------------+     +----------------------------------+
                      |                                        |
               +-------------+                          +-------------+
               |   VM-A1     |                          |   VM-B1     |
               |  Name: vm-a1|                          |  Name: vm-b1|
               |  Fixed IP:  |                          |  Fixed IP:  |
               | 10.10.10.10 |                          | 10.10.20.10 |
               | Floating IP:|                          | Floating IP:|
               | 172.24.4.100|                          | 172.24.4.101|
               +-------------+                          +-------------+

```

## 🧩 **Giải thích các thành phần**

| Thành phần       | Mô tả                                                                |
|------------------|----------------------------------------------------------------------|
| `myproject`      | Project chứa toàn bộ tài nguyên mạng và VM                           |
| `public`         | External network DevStack tạo sẵn, dùng để cấp Floating IP           |
| `my-router`      | Router kết nối mạng nội bộ với external, bật SNAT/NAT mặc định       |
| `my-net-a/b`     | Internal networks do user tự tạo (tenant network)                    |
| `my-subnet-a/b`  | Subnet ứng với mỗi network, cấp IP động qua DHCP                     |
| `VM-A1/B1`       | VM trong mỗi subnet, có IP nội bộ + Floating IP để truy cập từ ngoài |
| `Floating IP`    | IP public để NAT vào VM                                              |
| `Security Group` | Phải mở ICMP, SSH nếu muốn ping/ssh từ bên ngoài                     |

### 🧠 NAT là gì?

**NAT (Network Address Translation)** là cơ chế dịch địa chỉ mạng — cho phép **nhiều thiết bị trong mạng nội bộ (private
IP)** truy cập ra Internet bằng **một địa chỉ IP công cộng duy nhất**.

---

### 🔁 Cách hoạt động (đơn giản hóa):

| Thiết bị | IP nội bộ   | Gửi ra Internet qua | IP công cộng |
|----------|-------------|---------------------|--------------|
| VM-A     | 10.10.10.10 | NAT (router)        | 172.24.4.1   |
| VM-B     | 10.10.20.10 | NAT (router)        | 172.24.4.1   |

> Khi gói tin từ VM có IP nội bộ đi ra ngoài, router sẽ **"dịch" IP nguồn** thành IP public (`172.24.4.1`), và khi nhận
> gói tin phản hồi, nó sẽ **dịch ngược lại**.

---

### 🧰 Trong OpenStack

Trong OpenStack, khi bạn gắn `--external-gateway` cho router như sau:

```bash
openstack router set my-router --external-gateway public
```

thì Neutron sẽ bật **SNAT** (Source NAT) cho router đó.

---

### 📦 Có mấy kiểu NAT?

| Kiểu NAT       | Mô tả                                                                  |
|----------------|------------------------------------------------------------------------|
| **SNAT**       | Dùng khi nhiều máy trong mạng nội bộ cùng ra ngoài qua 1 IP            |
| **DNAT**       | Dùng khi có kết nối từ bên ngoài vào (qua Floating IP → nội bộ)        |
| **PAT (NAPT)** | Nhiều IP/port nội bộ chia sẻ 1 IP công cộng (Port Address Translation) |

Trong OpenStack:

* **SNAT** dùng khi bạn không gán Floating IP nhưng muốn VM có thể truy cập Internet.
* **DNAT** xảy ra khi bạn gán Floating IP để truy cập ngược lại vào VM từ bên ngoài.

---

### 🔐 Ví dụ:

Bạn có VM `10.10.10.10`, không có Floating IP, nhưng router `my-router` có gắn external gateway.

```bash
ping 8.8.8.8
```

→ Router sẽ **NAT IP 10.10.10.10 → 172.24.4.1** → Internet, và **dịch ngược lại** khi phản hồi về.

---

### ✅ Tổng kết

| Tính năng               | Có trong OpenStack? | Khi nào dùng?                                  |
|-------------------------|---------------------|------------------------------------------------|
| SNAT                    | ✅                   | VM không có Floating IP nhưng muốn ra Internet |
| DNAT (qua Floating IP)  | ✅                   | Khi muốn SSH/ping vào VM từ bên ngoài          |
| NAT cần router external | ✅                   | Phải gán gateway tới external network          |

---

### 📚 **Khái niệm NAT trong mạng – Gọi chung**

---

## 🔁 NAT là gì?

**NAT (Network Address Translation)** là một kỹ thuật được sử dụng trong mạng máy tính để **dịch địa chỉ IP** giữa:

* **Mạng nội bộ (private IP)** ➜ **Mạng bên ngoài (public IP)**
* Giúp **nhiều thiết bị** trong mạng nội bộ có thể chia sẻ **một địa chỉ IP công cộng duy nhất** khi truy cập Internet.

---

## 🎯 Mục đích chính của NAT

| Mục đích                     | Mô tả ngắn gọn                                                      |
|------------------------------|---------------------------------------------------------------------|
| **Tiết kiệm IP public**      | Không cần cấp IP công cộng cho từng thiết bị nội bộ                 |
| **Tăng tính bảo mật**        | Thiết bị nội bộ không lộ trực tiếp ra Internet                      |
| **Cho phép Internet access** | Máy trong mạng private vẫn ra Internet mà không cần IP public riêng |

---

## 🔍 Các kiểu NAT phổ biến

| Loại NAT       | Viết tắt   | Mô tả hoạt động chính                                                |
|----------------|------------|----------------------------------------------------------------------|
| **SNAT**       | Source NAT | Dịch địa chỉ IP nguồn khi **gửi gói đi ra ngoài** (private → public) |
| **DNAT**       | Dest. NAT  | Dịch địa chỉ IP đích khi **gói từ ngoài vào** (public → private)     |
| **PAT / NAPT** | Port-based | Dùng chung 1 IP public với nhiều port khác nhau cho các máy nội bộ   |

---

## 💡 Ví dụ minh họa NAT đơn giản

| Máy nội bộ   | IP nội bộ    | Gửi tới Internet | NAT  | Internet thấy là |
|--------------|--------------|------------------|------|------------------|
| Laptop       | 192.168.1.10 | google.com       | SNAT | 203.0.113.100    |
| Server       | 192.168.1.20 | ping 8.8.8.8     | SNAT | 203.0.113.100    |
| User outside | ?            | 203.0.113.100    | DNAT | 192.168.1.10     |

---

## 🛠 NAT được dùng ở đâu?

| Môi trường           | NAT dùng làm gì                                  |
|----------------------|--------------------------------------------------|
| ✅ **OpenStack**      | DNAT: Floating IP vào VM<br>SNAT: VM ra Internet |
| ✅ **Router Wi-Fi**   | SNAT: Thiết bị trong nhà ra ngoài qua 1 IP       |
| ✅ **Firewall**       | Dịch IP khi điều hướng gói tin                   |
| ✅ **Cloud Provider** | AWS, Azure, GCP đều dùng NAT Gateway             |

---

## 🧠 Tổng kết nhanh

* NAT là **kỹ thuật dịch địa chỉ IP**
* Cho phép **private IP giao tiếp với Internet**
* Có 2 hướng chính:

    * **SNAT**: Gói tin **đi ra ngoài**
    * **DNAT**: Gói tin **đi vào hệ thống**

---

