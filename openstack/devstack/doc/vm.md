Dưới đây là hướng dẫn chi tiết **API tạo và xoá VM (instance)** trong OpenStack (Nova) qua `curl`:

---
### 1. Gọi API để tạo keypair
```bash
curl --location 'http://35.197.146.206/compute/v2.1/os-keypairs' \
--header 'Content-Type: application/json' \
--header 'X-Auth-Token: gAAAAABocNUXaHkscpM4jPFqYY46YHZPkmAEze2Zk2Kr_S7y6UxoM0sjgcxSH0T6aiWnZ9lCOypvpqdTC1mODivl-K_0cGQDp6OAcByyBUNtCOZ695r6WTo8UIHDDXJxq6vmuzVRl3J71N-8fcelOAR9NI6633zetZHDOqnk-jBbweuxwfWMcOA' \
--data-raw '{
  "keypair": {
    "name": "mykey",
    "public_key": "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKT+X+GVJ1EwWxT+nHb6CdCkChG5be/W9ZEHGbq5dQiKsDKBWiNdZlCocKMmxX6MmTeiB/eZ0GxiHI6qRuK9/6A= namnv@namnv"
  }
}
'
```

## 🚀 **Tạo VM (Instance)** – Nova API

### 1. Gọi API để tạo instance

```bash
curl -X POST http://<nova_endpoint>/servers \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: <admin_token>" \
  -d '{
    "server": {
      "name": "test-vm",
      "imageRef": "<image_id>",
      "flavorRef": "<flavor_id>",
      "networks": [
        {
          "uuid": "<network_id>"
        }
      ],
      "key_name": "<optional_ssh_keypair>"
    }
  }'
```

📌 **Thông số cần thay thế**:

* `<nova_endpoint>`: Ví dụ `34.142.171.53/compute/v2.1/<project_id>`
* `<image_id>`: ID của image (ví dụ Ubuntu/CentOS)
* `<flavor_id>`: ID của flavor (m1.small, v.v.)
* `<network_id>`: ID của mạng Neutron
* `<optional_ssh_keypair>`: tên keypair nếu muốn SSH vào VM

💡 **Lấy các ID cần thiết**:

```bash
openstack image list
openstack flavor list
openstack network list
openstack keypair list
```

---

Dưới đây là tài liệu **tổng hợp đầy đủ và có giải thích chi tiết** các thao tác quản lý vòng đời VM trên OpenStack qua
REST API (`nova`/`compute`, `volume`), bao gồm ví dụ `curl` và các mô tả rõ ràng về từng trường.

---

# 🖥️ OpenStack – Tài liệu API Quản lý Vòng đời VM

## 1. 🚀 Tạo VM mới (Nova create server)

### ✅ API

```
POST /v2.1/{project_id}/servers
```

### ✅ Giải thích các trường:

| Trường                    | Bắt buộc | Ý nghĩa                                                          |
|---------------------------|----------|------------------------------------------------------------------|
| `name`                    | ✅        | Tên VM sẽ hiển thị trong danh sách máy ảo                        |
| `imageRef`                | ✅ (\*)   | ID của image để boot VM. Nếu dùng volume boot thì không cần      |
| `flavorRef`               | ✅        | ID của flavor (cấu hình CPU/RAM)                                 |
| `networks`                | ✅        | Danh sách network mà VM sẽ gắn NIC vào                           |
| `key_name`                | ❌        | Tên của SSH keypair sẽ inject vào VM                             |
| `security_groups`         | ❌        | Danh sách security group áp dụng, ví dụ: `[{"name": "default"}]` |
| `block_device_mapping_v2` | ❌        | Nếu boot từ volume (Cinder)                                      |
| `availability_zone`       | ❌        | Tên AZ (nếu muốn chỉ định nơi đặt VM)                            |
| `user_data`               | ❌        | Cloud-init script base64 encode                                  |
| `metadata`                | ❌        | Gán metadata key-value vào VM                                    |
| `config_drive`            | ❌        | Nếu `true`, OpenStack sẽ tạo config drive (ISO chứa metadata)    |
| `min_count`               | ❌        | Tạo ít nhất bao nhiêu VM (mặc định 1)                            |
| `max_count`               | ❌        | Tạo tối đa bao nhiêu VM (mặc định 1)                             |

