# Jenkins (Ansible)

Cài Jenkins lên VM Linux có sẵn. Một bộ cài, 2 trục lựa chọn:

| | Chọn bằng | Giá trị |
|---|---|---|
| **Chế độ** | `[jenkins_agents]` trong `inventory.ini` | trống → **standalone** (job chạy trên controller) · có host → **controller + agent** (controller 0 executor, job chạy trên agent, controller SSH vào agent) |
| **Nguồn cài** | `jenkins_install_source` trong `group_vars/all/settings.yml` | **online** (VM tự tải, Ubuntu/Debian) · **offline** (VM không cần internet; Ansible đẩy file từ `bundle/` qua SSH; mọi Linux dùng systemd) |

Toàn bộ cấu hình Jenkins (user admin, node agent, credential SSH, URL) khai báo bằng **JCasC**, sinh từ inventory — không cấu hình tay trên UI.

## Bắt đầu

```bash
cp inventory.example.ini inventory.ini   # sửa IP/user các VM
./install.sh
```

Đăng nhập: `admin`, mật khẩu ở `credentials/jenkins_admin_password` (tự sinh lần đầu).

## Thao tác thường gặp

| Việc | Làm |
|---|---|
| Thêm / bớt agent | Sửa `[jenkins_agents]` → `./install.sh` (hoặc `--limit 'jenkins_controller:agent-3'`). Controller chỉ **reload** JCasC, không restart. Luôn chạy kèm controller. |
| Đổi mật khẩu admin | Sửa `credentials/jenkins_admin_password` → `./install.sh` (reload) |
| Thêm plugin | Thêm vào `jenkins_plugins` → `./install.sh` (restart). Offline: chạy lại `bundle.yml` trước. |
| Cài offline | Trên máy có internet: `ansible-playbook bundle.yml` → mang `bundle/` sang → đặt `jenkins_install_source: offline` → `./install.sh` |
| Nâng Jenkins | online: apt lấy bản LTS mới · offline: đổi `jenkins_version`, chạy lại `bundle.yml` |

Restart hay reload được quyết định tự động (`roles/jenkins/tasks/casc.yml`): đổi service/war/plugin → **restart**; chỉ đổi JCasC/mật khẩu → **reload**; không đổi → không làm gì.

## Luồng chạy (`jenkins.yml`)

```
play 1  Prepare      mọi host    chờ SSH, facts, cloud-init, kiểm tra điều kiện (OS, bundle khớp version/plugin)
play 2  Controller   jenkins     Java → Jenkins → service → plugin → SSH key        (roles/jenkins/tasks/main.yml)
play 3  Agents       agents      Java → user jenkins → nhận public key controller   (roles/jenkins_agent)
play 4  Controller   jenkins     known_hosts → JCasC → restart/reload → agent online (roles/jenkins/tasks/casc.yml)
```

Controller chạy 2 lần vì JCasC cần thông tin của agent (host key, đường dẫn java). Dữ liệu truyền giữa các play qua `hostvars`:

| Fact | Từ → đến | Dùng để |
|---|---|---|
| `jenkins_controller_pubkey` | controller → agent | `authorized_keys` của user jenkins trên agent |
| `jenkins_agent_hostkey` | agent → controller | `known_hosts` (controller xác thực agent) |
| `jenkins_java_bin` | agent → controller | `javaPath` của node trong JCasC |
| `jenkins_restart_needed` | play 2 → play 4 | quyết định restart |

## Cấu trúc

```
inventory.example.ini       mẫu inventory (inventory.ini thật: gitignore)
group_vars/all/settings.yml biến người dùng chỉnh
group_vars/all/derived.yml  biến suy ra (không sửa)
jenkins.yml / install.sh    playbook chính
bundle.yml                  tạo bundle offline (JRE, jenkins.war, plugin + dependency)
roles/
  java_runtime/             Java: apt (online) hoặc JRE Temurin từ bundle (offline)
  jenkins/tasks/
    main.yml                thứ tự cài controller (gọi các file dưới)
    install_online.yml      apt repo pkg.jenkins.io
    install_offline.yml     jenkins.war + systemd unit
    service.yml             drop-in: port, JCasC, bỏ setup wizard
    plugins*.yml            plugin manager (online) / plugins.tar.gz (offline)
    ssh_key.yml             key controller → agent
    casc.yml                JCasC + restart/reload + kiểm tra agent
  jenkins_agent/            agent
credentials/, bundle/       sinh ra, gitignore
```

## Biến chính (`group_vars/all/settings.yml`)

| Biến | Mặc định | |
|---|---|---|
| `jenkins_install_source` | `online` | `online` / `offline` |
| `jenkins_version` | `2.580.2` | version war trong bundle (offline) |
| `jenkins_plugins` | 6 plugin | plugin cần có (dependency tự kéo theo) |
| `jenkins_http_port` | `8080` | |
| `jenkins_controller_executors` | `2` | chỉ áp dụng khi standalone |
| `jenkins_agent_executors` / `_labels` | `2` / `linux` | ghi đè được từng host |
| `jenkins_agent_address` | IP nội bộ agent | controller SSH vào địa chỉ này; khác mạng → đặt IP public |
| `jenkins_bundle_arches` | `[x64]` | kiến trúc CPU cần có trong bundle |

## Giới hạn

- Online chỉ Ubuntu/Debian (apt). Distro khác → offline.
- Bộ cài **thêm** plugin, không gỡ plugin cài tay.
- Firewall (port 8080, SSH controller → agent) không nằm trong bộ cài.
