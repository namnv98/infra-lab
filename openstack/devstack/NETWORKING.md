# Mạng trong OpenStack (Neutron) — hiểu qua chính lab này

Tài liệu này giải thích các khái niệm mạng mà ops OpenStack cần nắm, dùng **chính
lab DevStack bạn đang chạy** làm ví dụ — mọi lệnh/giá trị trong bài đều tra được
thật trên VM của bạn, không phải lý thuyết suông.

## 0. Mạng máy tính cơ bản — giải thích từ đầu

Phần này dành cho ai **chưa biết gì** về mạng — không cần kiến thức gì trước
khi đọc. Đọc xong phần này rồi vào phần 1 sẽ dễ hơn nhiều.

### 0.0. "Mạng" thực chất là gì?

2 máy tính muốn nói chuyện với nhau, cần 2 thứ:

1. **Đường truyền vật lý** — dây cáp, sóng Wi-Fi, hoặc cáp quang. Đây là "con
   đường" gói tin đi qua, không khác gì đường nhựa cho xe chạy.
2. **Một "ngôn ngữ" chung** — luật lệ 2 bên đồng ý để hiểu nhau. Gọi là
   **protocol** (giao thức). Ví dụ: TCP/IP là bộ giao thức phổ biến nhất,
   giống như "tiếng Anh" là ngôn ngữ chung để người khắp thế giới giao tiếp.

Dữ liệu không gửi nguyên khối — nó bị chia nhỏ thành từng **gói tin (packet)**,
mỗi gói có 2 phần:

```
┌─────────────────────────────┬──────────────────┐
│ HEADER (tiêu đề)             │ DATA (dữ liệu)    │
│ - IP nguồn, IP đích           │  phần nội dung    │
│ - port nguồn, port đích       │  thật muốn gửi    │
└─────────────────────────────┴──────────────────┘
```

Giống 1 bức thư: **HEADER** = thông tin ghi ngoài bì thư (địa chỉ người gửi,
người nhận), **DATA** = nội dung thư bên trong. Mọi thiết bị mạng (switch,
router, firewall) chỉ **đọc phần HEADER** để quyết định chuyển gói đi đâu —
không cần (và thường không được) đọc phần DATA bên trong.

### 0.1. Địa chỉ IP — "địa chỉ nhà" của máy tính

Muốn gửi thư, cần địa chỉ nhà. Muốn máy tính gửi dữ liệu cho nhau, cần **địa
chỉ IP**. Ví dụ: `192.168.1.10`. Nó gồm 4 số (0-255), gọi là 4 "octet".

Không có địa chỉ IP, máy tính không biết gửi gói tin đi đâu — giống thư không
ghi địa chỉ, bưu điện không biết giao đâu.

### 0.2. Subnet/CIDR — "khu phố" chứa các địa chỉ

Các nhà trong 1 con phố thường được đánh số liên tiếp (số 1 đến số 50 là phố
A, số 51 đến 100 là phố B...). Mạng máy tính cũng vậy — chia thành từng "khu",
gọi là **subnet**.

`192.168.1.0/24` nghĩa là: khu này gồm mọi IP có 3 số đầu là `192.168.1`, số
cuối (0-255) là "số nhà" trong khu — vậy khu này có 256 địa chỉ
(`192.168.1.0` → `192.168.1.255`). Số `/24` gọi là **prefix length**: nó nói
"24 bit đầu tiên (3 số đầu) là cố định, dùng để định danh khu; phần còn lại là
số nhà". `/24` = khu 256 nhà, `/16` = khu 65536 nhà (lớn hơn), `/28` = khu 16
nhà (nhỏ hơn). Công thức chung: prefix `/n` có `2^(32-n)` địa chỉ.

**Lưu ý quan trọng:** trong 256 địa chỉ đó, **2 địa chỉ đầu và cuối không gán
được cho máy nào** — `192.168.1.0` (địa chỉ đại diện cho cả khu, gọi là
*network address*) và `192.168.1.255` (địa chỉ gửi broadcast cho mọi máy trong
khu, gọi là *broadcast address*). Vậy `/24` chỉ dùng được thực tế 254 địa chỉ.
Đây chính là lý do khi cấu hình allocation pool trong lab, bạn phải né cả 2
đầu dải, không phải chỉ né IP gateway (xem lỗi `end < start` bạn từng gặp khi
gateway rơi đúng đầu dải).

Hai máy trong **cùng 1 subnet** nói chuyện trực tiếp được với nhau (như 2 nhà
cùng phố, đi bộ qua nhà nhau). Hai máy ở **2 subnet khác nhau** phải qua
**router** (giống muốn qua phố khác phải ra đường lớn, qua ngã tư).