### ✅ Ví dụ `curl`

### ➕ Tạo VM:

```bash
curl -X POST http://34.142.171.53/compute/v2.1/ad79d6284a6e4fa3b6d269e9f795de63/servers \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: <admin_token>" \
  -d '{
    "server": {
      "name": "vm-from-api",
      "imageRef": "b8c634f2-8aa0-4bcf-8b69-350eb50b27fc",
      "flavorRef": "1",
      "networks": [
        {
          "uuid": "e1f14cfb-95ec-4d87-9287-3568e43a60b4"
        }
      ]
    }
  }'
```

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "server": {
      "name": "vm-api-demo",
      "imageRef": "image-uuid",
      "flavorRef": "flavor-id",
      "networks": [{"uuid": "net-uuid"}],
      "key_name": "my-key",
      "metadata": {
        "purpose": "api-created"
      }
    }
  }'
```

---

## 2. ❌ Xóa VM

```bash
curl -X DELETE http://<compute>/v2.1/<project_id>/servers/<server_id> \
  -H "X-Auth-Token: <token>"
```

---

## 3. 🔁 Reboot VM

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{ "reboot": { "type": "HARD" } }'
```

> `type`: `HARD` (force reboot) hoặc `SOFT` (gentle restart)

---

## 4. ⬆️ Resize VM (thay đổi flavor)

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{ "resize": { "flavorRef": "new-flavor-id" } }'
```

> Sau khi resize thành công, cần **confirm** hoặc **revert**:

### Xác nhận:

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -d '{ "confirmResize": null }'
```

### Hoặc hủy:

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -d '{ "revertResize": null }'
```

---

## 5. 🔗 Attach Volume

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/os-volume_attachments \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "volumeAttachment": {
      "volumeId": "<volume_id>",
      "device": "/dev/vdb"
    }
  }'
```

---

## 6. 🧱 Snapshot VM (tạo image từ VM)

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{ "createImage": { "name": "snapshot-name" } }'
```

---

## 7. 📦 Backup VM

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "createBackup": {
      "name": "backup-name",
      "backup_type": "daily",
      "rotation": 1
    }
  }'
```

---

## 8. 🧬 Rebuild VM (dùng lại instance với image khác)

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers/<server_id>/action \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "rebuild": {
      "imageRef": "new-image-id",
      "name": "new-vm-name"
    }
  }'
```

---

## 9. ♻️ Restore từ snapshot hoặc backup

> Cách 1: **Tạo volume từ snapshot rồi boot từ volume**

```bash
curl -X POST http://<volume>/v3/<project_id>/volumes \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "volume": {
      "snapshot_id": "<snapshot_id>",
      "name": "restored-vol"
    }
  }'
```

> Cách 2: **Tạo VM boot từ volume**

```bash
curl -X POST http://<compute>/v2.1/<project_id>/servers \
  -H "X-Auth-Token: <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "server": {
      "name": "boot-from-volume",
      "flavorRef": "flavor-id",
      "block_device_mapping_v2": [
        {
          "uuid": "<volume_id>",
          "boot_index": 0,
          "source_type": "volume",
          "destination_type": "volume",
          "delete_on_termination": false
        }
      ],
      "networks": [
        { "uuid": "<network_id>" }
      ]
    }
  }'
```

---

## 📋 Tham khảo thêm

* List servers: `GET /v2.1/{project_id}/servers`
* List images: `GET /image/v2/images`
* List volumes: `GET /v3/{project_id}/volumes`
* List snapshots: `GET /v3/{project_id}/snapshots`

---

📌 **Ghi chú:**

* Thay `<token>`, `<project_id>`, `<server_id>`, `<imageRef>`, `<flavorRef>`, `<volume_id>`, `<network_id>` bằng giá trị
  thực tế.
* Tất cả API cần xác thực bằng token (`X-Auth-Token`) lấy từ Keystone.
* Volume API dùng qua `cinder` (`http://<volume_host>:8776`), Image API dùng qua `glance` (`/image/v2`).

---

Nếu bạn cần **file Markdown hoặc HTML đầy đủ** để copy/dán hoặc làm tài liệu, mình có thể tạo giúp luôn. Bạn có muốn
không?
