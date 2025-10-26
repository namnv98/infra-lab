# 📘 OpenStack Identity API via Curl

Tài liệu tổng hợp sử dụng `curl` để thao tác với OpenStack API (Identity, Compute, Volume, Network). Tất cả ví dụ đều sử
dụng IP public: `34.142.171.53`

## 🔐 Lấy Token X-Auth-Token (Scoped)

```bash
curl -i -X POST http://34.142.171.53/identity/v3/auth/tokens   -H "Content-Type: application/json"   -d '{
    "auth": {
      "identity": {
        "methods": ["password"],
        "password": {
          "user": {
            "name": "admin",
            "domain": { "id": "default" },
            "password": "admin"
          }
        }
      },
      "scope": {
        "project": {
          "name": "admin",
          "domain": { "id": "default" }
        }
      }
    }
  }'
```

> 📝 Token được trả về trong response header `X-Subject-Token`.

---

## 🧾 Lấy Thông Tin Chi Tiết

### 🔍 Get thông tin Project theo ID

```bash
curl http://34.142.171.53/identity/v3/projects/<project_id>   -H "X-Auth-Token: <admin_token>"
```

### 🔍 Get thông tin User theo ID

```bash
curl http://34.142.171.53/identity/v3/users/<user_id>   -H "X-Auth-Token: <admin_token>"
```

---

## 🔄 Role Assignment

### ➕ Gán role cho user vào project

```bash
curl -X PUT http://34.142.171.53/identity/v3/projects/<project_id>/users/<user_id>/roles/<role_id>   -H "X-Auth-Token: <admin_token>"
```

### ➖ Bỏ gán role (Xoá role assignment)

```bash
curl -X DELETE http://34.142.171.53/identity/v3/projects/<project_id>/users/<user_id>/roles/<role_id>   -H "X-Auth-Token: <admin_token>"
```

---

## 🆔 Token Không Có Scope (Unscoped Token)

### 🧾 Lấy token unscoped

```bash
curl -i -X POST http://34.142.171.53/identity/v3/auth/tokens   -H "Content-Type: application/json"   -d '{
    "auth": {
      "identity": {
        "methods": ["password"],
        "password": {
          "user": {
            "name": "namnv",
            "domain": { "id": "default" },
            "password": "namnv"
          }
        }
      }
    }
  }'
```

### 📋 Danh sách project user có quyền truy cập

```bash
curl http://34.142.171.53/identity/v3/auth/projects   -H "X-Auth-Token: <unscoped_token>"
```

---

## 📚 Lấy danh sách catalog

```bash
curl --location 'http://34.142.171.53/identity/v3/auth/catalog' --header 'X-Auth-Token: <admin_token>'
```

---

## 🧑‍💼 Quản lý Project

### 📋 Danh sách project

```bash
curl http://34.142.171.53/identity/v3/projects -H "X-Auth-Token: <admin_token>"
```

### ➕ Tạo project

```bash
curl -X POST http://34.142.171.53/identity/v3/projects   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "project": {
      "name": "myproject",
      "description": "Project tạo qua REST API",
      "enabled": true,
      "domain_id": "default"
    }
  }'
```

### ❌ Xoá project

```bash
curl -X DELETE http://34.142.171.53/identity/v3/projects/<project_id>   -H "X-Auth-Token: <admin_token>"
```

---

## 👤 Quản lý User

### ➕ Tạo user

```bash
curl -X POST http://34.142.171.53/identity/v3/users   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "user": {
      "name": "namnv",
      "password": "namnv",
      "default_project_id": "<project_id>",
      "domain_id": "default",
      "enabled": true
    }
  }'
```

### 📋 Danh sách user

```bash
curl http://34.142.171.53/identity/v3/users   -H "X-Auth-Token: <admin_token>"
```

### 🛠️ Thay đổi mật khẩu

```bash
curl -X PATCH http://34.142.171.53/identity/v3/users/<user_id>/password   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "user": {
      "original_password": "oldpassword",
      "password": "newpassword"
    }
  }'
```

### 🏷 Gán project mặc định cho user

```bash
curl -X PATCH http://34.142.171.53/identity/v3/users/<user_id>   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "user": {
      "default_project_id": "<project_id>"
    }
  }'
```

---

## 🔐 Quản lý Role

### 📋 Danh sách role

```bash
curl http://34.142.171.53/identity/v3/roles -H "X-Auth-Token: <admin_token>"
```

---

## 📦 Quota

### 🖥️ Compute (Nova)

```bash
curl -X PUT http://34.142.171.53/compute/v2.1/os-quota-sets/<project_id>   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "quota_set": {
      "cores": 10,
      "instances": 1,
      "ram": 20480
    }
  }'
```

### 💾 Volume (Cinder)

```bash
curl -X PUT 'http://34.142.171.53/volume/v3/os-quota-sets/<project_id>?usage=False'   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "quota_set": {
      "volumes": 5,
      "gigabytes": 100,
      "snapshots": 3
    }
  }'
```

### 🌐 Network (Neutron)

```bash
curl -X PUT http://34.142.171.53/networking/v2.0/quotas/<project_id>   -H "Content-Type: application/json"   -H "X-Auth-Token: <admin_token>"   -d '{
    "quota": {
      "network": 1,
      "subnet": 1,
      "port": 50
    }
  }'
```

Danh sách network

```bash
curl --location 'http://34.142.171.53/networking/v2.0/networks' \
--header 'X-Auth-Token: gAAAAABocLEqOsrHXcg7UTbWeyQ2PM1ntk0Ri5yD7hcv4J4OOZQE_PPv_M_1enn6wVJUmBVYWfsMV3nSFJ3p349gQSwfofFHJtZXeDZXmTUDM0dPrCEekhmsyTrh5fQEmq300ritnXFlKME9DvIDYKZTA2G7uB7zNAXiUaWv1Lhzp1yoiNniiZc'
```

### 📥 Get quota hiện tại

```bash
curl http://34.142.171.53/compute/v2/os-quota-sets/<project_id>   -H "X-Auth-Token: <admin_token>"
```

```bash
curl http://34.142.171.53/volume/v3/os-quota-sets/<project_id>   -H "X-Auth-Token: <admin_token>"
```

```bash
curl http://34.142.171.53/networking/v2.0/quotas/<project_id>   -H "X-Auth-Token: <admin_token>"
```

---

## 🏢 Quản lý domain

```bash
curl http://34.142.171.53/identity/v3/domains   -H "X-Auth-Token: <admin_token>"
```

---

## 📡 Service và Endpoint

```bash
curl http://34.142.171.53/identity/v3/services   -H "X-Auth-Token: <admin_token>"
```

```bash
curl http://34.142.171.53/identity/v3/endpoints   -H "X-Auth-Token: <admin_token>"
```

---

## 🖼️ Lấy danh sách image (Glance v2)

```bash
curl -X GET http://34.142.171.53/image/v2/images \
  -H "X-Auth-Token: <admin_token>"
```

---

## ℹ️ Lưu ý

* Thay thế `<admin_token>`, `<project_id>`, `<user_id>`, `<role_id>` bằng giá trị thực tế.
* Có thể lấy các ID bằng lệnh:

```bash
openstack project list
openstack user list
openstack role list
```