**Subnet mask — cách viết khác của cùng 1 thứ.** Bạn sẽ thấy 2 cách viết cho
cùng 1 khái niệm: `/24` (CIDR, hay gặp trong OpenStack/Linux) và
`255.255.255.0` (subnet mask, hay gặp trên Windows/router gia đình) — cả 2
đều nói "24 bit đầu cố định". Cách suy ra mask từ prefix: viết `n` bit `1`
liền nhau rồi phần còn lại là `0`, chia thành 4 nhóm 8 bit, đổi mỗi nhóm ra
số thập phân:

```
/24  = 11111111.11111111.11111111.00000000  = 255.255.255.0
/26  = 11111111.11111111.11111111.11000000  = 255.255.255.192
/16  = 11111111.11111111.00000000.00000000  = 255.255.0.0
```

Máy tính dùng mask để tự trả lời câu hỏi "IP đích có cùng subnet với tôi
không?" bằng 1 phép tính nhị phân (AND) giữa IP của nó và mask, so với kết
quả AND của IP đích và mask — giống nhau thì cùng subnet. Bạn không cần tự
tính tay, chỉ cần hiểu: **mask/prefix quyết định "cùng khu" hay "khác khu"**,
và đây chính là con số máy tính dùng để tự quyết định gửi trực tiếp (switch)
hay gửi cho gateway (router) — xem tiếp mục 0.3 và 0.5.

**Vì sao phải chia subnet, không dùng chung 1 mạng khổng lồ?** 2 lý do chính:
1. **Giới hạn broadcast** — 1 số loại gói tin (như ARP hỏi "IP này của ai")
   gửi tới **mọi máy** trong subnet cùng lúc, gọi là *broadcast*. Subnet càng
   lớn, broadcast càng tốn băng thông, mọi máy đều phải xử lý. Chia nhỏ subnet
   giới hạn phạm vi broadcast.
2. **Tổ chức & cách ly** — nhóm các máy theo phòng ban/mục đích (mạng dev,
   mạng quản trị, mạng khách...), rồi dùng router/firewall kiểm soát ai được
   nói với ai giữa các nhóm. Đây chính là lý do lab bạn có 3 subnet riêng
   (`private`, `public`, `trove-mgmt`) chứ không dùng chung 1 subnet.

### 0.3. Gateway — "cổng ra" của 1 khu

Mỗi subnet có 1 địa chỉ đặc biệt gọi là **gateway** (hay "default gateway") —
thường là địa chỉ đầu tiên hoặc gần đó trong subnet, ví dụ `192.168.1.1`. Về
bản chất, gateway chính là **địa chỉ IP của router**, đặt trên chính subnet
đó — không có gì đặc biệt về mặt kỹ thuật khiến 1 IP "trở thành" gateway,
người quản trị chỉ đơn giản gán IP đó cho router rồi khai báo với các máy
trong subnet "gateway của các bạn là IP này".

Giống: muốn gửi thư đi tỉnh khác, bạn không tự đi giao — bạn đưa cho bưu điện
khu phố (gateway), bưu điện khu phố biết cách chuyển tiếp lên tuyến lớn hơn.

**Máy tính biết dùng gateway lúc nào nhờ đâu?** Mỗi máy có 1 **bảng định
tuyến** (routing table) nhỏ, ít nhất có 2 dòng:
```
10.0.0.0/24      → gửi trực tiếp (cùng subnet, qua switch)
0.0.0.0/0        → gửi cho gateway 10.0.0.1   (default route — "mọi IP khác")
```
`0.0.0.0/0` gọi là **default route** — nghĩa là "tôi không biết đường tới IP
này, cứ đưa cho gateway, gateway lo". Đây là dòng luôn được dùng khi đích
không khớp bất kỳ subnet nào máy biết trực tiếp. Xem bảng này bằng lệnh
`ip route` (Linux, đúng lệnh bạn đã chạy trong lab) hoặc `route print`
(Windows).

**Chưa cấu hình gateway thì sao?** Máy vẫn nói chuyện tốt với các máy **cùng
subnet**, nhưng gửi gói cho bất kỳ IP ngoài subnet đều thất bại — không phải
lỗi tường lửa, mà đơn giản máy không biết phải "đưa gói cho ai" để đi tiếp.
Đây là 1 trong những nguyên nhân phổ biến nhất của lỗi "VM tạo ra không có
Internet" — đúng loại lỗi bạn đã gặp và tự sửa với mạng `trove-mgmt` trong
lab (mạng đó DevStack tạo ra không có gateway, phải tự gán IP của VM host làm
gateway).

### 0.4. Địa chỉ MAC — "số khung máy", cố định trong lúc chạy

Mỗi card mạng (NIC) có **1 địa chỉ MAC**, dạng `52:54:00:b7:9e:5d` — dùng để
định danh duy nhất trong mạng, không đổi trong lúc máy đang chạy (khác IP, IP
có thể đổi mỗi lần cắm mạng khác). Giống **số khung xe** — cố định, gắn với
chính chiếc xe, khác với biển số (IP) có thể đổi theo nơi đăng ký.

