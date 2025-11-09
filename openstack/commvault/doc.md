
## 🧩 1️⃣ Kiến trúc tích hợp Commvault ↔ OpenStack

Khi triển khai backup OpenStack, bạn có các thành phần chính:

| Thành phần                                   | Vai trò                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| **CommServe**                                | Trung tâm điều phối, policy, schedule, catalog                 |
| **MediaAgent**                               | Xử lý luồng dữ liệu backup/restore (viết ra storage, cloud...) |
| **OpenStack Controller**                     | Nơi Commvault gọi API Keystone/Nova/Cinder                     |
| **OpenStack Plugin (Virtualization Client)** | Plugin Commvault dùng để nhận diện và backup VM qua API        |
| **Storage (Disk/Cloud/Library)**             | Nơi lưu dữ liệu backup                                         |

👉 Commvault không cần cài agent bên trong VM (agentless), nó dùng API OpenStack để snapshot volume rồi copy dữ liệu qua MediaAgent.

---

## 🧩 2️⃣ Cách hoạt động backup VM OpenStack

1. **Commvault kết nối Keystone**

    * Dùng `Auth URL`, `Tenant/Project`, `Username`, `Password`, và domain.
    * Lấy token để truy cập Nova/Cinder/Glance API.

2. **Quét danh sách VM**

    * Lấy metadata: VM name, ID, project, hypervisor, attached volumes...

3. **Tạo snapshot Cinder/Nova**

    * Gọi API `cinder snapshot-create` hoặc `nova image-create`.
    * Đợi snapshot hoàn tất.

4. **Copy dữ liệu snapshot ra ngoài**

    * Commvault mount snapshot block qua API và stream block-level data về MediaAgent.

5. **Xóa snapshot tạm thời**

    * Đảm bảo không tốn dung lượng trong cloud.

6. **Lưu catalog backup**

    * Ghi metadata (VM ID, image, network info, v.v.) vào database của CommServe.

---

## 🧩 3️⃣ Cách restore VM

Bạn có 2 chế độ restore:

| Loại Restore                 | Mô tả                                                            |
| ---------------------------- | ---------------------------------------------------------------- |
| **In-place restore**         | Phục hồi VM trở lại vị trí cũ (ghi đè volume)                    |
| **Out-of-place restore**     | Tạo VM mới trong cùng hoặc khác project                          |
| **Disk restore**             | Khôi phục chỉ một hoặc nhiều volume                              |
| **File-level restore (FLR)** | Truy cập vào nội dung backup để khôi phục từng file bên trong VM |

Cách thực hiện:

1. Trong **Commvault Console** → chọn **Virtualization → OpenStack → Restore**.
2. Chọn VM, restore point.
3. Chọn “In place” hoặc “Out of place”.
4. Nếu out-of-place, bạn chọn project/tenant và network muốn deploy.
5. Commvault tự gọi API OpenStack để tạo lại volume & VM.

---

## 🧩 4️⃣ Các yêu cầu cấu hình trước (prerequisites)

| Thành phần        | Yêu cầu                                                      |
| ----------------- | ------------------------------------------------------------ |
| OpenStack version | Mitaka trở lên (API v3 Keystone)                             |
| Quyền user        | Có quyền admin hoặc project-level full access                |
| Commvault version | ≥ 11 SP18 (hỗ trợ Keystone v3)                               |
| MediaAgent        | Có network reach tới OpenStack Cinder API và storage backend |
| Plugin            | “OpenStack Virtualization” phải được enable trong Commvault  |
| Storage           | Nên dùng deduplicated disk hoặc cloud tier                   |

---

## 🧩 5️⃣ Mô hình hoạt động (sơ đồ)

```
        +-------------------+
        |  CommServe        |
        +---------+---------+
                  |
                  | Control & Catalog
                  |
        +---------v---------+
        |  MediaAgent       |
        +---------+---------+
                  |
          Backup Data Stream
                  |
        +---------v---------+
        | OpenStack Cloud   |
        | (Keystone, Nova,  |
        |  Cinder, Glance)  |
        +-------------------+
```

---

## 🧩 6️⃣ Ví dụ cấu hình kết nối OpenStack trong Commvault

Khi tạo **Virtualization Client**:

* Type: **OpenStack**
* Keystone URL: `http://controller:5000/v3`
* Domain: `Default`
* Project (tenant): `demo`
* Username / Password: `admin / admin_pass`
* Region: `RegionOne`
* Availability Zone: `nova`

Sau khi add, Commvault sẽ liệt kê danh sách VM để bạn chọn policy backup.

---

## 🧩 7️⃣ Ưu điểm so với snapshot thủ công

| Tính năng                 | Snapshot thủ công | Commvault       |
| ------------------------- | ----------------- | --------------- |
| Lưu trữ ngoài OpenStack   | ❌                 | ✅               |
| Lịch backup định kỳ       | ❌                 | ✅               |
| Incremental backup        | ❌                 | ✅               |
| Restore linh hoạt         | Hạn chế           | ✅ (in/out/file) |
| Retention, catalog, dedup | ❌                 | ✅               |
| Báo cáo, monitoring       | ❌                 | ✅               |

---

## 🧠 Tóm tắt gọn

✅ Commvault **backup OpenStack VM qua API**, không cần agent.
✅ Hỗ trợ **snapshot → copy → cleanup → catalog**.
✅ Restore được cả **VM, disk, hoặc file-level**.
✅ Dễ quản lý qua policy, schedule, retention.

---

Nếu bạn muốn, mình có thể giúp bạn viết **checklist hoặc playbook Ansible** để tự động:

* đăng ký OpenStack environment trong Commvault,
* tạo policy backup VM,
* chạy restore thử.

Bạn muốn mình giúp tạo bản đó luôn không?
