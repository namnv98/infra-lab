### **Kiến trúc OpenStack: Các Thành phần Cốt lõi Chi Tiết**

OpenStack không phải là một ứng dụng đơn lẻ mà là một tập hợp các dự án mã nguồn mở, hoạt động như những "dịch vụ" độc
lập nhưng tích hợp chặt chẽ để tạo thành một nền tảng điện toán đám mây hoàn chỉnh. Dưới đây là phân tích chi tiết về
các thành phần cốt lõi.

---

#### **1. Nova (Dịch vụ Điện toán - Compute)**

Nova đóng vai trò là bộ não cho các hoạt động điện toán, quản lý toàn bộ vòng đời của các máy ảo (VM).

* **Chức năng chính:** Cung cấp và quản lý các instance (máy ảo) trên nền tảng OpenStack.
* **Kiến trúc & Cách hoạt động:**
    * **Nova-API:** Tiếp nhận và xử lý các yêu cầu REST API (như tạo, xóa, quản lý máy ảo).
    * **Nova-Scheduler:** Quyết định máy chủ vật lý (compute node) nào sẽ chạy máy ảo, dựa trên các yếu tố như tài
      nguyên khả dụng, chính sách đặt chỗ.
    * **Nova-Compute:** Thành phần chính chạy trên mỗi compute node, tương tác trực tiếp với hypervisor (KVM, VMware,
      Hyper-V, v.v.) để khởi chạy và hủy các máy ảo.
    * **Nova-Conductor:** Đứng giữa Nova-Compute và cơ sở dữ liệu, tăng cường bảo mật bằng cách ngăn compute node truy
      cập trực tiếp vào database.
* **Tính năng nổi bật:**
    * Hỗ trợ đa dạng hypervisor.
    * Tự động mở rộng quy mô (scale horizontally) bằng cách thêm các compute node mới.
    * Hỗ trợ tạo snapshot và khôi phục máy ảo.
* **Tích hợp với:** Glance (để lấy image), Neutron (để cung cấp mạng), Keystone (để xác thực), Cinder (để gắn ổ đĩa).

---

#### **2. Neutron (Dịch vụ Mạng - Networking)**

Neutron cung cấp "hệ thống thần kinh" mạng cho OpenStack, cho phép người dùng định nghĩa và kiểm soát hoàn toàn cấu trúc
mạng ảo.

* **Chức năng chính:** Cung cấp Mạng-dưới-dạng-Dịch-vụ (Network-as-a-Service) cho các máy ảo.
* **Kiến trúc & Cách hoạt động:**
    * **Neutron Server:** Nhận và định tuyến các yêu cầu API để tạo và cấu hình mạng.
    * **Plugin & Agent:** Cho phép Neutron làm việc với nhiều công nghệ mạng khác nhau (như Open vSwitch, Linux Bridge).
      Các agent chạy trên compute node và network node để thực thi các quy tắc mạng (router, firewall, switch ảo).
    * **Cung cấp các thực thể mạng:**
        * **Network:** Một segment mạng Layer 2 được cô lập (tương tự VLAN).
        * **Subnet:** Dải địa chỉ IP Layer 3 cho một network.
        * **Router:** Định tuyến lưu lượng giữa các network và ra mạng bên ngoài (internet).
* **Tính năng nổi bật:**
    * Các nhóm bảo mật (Security Groups): Firewall ảo ở mức port cho từng máy ảo.
    * Cân bằng tải ảo (Load Balancer-as-a-Service).
    * Mạng riêng ảo (VPN-as-a-Service).
    * Hỗ trợ các công nghệ mạng overlay tiên tiến như VXLAN, GRE.

---

#### **3. Swift (Dịch trữ Đối tượng - Object Storage)**

Swift là hệ thống lưu trữ phân tán, được thiết kế cho dữ liệu phi cấu trúc, có khả năng mở rộng vô hạn và độ bền cực
cao.

* **Chức năng chính:** Lưu trữ và truy xuất lượng lớn dữ liệu không cấu trúc một cách an toàn và phân tán.
* **Kiến trúc & Cách hoạt động:**
    * **Không có kiến trúc master-centralized:** Mọi node đều có vai trò ngang hàng, tránh điểm lỗi duy nhất.
    * **Dữ liệu được lưu trữ trong các "vùng" (zones):** Giúp chịu được lỗi của toàn bộ một rack hoặc data center.
    * **Dữ liệu được nhân bản và phân tán** trên nhiều node đĩa cứng.
    * **Ring:** Là một thành phần ảo, ánh xạ dữ liệu đến các vị trí vật lý thực tế trên cluster.