Với NIC vật lý thật, MAC do nhà sản xuất in cứng (mỗi hãng được cấp riêng 1
dải MAC, gọi là OUI). Với NIC **ảo** — chính là card mạng của các VM trong lab
bạn — MAC do **hypervisor tự sinh** lúc tạo VM, không phải "hãng sản xuất" nào
cả. Bằng chứng ngay trong lab: MAC `52:54:00:...` bạn thấy ở output
`virsh domifaddr` luôn bắt đầu bằng `52:54:00` — đây là dải MAC riêng mà
QEMU/KVM tự dùng cho VM ảo, không phải MAC "thật" gắn cứng vào phần cứng nào.

Trong cùng 1 subnet, máy tính tìm nhau bằng MAC address (qua giao thức ARP:
"IP này của ai, cho tôi biết MAC address"), không phải bằng IP trực tiếp — IP
chỉ dùng để quyết định "gói này đi trong subnet hay phải qua router", còn khi
đã xác định đích, việc chuyển gói vật lý trong subnet dựa vào MAC.

### 0.5. Router vs Switch — 2 thiết bị hay bị nhầm

- **Switch**: nối các máy **trong cùng 1 subnet**. Chỉ nhìn vào MAC address,
  không quan tâm IP. Dân kỹ thuật gọi đây là hoạt động ở **Layer 2** (tầng
  liên kết dữ liệu, trong 7 tầng OSI — không cần nhớ hết 7 tầng, chỉ cần nhớ
  Layer 2 = MAC, Layer 3 = IP là đủ dùng cho tài liệu này).
- **Router**: nối **2 subnet khác nhau** lại, quyết định gói tin đi từ subnet
  này sang subnet kia bằng cách nào. Nhìn vào IP để quyết định đường đi — hoạt
  động ở **Layer 3**.

**Switch học đường đi bằng cách nào?** Switch giữ 1 bảng gọi là *MAC address
table* (hay CAM table), ghi nhớ "MAC này nằm sau cổng (port) nào". Lần đầu
nhận 1 frame chưa biết MAC đích, switch gửi ra **mọi cổng** (gọi là *flood*)
để dò; khi có máy trả lời, switch ghi nhớ luôn MAC nguồn + cổng vào bảng.
Những lần sau, switch chỉ gửi đúng 1 cổng cần thiết, không flood nữa. Bảng
này tự học, không cần cấu hình tay.

**Router học đường đi bằng cách nào?** Router giữ 1 bảng khác gọi là *routing
table* (đã thấy ở mục 0.3: dòng `0.0.0.0/0 → gateway`) — ghi "IP/subnet này
thì đi hướng nào". Với mạng nhỏ, bảng này thường cấu hình tay hoặc tự nhận từ
DHCP; với mạng lớn (như hạ tầng internet), router trao đổi bảng này với nhau
bằng các protocol định tuyến (OSPF, BGP...) — phần này không cần biết sâu cho
tài liệu này, chỉ cần hiểu **switch tự học, router có cả cấu hình tay và tự
động, tuỳ quy mô**.

**Broadcast domain — vì sao switch "không chặn" được gì cả.** 1 gói broadcast
(ví dụ ARP) gửi vào switch sẽ được chuyển tới **toàn bộ** máy nối cùng switch
đó (và switch khác nối tiếp theo, nếu không có VLAN chia tách — xem mục 0.14).
Router thì **chặn broadcast lại**, không cho lan qua subnet khác. Vùng mà 1
gói broadcast lan tới được gọi là **broadcast domain** — về cơ bản trùng với
định nghĩa "1 subnet". Đây là lý do subnet càng lớn thì broadcast domain càng
lớn, càng tốn tài nguyên xử lý mọi máy trong đó (đã nói ở mục 0.2).

### 0.6. Modem Wifi nhà bạn thực chất là gì?

Cái hộp bạn gọi là "modem wifi" hay "router wifi" ở nhà **không phải 1 thiết
bị đơn lẻ** — nó là 4-5 thiết bị khác nhau đóng gộp vào 1 hộp:

| Chức năng | Việc nó làm |
|---|---|
| **Modem** | Biến đổi tín hiệu từ nhà mạng (cáp quang, DSL...) thành Ethernet — đây mới là nghĩa gốc của từ "modem" (**mo**dulator-**dem**odulator) |
| **Router** | Định tuyến + NAT giữa mạng nhà bạn (private) và mạng ISP (public) — xem mục 0.7, 0.8 |
| **Switch** | Các cổng LAN (RJ45) phía sau hộp, nối máy có dây trong cùng subnet |
| **Access Point (AP)** | Phát Wi-Fi — về bản chất là 1 switch "không dây", máy nối Wi-Fi cũng vào cùng subnet với máy nối dây |
| **DHCP server** | Tự cấp IP cho máy mới nối vào (không phải bạn tự gõ IP tay cho từng laptop) |
| **DNS relay** | Nhận câu hỏi DNS từ máy trong nhà, chuyển tiếp lên DNS server thật của ISP hoặc 8.8.8.8 |

