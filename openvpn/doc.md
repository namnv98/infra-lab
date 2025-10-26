### 2. 🌐 Kiểm tra IP public sau khi kết nối:

Chạy:

```bash
curl ifconfig.me
```

→ Phải trả về IP public của server OpenVPN (34.124.241.221 nếu đúng)

### 3. 🕵️ Nếu không truy cập được internet:

* Kiểm tra server đã bật NAT:

  ```bash
  sudo iptables -t nat -L -n -v
  ```

* Đảm bảo rule như sau:

  ```bash
  -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
  ```

* Nếu chưa có thì thêm bằng Ansible hoặc lệnh thủ công:

  ```bash
  sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
  ```

---

```shell

sudo iptables -t nat -L -n -v
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         
    0     0 MASQUERADE  0    --  *      eth0    10.8.0.0             0.0.0.0/0           
    0     0 MASQUERADE  0    --  *      eth0    10.8.0.0/24          0.0.0.0/0    

```

Bạn **đã có rule MASQUERADE**, nhưng chưa hoạt động — bằng chứng là:

```
    0     0 MASQUERADE  ...  source 10.8.0.0/24
```

→ `pkts = 0`, nghĩa là chưa có gói nào được NAT qua. Dưới đây là các bước kiểm tra và khắc phục.

---

## ✅ Kiểm tra hệ thống và sửa lỗi NAT nếu cần

---

### 1. 🔥 Bật IP forwarding (cực kỳ quan trọng)

Chạy:

```bash
sudo sysctl net.ipv4.ip_forward
```

Nếu trả về:

```
net.ipv4.ip_forward = 0
```

→ Phải bật lên:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

Để bật vĩnh viễn:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

### 2. 🔌 Kiểm tra đúng interface

Hiện tại bạn dùng rule:

```
MASQUERADE -o eth0
```

→ Kiểm tra interface thật đang ra internet:

```bash
ip route get 8.8.8.8
```

Ví dụ kết quả:

```
8.8.8.8 via 10.148.0.1 dev ens4 src 10.148.0.14
```

→ Interface thực là `ens4`, không phải `eth0`.

Vì vậy bạn phải sửa iptables lại:

```bash
sudo iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens4 -j MASQUERADE
```

```
2. Xóa rule sai eth0 (nếu chưa xóa)
sudo iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
3. Thêm rule đúng ens4
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ens4 -j MASQUERADE

```

---

### 3. 💾 Lưu lại iptables nếu cần

* Trên Ubuntu:

```bash
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

---

### 4. 🧪 Thử lại từ client

* Ngắt kết nối VPN trên client
* Kết nối lại
* Kiểm tra:

```bash
curl ifconfig.me
```

→ Phải ra IP của máy chủ VPN

---

### ✅ Tổng kết:

| Kiểm tra            | Lệnh                                                                     |
|---------------------|--------------------------------------------------------------------------|
| IP forwarding       | `sysctl net.ipv4.ip_forward`                                             |
| Interface ra ngoài  | `ip route get 8.8.8.8`                                                   |
| Fix iptables        | `iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o <iface> -j MASQUERADE` |
| Kiểm tra lại client | `curl ifconfig.me`                                                       |




sudo iptables -t nat -L POSTROUTING --line-numbers -n -v