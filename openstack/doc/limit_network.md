# 📘 Hướng dẫn giới hạn băng thông VM trong OpenStack (QoS)

## 🎯 Mục tiêu

Giới hạn băng thông **egress (từ VM ra ngoài)** xuống còn **1 Mbps** bằng cách sử dụng tính năng **Quality of Service (
QoS)** của Neutron trong DevStack.

---

## 🧩 Bước 1. Chuyển sang user `stack`

Hầu hết thao tác DevStack cần chạy với user `stack`:

```bash
sudo -iu stack
```

---

## 🧩 Bước 2. Nạp biến môi trường OpenStack

Để sử dụng CLI `openstack`, cần load file `openrc`:

```bash
source ~/devstack/openrc admin demo
```

---

## 🧩 Bước 3. Tạo QoS Policy

Tạo một policy có tên `limit-bw`:

```bash
openstack network qos policy create limit-bw
```

> Policy là “container” chứa các rule QoS (ví dụ: giới hạn băng thông, packet rate, DSCP…).

---

## 🧩 Bước 4. Tạo rule giới hạn băng thông

Thêm rule **bandwidth limit** vào policy vừa tạo:

```bash
openstack network qos rule create \
  --type bandwidth-limit \
  --max-kbps 1024 \
  --max-burst-kbits 1000 \
  limit-bw
```

📖 **Giải thích tham số:**

* `--type bandwidth-limit`: kiểu rule là giới hạn băng thông.
* `--max-kbps 1024`: tốc độ tối đa 1024 kilobit/s ≈ 1 Mbps.
* `--max-burst-kbits 1000`: cho phép “burst” tối đa 1 Mb trước khi giới hạn.
* `limit-bw`: tên policy đã tạo ở bước 3.

---

## 🧩 Bước 5. Lấy port ID của VM

Mỗi VM trong OpenStack có ít nhất một port (card mạng).
Lấy danh sách port của VM:

```bash
openstack port list --server <vm_name>
```

Ghi lại giá trị của `ID` — đó là `port_id` bạn cần.

---

## 🧩 Bước 6. Gắn QoS Policy vào port của VM

```bash
openstack port set --qos-policy limit-bw <port_id>
```

> Khi policy được gắn, rule giới hạn băng thông sẽ bắt đầu có hiệu lực trên port đó.

---

## 🧩 Bước 7. Kiểm tra lại cấu hình QoS của port

```bash
openstack port show <port_id> -f yaml | grep qos
```

Kết quả mong đợi:

```
qos_policy_id: 2b0f7a76-93df-4d9a-a771-fb3f9a0c3d8d
qos_network_policy_id: null
```

---

# 🧮 Kiểm tra giới hạn băng thông bằng iperf3

## 🧩 Bước 1. Trong host DevStack, bật iperf3 server

```bash
iperf3 -s
```

> Host DevStack sẽ lắng nghe ở cổng 5201.

---

## 🧩 Bước 2. Trong VM (ví dụ IP: `10.0.0.58`), chạy iperf3 client

Kết nối ngược về host để kiểm tra tốc độ **egress (từ VM ra ngoài)**:

```bash
iperf3 -c <ip_host_của_devstack>
```

---

## 📊 Kết quả mong đợi

Nếu rule hoạt động đúng, bạn sẽ thấy kết quả gần **1 Mbit/sec** (tức ~1 Mbps):

```
[ ID] Interval           Transfer     Bandwidth
[  5]   0.00-10.00  sec  1.22 MBytes  1.02 Mbits/sec  sender
[  5]   0.00-10.00  sec  1.21 MBytes  1.01 Mbits/sec  receiver
```

---

## ✅ Tóm tắt

| Bước | Lệnh chính                                           | Mục đích             |
|------|------------------------------------------------------|----------------------|
| 1    | `sudo -iu stack`                                     | Đăng nhập user stack |
| 2    | `source ~/devstack/openrc admin demo`                | Nạp biến môi trường  |
| 3    | `openstack network qos policy create limit-bw`       | Tạo policy           |
| 4    | `openstack network qos rule create ... limit-bw`     | Tạo rule giới hạn    |
| 5    | `openstack port list --server <vm_name>`             | Lấy port ID          |
| 6    | `openstack port set --qos-policy limit-bw <port_id>` | Gắn rule vào port    |
| 7    | `openstack port show <port_id>`                      | Kiểm tra policy      |
| 8    | `iperf3 -s / -c`                                     | Đo tốc độ thực tế    |

---