Vì mọi chức năng gộp vào 1 hộp, người dùng thường tưởng "router" và "modem"
là 1 từ đồng nghĩa — thực ra là 2 (thậm chí nhiều hơn) thiết bị hoàn toàn
khác nhau về chức năng, chỉ tình cờ nằm chung 1 vỏ nhựa. Trong data center
hay lab của bạn, các chức năng này **tách riêng hẳn**: switch vật lý riêng,
router riêng (hoặc chạy phần mềm như Neutron `router1` bạn đã tạo), DHCP là 1
service riêng (Neutron cũng tự chạy DHCP cho mỗi subnet nó tạo).

### 0.7. IP Public vs Private — vì sao nhà bạn không có "IP riêng thật"

IPv4 chỉ có khoảng 4.3 tỷ địa chỉ — không đủ cho mọi thiết bị trên Trái Đất.
Giải pháp: dành riêng vài dải IP để **dùng lại thoải mái bên trong mạng nội
bộ**, không ai được route ra internet:

```
10.0.0.0/8        (10.0.0.0 → 10.255.255.255)
172.16.0.0/12     (172.16.0.0 → 172.31.255.255)
192.168.0.0/16    (192.168.0.0 → 192.168.255.255)
```

Đây là **IP private**. Cả triệu nhà trên thế giới có thể cùng dùng
`192.168.1.10` — không xung đột, vì các mạng private này không bao giờ "gặp"
nhau trực tiếp trên internet.

**IP public** là IP thật, duy nhất trên toàn thế giới, route được từ bất kỳ
đâu tới. Nhà mạng (ISP) của bạn có 1 (hoặc vài) IP public, gán cho modem nhà
bạn — mọi thiết bị trong nhà **dùng chung** IP public đó khi ra internet.

### 0.8. NAT — "cùng dùng chung 1 IP public"

Làm sao 5 thiết bị trong nhà (IP private khác nhau) cùng ra internet qua 1 IP
public? **NAT (Network Address Translation)** — router (modem nhà bạn) làm
việc: khi laptop bạn gửi gói ra ngoài, router đổi source IP từ
`192.168.1.10` (private) thành IP public của nó, **và cũng đổi luôn source
port** thành 1 port tạm nó tự chọn (ví dụ 192.168.1.10:51000 → 203.0.113.5:
40001), ghi nhớ cặp "port 40001 này là của laptop, port gốc 51000". Khi có
gói trả về đúng port 40001, router tra lại bảng ghi nhớ, biết trả về đúng cho
laptop. Đổi cả port (không chỉ IP) là bắt buộc — vì 5 thiết bị có thể cùng
dùng trùng 1 port nguồn, chỉ dựa vào IP không đủ để phân biệt gói nào của ai.

Đây chính là NAT bạn đã tự tay cấu hình trong lab (`iptables -t nat -A
POSTROUTING ... -j MASQUERADE`) — code y hệt cơ chế modem Wi-Fi nhà bạn đang
làm mỗi ngày.

### 0.9. Port — "số phòng" trong 1 "địa chỉ nhà"

1 máy có 1 IP, nhưng chạy được nhiều dịch vụ cùng lúc (web, SSH, database...).
Làm sao gói tin biết phải đưa cho dịch vụ nào? Bằng **port** — 1 số từ
0-65535, đi kèm IP:

```
192.168.1.10:22    → SSH
192.168.1.10:80    → web (HTTP)
192.168.1.10:443   → web (HTTPS)
192.168.1.10:3306  → MySQL
```

Giống: địa chỉ nhà (IP) đưa bạn tới đúng toà nhà, số phòng (port) đưa bạn tới
đúng phòng bên trong toà nhà đó. `ssh user@192.168.1.10 -p 2222` là bạn nói rõ
"tôi muốn gõ cửa phòng 2222 của nhà này", không phải phòng 22 mặc định.

### 0.10. Client-Server — ai hỏi trước, ai trả lời

Hầu hết giao tiếp mạng theo mô hình **client-server**: 1 bên chủ động **hỏi**
(client), 1 bên ngồi chờ sẵn để **trả lời** (server). Server phải "lắng nghe"
(listen) ở 1 port cố định trước, client mới kết nối tới được.

Ví dụ chính bạn đã làm trong lab:
- `ssh ubuntu@192.168.122.201` → bạn (client) chủ động hỏi, VM (server) có
  tiến trình `sshd` đang lắng nghe port 22, chờ sẵn để trả lời.
- `curl http://192.168.122.201/dashboard` → bạn (client) hỏi, Apache/Horizon
  (server) đang lắng nghe port 80, trả về trang HTML.

Nếu server **chưa khởi động** (`sshd` chưa chạy, web server chưa lên) thì dù
mạng thông suốt 100%, client vẫn không kết nối được — không có ai ở đầu bên
kia "nhấc máy". Đây là lý do khi debug, luôn phải phân biệt "mạng lỗi" (gói
tin không tới được) và "service lỗi" (gói tin tới được, nhưng không ai lắng
nghe ở port đó).