* **Tính năng nổi bật:**
    * Khả năng chịu lỗi cực cao: Dữ liệu vẫn có thể truy cập ngay cả khi nhiều node hoặc ổ đĩa bị lỗi.
    * Không có giới hạn kích thước file hoặc tổng dung lượng lưu trữ.
    * Phù hợp cho lưu trữ backup, archive, video, image, và dữ liệu cho ứng dụng web.

---

#### **4. Cinder (Dịch vụ Lưu trữ Khối - Block Storage)**

Cinder cung cấp khả năng lưu trữ "khối" (block-level) bền vững cho các máy ảo, tương tự như việc gắn một ổ cứng ngoài
vào máy tính.

* **Chức năng chính:** Cung cấp các volume (ổ đĩa ảo) có thể gắn (attach) và tháo (detach) động vào các máy ảo.
* **Kiến trúc & Cách hoạt động:**
    * **Cinder-API:** Tiếp nhận yêu cầu tạo và quản lý volume.
    * **Cinder-Volume:** Quản lý các volume và tương tác với các backend lưu trữ (như CEPH, LVM, NetApp, SolidFire).
    * **Cinder-Scheduler:** Lựa chọn backend lưu trữ phù hợp để tạo volume.
    * **Cinder-Backup:** Quản lý việc sao lưu volume sang Swift.
* **Tính năng nổi bật:**
    * Tạo snapshot và clone của volume.
    * Cho phép mở rộng hoặc thu nhỏ kích thước volume.
    * Dữ liệu trên volume vẫn tồn tại ngay cả khi máy ảo bị xóa.
    * Hỗ trợ nhiều driver lưu trữ thương mại và mã nguồn mở.

---

#### **5. Glance (Dịch vụ Hình ảnh - Image Service)**

Glance đóng vai trò như một thư viện template, lưu trữ và quản lý các bản sao (image) của đĩa máy ảo để Nova có thể sử
dụng để khởi chạy các instance mới.

* **Chức năng chính:** Đăng ký, khám phá, truy xuất và quản lý các image máy ảo.
* **Kiến trúc & Cách hoạt động:**
    * **Glance-API:** Cung cấp giao diện REST để người dùng quản lý image (upload, download, tạo mới).
    * **Glance-Registry:** Lưu trữ, xử lý và truy xuất siêu dữ liệu (metadata) về các image.
    * **Có thể lưu trữ image** trên nhiều backend khác nhau như hệ thống file, Swift, S3, Ceph.
* **Tính năng nổi bật:**
    * Hỗ trợ nhiều định dạng image (QCOW2, RAW, VHD, VMDK, v.v.).
    * Tạo snapshot từ một máy ảu đang chạy và lưu nó dưới dạng image mới.
    * Kiểm soát quyền truy cập vào image (public hoặc private).

---

#### **6. Keystone (Dịch vụ Định danh - Identity Service)**

Keystone là "cổng trung tâm" của OpenStack, chịu trách nhiệm cho tất cả các hoạt động xác thực và ủy quyền.

* **Chức năng chính:** Cung cấp dịch vụ xác thực (Authentication) và ủy quyền (Authorization) trung tâm cho tất cả các
  dịch vụ OpenStack.
* **Kiến trúc & Cách hoạt động:**
    * **Danh tính (Identity):** Quản lý người dùng (Users) và nhóm (Groups). Hỗ trợ nhiều backend như SQL, LDAP, Active
      Directory.
    * **Dịch vụ (Services):** Là một catalog chứa danh sách tất cả các dịch vụ OpenStack và endpoints (URL) của chúng.
    * **Vai trò (Roles):** Định nghĩa quyền mà một người dùng có thể có (ví dụ: `admin`, `member`).
    * **Dự án (Projects/Tenants):** Là một nhóm logic để cô lập và tổ chức tài nguyên.
    * **Token:** Cấp phát và xác thực token (dạng UUID hoặc Fernet) để người dùng truy cập vào các dịch vụ.
* **Tính năng nổi bật:**
    * Là trung tâm của mọi tương tác trong OpenStack. Không có Keystone, các dịch vụ khác không thể hoạt động.
    * Hỗ trợ đa xác thực (multi-factor authentication).
    * Cung cấp danh mục dịch vụ động, cho phép các dịch vụ đăng ký endpoint của chúng.