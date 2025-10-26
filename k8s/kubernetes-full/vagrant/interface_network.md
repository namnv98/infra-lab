---

# Tài liệu Chi Tiết: Interface Mạng và Cách Cấp Phát IP (Static & DHCP) + Sơ Đồ Minh Họa

---

## 1. Interface Mạng là gì?

* **Interface mạng** là cổng kết nối mạng trên máy tính hoặc thiết bị mạng, có thể là:

    * **Vật lý:** card mạng Ethernet (LAN), card Wi-Fi.
    * **Ảo:** interface mạng ảo do phần mềm tạo (ví dụ: enp0s8, eth0, wlan0, docker0...).

* Mỗi interface là điểm đầu cuối để máy tính giao tiếp với mạng khác, được gán địa chỉ IP để định danh trên mạng.

* **Tên interface** thường theo chuẩn hệ điều hành (Linux phổ biến là `enp0s8`, `eth0`, `wlan0`, Windows thì `Ethernet`,
  `Wi-Fi`...).

---

## 2. IP là gì?

* **Địa chỉ IP (Internet Protocol Address)** là số định danh duy nhất cho mỗi interface trong mạng.
* IP dùng để gửi nhận dữ liệu qua mạng.
* Có 2 loại IP phổ biến dùng trong LAN hoặc Internet: **IPv4** (ví dụ 192.168.1.10) và **IPv6** (ví dụ fe80::1).

---

## 3. IP tĩnh (Static IP) và IP động (DHCP)

### 3.1. IP tĩnh (Static IP)

* Là IP được **cấu hình thủ công cố định** cho interface.
* Không thay đổi nếu không chỉnh sửa.
* Thường dùng cho server, thiết bị mạng cần IP cố định như: máy chủ web, router, camera, máy chủ Kubernetes master...
* Ưu điểm:

    * Đảm bảo IP không đổi, dễ quản lý và cấu hình dịch vụ.
* Nhược điểm:

    * Cần phải quản lý tránh xung đột IP thủ công.
    * Không linh hoạt khi thay đổi mạng.

### 3.2. IP động (DHCP - Dynamic Host Configuration Protocol)

* Là IP được **cấp tự động** qua DHCP server khi interface yêu cầu.
* DHCP server quản lý dải IP và cấp phát cho các thiết bị trong mạng.
* Thường dùng cho máy tính cá nhân, laptop, điện thoại.
* Ưu điểm:

    * Tự động, linh hoạt, tiết kiệm công sức quản lý.
    * Giảm xung đột IP.
* Nhược điểm:

    * IP có thể thay đổi theo thời gian (trừ khi DHCP server giữ lại IP cho MAC address cố định).

---

## 4. Ai cấp IP cho interface?

| Loại IP        | Ai cấp IP?                     | Cách cấp phát                         |
|----------------|--------------------------------|---------------------------------------|
| IP tĩnh        | Người quản trị hoặc người dùng | Cấu hình thủ công trên OS             |
| IP động (DHCP) | DHCP server trong mạng         | DHCP server cấp phát khi nhận yêu cầu |

* **Lưu ý:** Máy tính phải kết nối mạng (vật lý hoặc ảo) mới có thể nhận IP.

---

## 5. Quá trình cấp phát IP

### 5.1. IP tĩnh

* Khi interface bật, hệ điều hành đọc file cấu hình (vd: `/etc/systemd/network/10-enp0s8.network`).
* Gán IP tĩnh, Gateway, DNS cho interface.
* Không gửi yêu cầu DHCP.

### 5.2. IP động (DHCP)

* Khi interface bật, gửi yêu cầu DHCPDISCOVER (Broadcast).
* DHCP server nhận yêu cầu, chọn IP phù hợp.
* Gửi lại DHCPOFFER cho client.
* Client chấp nhận (DHCPREQUEST).
* DHCP server xác nhận (DHCPACK).
* Client gán IP được cấp và các thông số khác.

---

## 6. Interface có thể có nhiều IP được không?

* Có thể, 1 interface có thể cấu hình nhiều IP (IPv4 hoặc IPv6).
* Nhưng **trong cùng mạng con (subnet)** không được trùng IP giữa các interface khác nhau để tránh xung đột.

---

## 7. Máy tính có thể có nhiều interface mạng không?

* Có thể, nhiều interface để kết nối nhiều mạng khác nhau.
* Ví dụ: máy có `eth0` kết nối mạng LAN nội bộ, `wlan0` kết nối Wi-Fi khác.

---

## 8. Xung đột IP xảy ra khi nào?

* Khi 2 hoặc nhiều interface khác nhau **cùng dùng chung IP trong cùng mạng con**, sẽ gây ra lỗi giao tiếp, mất kết nối,
  lỗi ARP.

---

## 9. Ví dụ cấu hình IP tĩnh bằng systemd-networkd trên Debian

Giả sử interface thứ 2 của máy là `enp0s8`, bạn muốn cấu hình IP tĩnh 192.168.56.10/24:

```bash
mkdir -p /etc/systemd/network

cat <<EOF > /etc/systemd/network/10-enp0s8.network
[Match]
Name=enp0s8

[Network]
Address=192.168.56.10/24
Gateway=192.168.56.1
DNS=8.8.8.8
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd
```

---

## 10. Ví dụ file cấu hình IP động (DHCP) cho interface `enp0s8`

```bash
cat <<EOF > /etc/systemd/network/10-enp0s8.network
[Match]
Name=enp0s8

[Network]
DHCP=yes
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd
```

---

## 11. Sơ đồ minh họa

```plaintext
+-----------------------+
|       Máy tính         |
| +-------------------+ |
| |    Interface      | |       <--- Tên interface: enp0s8
| |    (Card Mạng)    | |
| +-------------------+ |
+-----------|-----------+
            |
            | 1. Cấu hình IP tĩnh: IP cố định gán trực tiếp
            |
            | 2. Cấu hình IP động:
            |    - Gửi yêu cầu DHCP (Broadcast)
            |    - Nhận IP và config
            |
+-----------v-----------+
|       Mạng LAN        |
| +-------------------+ |
| |   DHCP Server     | |    <--- Cấp IP động khi có yêu cầu
| +-------------------+ |
|                       |
| +-------------------+ |
| |   Router/Gateway  | |    <--- Cấp Gateway (địa chỉ để ra ngoài Internet)
| +-------------------+ |
+-----------------------+

```

---

## 12. Tóm tắt quan trọng

| Thuộc tính  | IP tĩnh                     | IP động (DHCP)          |
|-------------|-----------------------------|-------------------------|
| Gán IP      | Thủ công                    | Tự động bởi DHCP server |
| Thay đổi IP | Không thay đổi              | Có thể thay đổi         |
| Quản lý     | Quản trị viên quản lý       | Tự động, ít cần quản lý |
| Phù hợp với | Server, thiết bị quan trọng | Thiết bị client, laptop |
| Xung đột IP | Phải kiểm soát tránh        | DHCP server tránh giúp  |

---