### 0.11. TCP, UDP, ICMP — 3 "kiểu gói" hay gặp

Mục 0.0 nói tới **protocol** (giao thức). 3 protocol hay gặp nhất, ghi trong
header gói tin để phân biệt:

- **TCP**: kiểu "gọi điện" — bắt tay 3 bước trước khi gửi dữ liệu thật (gọi là
  3-way handshake: SYN → SYN-ACK → ACK), đảm bảo dữ liệu tới đủ, đúng thứ tự,
  tự gửi lại nếu bị mất. Có port. Dùng cho SSH, HTTP, database — nơi cần độ
  tin cậy hơn tốc độ.
- **UDP**: kiểu "gửi thư nhanh" — gửi luôn, không bắt tay, không đảm bảo tới,
  không đảm bảo đúng thứ tự, nhưng nhanh hơn TCP. Có port. Dùng cho video
  call, DNS, game online.
- **ICMP**: dùng để kiểm tra/báo lỗi mạng, không phải để truyền dữ liệu ứng
  dụng. `ping` chính là gửi gói ICMP loại "Echo Request", chờ máy đích trả về
  "Echo Reply". **ICMP không có port** — khác TCP/UDP.

Vì ICMP không có port, "mở port 22" là khái niệm chỉ áp dụng cho TCP/UDP —
với ICMP, rule firewall chỉ có thể cho phép/chặn theo *loại* gói ICMP (ví dụ
"cho phép ping"), không thể chỉ định port.

### 0.12. Firewall/Security Group — "bảo vệ chỉ cho vào phòng được phép"

Firewall quyết định traffic nào được phép đi qua, dựa trên IP nguồn/đích,
port, và protocol (TCP/UDP/ICMP). "Chỉ mở TCP port 22 (SSH) cho IP văn
phòng, đóng hết port khác" — đó là 1 rule firewall. Trong OpenStack, khái
niệm này chính là **Security Group** (phần 5 bên dưới) — khi tạo rule, bạn
luôn phải chọn `--protocol tcp/udp/icmp` vì mỗi loại lọc khác nhau.

### 0.13. DNS — "sổ danh bạ" đổi tên thành IP

Con người nhớ tên (`google.com`) dễ hơn nhớ số (`142.250.183.100`). **DNS**
(Domain Name System) là hệ thống dịch tên → IP, giống tra số điện thoại trong
danh bạ trước khi gọi. Khi bạn gõ `ping google.com`, máy tính hỏi DNS server
"IP của google.com là gì?", được trả lời, rồi mới thực sự gửi gói ICMP tới IP
đó.

### 0.14. VLAN — "chia 1 con phố vật lý thành nhiều khu ảo"

Bình thường 1 switch vật lý = 1 broadcast domain = 1 subnet (mục 0.5). **VLAN**
(Virtual LAN) cho phép **1 switch vật lý giả vờ là nhiều switch riêng biệt**
— máy cắm cùng switch nhưng VLAN khác nhau **không thấy nhau**, như bị tường
vô hình ngăn cách, dù cùng chung 1 dây/switch thật.

**Làm bằng cách nào — gắn tag vào frame.** Mỗi frame Ethernet đi qua cổng
VLAN được gắn thêm 4 byte, gọi là **802.1Q tag**, chứa 1 số **VLAN ID**
(1-4094). Switch đọc tag này để biết frame thuộc "khu ảo" nào, chỉ chuyển
tiếp cho các cổng cùng VLAN ID.

**2 loại cổng trên switch — access vs trunk:**
- **Access port**: chỉ thuộc **1 VLAN duy nhất**. Máy/VM cắm vào đây gửi
  frame KHÔNG có tag — switch tự "gắn tag" khi frame vào, tự "bóc tag" khi
  frame ra cổng access khác. Máy cuối (laptop, VM) không cần biết gì về
  VLAN cả.
- **Trunk port**: mang **nhiều VLAN cùng lúc** trên 1 dây, giữ tag khi
  truyền. Dùng để nối 2 switch với nhau, hoặc nối switch với router/hypervisor
  cần phân biệt nhiều VLAN trên 1 uplink. Đây chính là kiểu port dùng ở
  `br-ex` trong lab bạn khi cấu hình `provider-segment` — 1 uplink vật lý,
  nhiều VLAN (nhiều khách hàng) đi qua cùng lúc, phân biệt bằng tag.

**Ví dụ cụ thể:** 1 data center có 3 khách hàng A, B, C dùng chung 1 switch
vật lý và 1 sợi cáp uplink lên router. Ops gán: cổng khách A = VLAN 10
(access), cổng khách B = VLAN 20 (access), cổng khách C = VLAN 30 (access),
cổng nối lên router = trunk (mang cả VLAN 10, 20, 30). Kết quả: A, B, C dùng
chung hạ tầng vật lý nhưng **không bao giờ thấy traffic của nhau** — đúng
mô hình multi-tenant mà `provider-segment` trong Neutron (phần 3) mô phỏng
lại bằng software.

**VLAN khác nhau muốn nói chuyện với nhau thì sao?** VLAN chỉ cách ly ở
Layer 2 (switch) — 2 VLAN là 2 broadcast domain/2 subnet khác nhau, nên đúng
theo mục 0.5: phải qua **router** (hoặc thiết bị Layer 3 switch) để đi từ
VLAN này sang VLAN khác, gọi là *inter-VLAN routing*. VLAN không tự động cho
phép hay chặn gì cả — nó chỉ tạo ra sự tách biệt về mạng; việc "VLAN A có
được nói với VLAN B không" là do router/firewall giữa chúng quyết định.

### 0.15. Tổng kết nhanh — nối các khái niệm lại

Chú ý: 1 địa chỉ **không thể vừa private vừa là đích ở "ngoài mạng nội bộ"**
— nên tách 2 ví dụ riêng, ứng với 2 tình huống thật khác nhau:

```
Ví dụ A — SSH vào máy CÙNG mạng nội bộ: "ssh 192.168.1.10 -p 22"
  Máy bạn kiểm tra: 192.168.1.10 cùng subnet với mình? → Có
  → Gửi trực tiếp qua switch, dùng MAC address (không qua gateway, không NAT)
  → Đến đích, Security Group/firewall (TCP, port 22) kiểm tra: cho phép không?
      ├─ Được phép → tới đúng sshd đang lắng nghe port 22
      └─ Bị chặn   → gói bị drop, kết nối timeout

Ví dụ B — Ra internet thật: "curl https://142.250.183.100" (1 IP của google.com)
  Máy bạn kiểm tra: 142.250.183.100 (IP public) cùng subnet với mình? → Không
  → Gửi cho gateway, gateway (router) định tuyến tiếp
  → Vì đích là IP public, router làm NAT: đổi source IP+port private → public
  → Gói ra internet, tới server đích; lúc trả lời, NAT đổi ngược lại đúng máy bạn
```

Toàn bộ phần 1-9 phía dưới là Neutron **triển khai lại đúng các khái niệm
trên bằng software**, cho phép hàng nghìn "mạng ảo" (subnet, router, NAT,
VLAN...) cùng tồn tại trên 1 hạ tầng vật lý chung — không có gì mới về bản
chất, chỉ là ảo hoá hoá những gì switch/router vật lý vẫn làm.

### 0.16. Bảng thuật ngữ — tra nhanh khi quên

| Thuật ngữ | 1 câu giải thích |
|---|---|
| **Packet** | 1 gói dữ liệu nhỏ, gồm header (địa chỉ) + data (nội dung) |
| **IP address** | "Địa chỉ nhà" của 1 máy trên mạng |
| **MAC address** | Địa chỉ định danh của 1 card mạng — hãng gán cho NIC vật lý, hypervisor gán cho NIC ảo |
| **Subnet / CIDR** | 1 "khu phố" IP, viết dạng `x.x.x.x/n`; địa chỉ đầu/cuối không gán được cho máy |
| **Subnet mask** | Cách viết khác của prefix (`/24` = `255.255.255.0`) |
| **Default route** | Dòng `0.0.0.0/0` trong routing table — "IP nào không rõ đường thì đưa cho gateway" |
| **Gateway** | Cổng ra của 1 subnet, nơi gửi gói đi khi đích ở ngoài subnet; chính là IP của router |
| **Switch** | Nối máy trong cùng 1 subnet (Layer 2), dựa vào MAC, tự học bằng MAC address table |
| **Router** | Nối 2 subnet khác nhau (Layer 3), dựa vào IP + routing table |
| **Broadcast domain** | Vùng 1 gói broadcast lan tới được — về cơ bản = 1 subnet |
| **NAT** | Đổi IP (và port) nguồn để nhiều máy private cùng dùng chung 1 IP public |
| **Port** | "Số phòng" phân biệt nhiều dịch vụ trên cùng 1 IP; chỉ TCP/UDP có, ICMP không có |
| **TCP** | Giao thức "gọi điện" — bắt tay trước, đảm bảo tới đủ/đúng thứ tự |
| **UDP** | Giao thức "gửi thư nhanh" — không bắt tay, không đảm bảo tới, nhanh hơn TCP |
| **ICMP** | Giao thức kiểm tra/báo lỗi mạng (`ping` dùng ICMP), không có port |
| **Client / Server** | Bên hỏi (client) / bên lắng nghe chờ trả lời (server) |
| **Firewall / Security Group** | Luật cho phép/chặn traffic theo IP + port + protocol |
| **DNS** | Dịch tên miền → IP |
| **VLAN** | Tag (VLAN ID) chia 1 switch vật lý thành nhiều mạng ảo cách ly nhau |
| **Access port** | Cổng switch chỉ thuộc 1 VLAN, máy cắm vào không cần biết gì về VLAN |
| **Trunk port** | Cổng switch mang nhiều VLAN cùng lúc, giữ tag — dùng nối switch-switch/switch-router |
| **Floating IP** *(OpenStack)* | 1 IP public gán cho 1 VM cụ thể để nhận traffic từ ngoài vào |
| **Provider network** *(OpenStack)* | Network Neutron ứng với 1 network vật lý thật |
| **Overlay network** *(OpenStack)* | Network ảo, đóng gói qua network vật lý bằng VXLAN/Geneve |

## 1. Vấn đề Neutron giải quyết

Nova tạo VM. VM cần network để có IP, ra internet, và các VM khác nhìn thấy
nhau (hoặc không, tuỳ ai được cấp quyền). **Neutron** là dịch vụ quản lý toàn
bộ phần "mạng" đó — tạo network, subnet, router, gán IP, mở/chặn port.

Vấn đề khó nhất Neutron giải: **hàng nghìn VM của hàng trăm khách hàng khác
nhau, dùng chung 1 hạ tầng vật lý (vài chục NIC, vài trăm switch port), nhưng
phải cách ly hoàn toàn với nhau** — VM của khách A không được thấy traffic của
khách B, dù cả hai cùng chạy trên 1 physical switch.

## 2. 2 loại network — phân biệt bằng "ai định nghĩa nó"

| | Provider network (external) | Tenant/self-service network |
|---|---|---|
| Ai tạo | Admin (ops) | User bất kỳ, tự tạo |
| Đại diện cho | 1 network **vật lý thật** (VLAN/uplink có sẵn) | 1 network **ảo hoàn toàn**, không tồn tại ngoài Neutron |
| Ví dụ trong lab bạn | `public` (172.24.4.0/24) | `private` (10.0.0.0/26), `trove-mgmt` |
| Cách cách ly | VLAN tag hoặc 1 uplink riêng | Overlay (VXLAN/Geneve) — đóng gói gói tin gốc vào 1 gói UDP khác |

**Tenant network** là phần hay gây nhầm: nó **không tồn tại về mặt vật lý**.
Khi VM1 (host A) gửi gói cho VM2 (host B) cùng 1 tenant network, Neutron đóng
gói cả frame Ethernet gốc vào trong 1 gói UDP (Geneve, nếu dùng OVN — chính là
cái lab bạn đang chạy), gửi qua network vật lý bình thường giữa 2 host, rồi
host B mở gói ra, tái tạo lại frame gốc, đưa vào VM2. Đây gọi là **overlay
network**. Nhờ vậy, 1000 tenant có thể mỗi người tự đặt CIDR `10.0.0.0/24`
riêng, trùng nhau thoải mái mà không xung đột — vì chúng không bao giờ thật sự
"gặp nhau" ở tầng vật lý.

## 3. Bridge mapping — cầu nối giữa "logic" và "vật lý"

Đây là khái niệm quan trọng nhất để hiểu provider network. Xem giá trị thật
trên VM bạn:

```bash
ssh ubuntu@<IP>
sudo ovs-vsctl get open . external-ids:ovn-bridge-mappings
# → "physnet1:br-ex"
```

`physnet1` là **1 cái tên/label tuỳ ý** — không phải tên interface Linux thật.
Neutron dùng tên này làm "địa chỉ" logic. Dòng trên nói: *"mọi network nào
khai báo `provider_physical_network=physnet1` thì đi ra bridge OVS tên `br-ex`
trên host này"*.

```bash
sudo ovs-vsctl list-ports br-ex
# → NIC thật (production) hoặc port ảo NAT (lab)
```

Đây chính là chỗ khác nhau giữa lab và thật:

| | Lab (VM bạn) | Production thật |
|---|---|---|
| Port trong `br-ex` | Port ảo, NAT qua `virbr0` của libvirt | NIC vật lý, cắm dây ra switch/router thật |
| `physnet1` dẫn tới đâu | VM host KVM, rồi NAT ra ngoài | Router biên data center, có BGP announce IP ra internet |

**Lệnh Neutron tạo network không khác gì cả** — chỉ khác NIC nào được gắn vào
`br-ex` ở tầng OVS, việc đó nằm ngoài Neutron, do ops host tự cấu hình.

## 4. Router + Floating IP — cách VM riêng tư "lộ ra" internet

Tenant network (`private`) không route được ra ngoài — nó là overlay riêng.
Muốn VM trong đó có Internet, cần 1 **router** nối `private` với `public`:

```bash
openstack router show router1 -c external_gateway_info
# external_gateway_info chứa IP router đã "mượn" từ public-subnet để làm SNAT
```

Có 2 chiều:

- **SNAT (VM → Internet):** mọi VM trong `private` ra ngoài đều dùng chung 1 IP
  — IP gateway của router (giống NAT trên router Wi-Fi nhà bạn). Không cần
  cấu hình gì thêm, tự động khi router có `external_gateway`.
- **DNAT (Internet → VM cụ thể):** ngược lại, muốn 1 VM nhận traffic từ ngoài
  vào (SSH, web...), phải cấp riêng **Floating IP** cho nó:
  ```bash
  openstack floating ip create public
  openstack server add floating ip <vm> <floating-ip>
  ```
  Từ giờ, gói tin tới floating IP đó được router NAT thẳng vào IP private của
  đúng VM đó — 1:1, không chia sẻ với VM khác.

## 5. Security Group vs FWaaS — 2 tầng lọc khác nhau, dễ nhầm

| | Security Group | FWaaS (bạn đã cài trong lab) |
|---|---|---|
| Áp vào | **Port** (NIC) của 1 VM cụ thể | **Router** — chặn cả router, ảnh hưởng mọi VM sau nó |
| Ai quản lý | User tự set cho VM của mình | Admin/network engineer, chính sách chung |
| State | Stateful (cho phép traffic trả về tự động) | Cấu hình rule tường minh cả 2 chiều |
| Tình huống dùng | "VM của tôi chỉ mở port 22, 443" | "Toàn bộ VM sau router này không được ra port 25 (SMTP)" |

Đa số lab/demo chỉ cần Security Group. FWaaS hợp cho ai mô phỏng **chính sách
mạng tập trung cấp công ty** (giống firewall vật lý đặt ở biên mạng).

## 6. Port security — lớp lọc "ai được nói tên IP nào"

Đây là thứ đã từng làm bạn (và mình) tốn khá nhiều thời gian debug khi setup
Trove — **port security** mặc định chặn:
1. Gói ra khỏi port có **source IP khác** IP đã gán cho port đó (chống giả
   mạo địa chỉ, "anti-spoofing").
2. Traffic không khớp Security Group của port.

VM đóng vai trò **gateway/router** cho VM khác (như VM host đóng vai gateway
cho mạng `trove-mgmt` trong lab bạn) sẽ luôn cần forward gói **không phải của
chính nó** — port security sẽ chặn việc này trừ khi tắt riêng cho port đó:
```bash
openstack port set --no-security-group --disable-port-security <port-id>
```

## 7. OVS vs OVN — 2 cách Neutron điều khiển traffic

- **OVS (Open vSwitch) truyền thống**: mỗi node chạy 1 "L3 agent"/"DHCP
  agent"/"L2 agent" riêng, Neutron server đẩy flow rule xuống qua RPC (message
  queue). Nhiều tiến trình, nhiều điểm lỗi.
- **OVN (lab bạn đang dùng)**: Neutron chỉ ghi "ý định" (intent) vào 1 database
  trung tâm (OVN Northbound DB); 1 tiến trình khác (`ovn-controller` trên từng
  node) tự đọc DB đó, tự tính ra flow rule OpenFlow, tự áp vào OVS — không qua
  message queue nữa. Nhanh hơn, ít tiến trình hơn, là hướng OpenStack khuyến
  nghị cho deployment mới.

Bài học đã ghi trong README: **OVN Database KHÔNG bị xoá khi Neutron's MySQL
database bị recreate** (lúc re-stack) — đây là lý do "chạy lại `stack.sh`" lại
làm hỏng network dù MySQL đã sạch. 2 lớp state (MySQL của Neutron, và OVN's
riêng NB/SB database) phải đồng bộ với nhau; DevStack's cơ chế "xoá & tạo lại"
chỉ lo lớp MySQL, không lo lớp OVN.

## 8. Datastore/service network riêng — vì sao Trove cần thêm 1 network nữa

Ngoài `public`/`private`, lab có thêm `trove-mgmt` — network riêng cho control
plane (Trove control tới guest agent bên trong mỗi VM database), tách biệt
khỏi network người dùng cuối thấy (`private`). Đây là pattern chung: **network
quản trị (management plane) tách khỏi network dữ liệu (data plane)** — lý do
là bảo mật (user thường không được đụng vào network quản trị) và để 1 hành
động của Trove (như build database, backup...) không bị giới hạn bởi rule
Security Group user đặt trên VM của họ.

## 9. Traffic Nova instance đi được tới đâu — trace 1 gói tin

VM Nova gửi gói ra ngoài (ví dụ ping `8.8.8.8`) đi qua các lớp:

```
VM (10.0.0.x)
  → OVS bridge trên compute node (br-int)
  → Geneve tunnel (nếu VM và router nằm trên node khác nhau)
  → OVN gateway node — router1 làm NAT (SNAT: 10.0.0.x → IP gateway public)
  → br-ex (bridge mapping physnet1)
  → NIC/uplink thật (hoặc virbr0 NAT trong lab)
  → Internet
```

Gói trả về đi ngược lại đúng đường, NAT reverse tại chính OVN gateway node đó.
Hiểu được luồng này thì debug lỗi mạng OpenStack (VM không ra net, floating IP
không vào được...) chỉ còn là việc kiểm tra từng lớp trong chuỗi trên xem đứt
ở đâu — đúng cách mình đã debug lỗi Trove/Swift/OVN trong lab này.
