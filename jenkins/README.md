# Jenkins (Ansible)

Cài Jenkins lên VM Linux có sẵn. Một bộ cài, 2 trục lựa chọn:

| | Chọn bằng | Giá trị |
|---|---|---|
| **Chế độ** | `[jenkins_agents]` trong `inventory.ini` | trống → **standalone** (job chạy trên controller) · có host → **controller + agent** (controller 0 executor, job chạy trên agent, controller SSH vào agent) |
| **Nguồn cài** | `jenkins_install_source` trong `group_vars/all.yml` | **online** (VM tự tải, Ubuntu/Debian) · **offline** (VM không cần internet; Ansible đẩy file từ `bundle/` qua SSH; mọi Linux dùng systemd) |

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
| Nâng Jenkins + plugin | online: `./install.sh -e jenkins_upgrade=true` (apt lấy bản LTS mới, plugin manager nâng mọi plugin) → restart · offline: đổi `jenkins_version`, chạy lại `bundle.yml` → `./install.sh`. Chạy thường (không có cờ) **không** nâng gì. |

Restart hay reload được quyết định tự động (`roles/jenkins_controller/tasks/configure.yml`):

- **restart**: task nào đổi Java / war / unit / drop-in / plugin thì `notify: Restart pending`. Handler ghi file `/var/lib/jenkins/.ansible-restart-pending`, và play 4 restart xong thì xoá file. Dấu được lưu trên đĩa, nên nếu lần chạy trước lỗi giữa chừng (ví dụ một agent không SSH được) thì lần sau vẫn restart.
- **reload**: chỉ đổi JCasC hoặc mật khẩu thì nạp lại cấu hình, không ngắt job đang chạy.
- **không đổi gì**: không làm gì.

## Luồng chạy (`jenkins.yml`)

```
play 1  Prepare      mọi host    chờ SSH, facts, cloud-init, kiểm tra điều kiện (OS, bundle khớp version/plugin)
play 2  Controller   controller  Java → Jenkins → drop-in → plugin → SSH key     (jenkins_controller/tasks/main.yml)
play 3  Agents       agents      Java → user jenkins → nhận public key controller  (jenkins_agent)
play 4  Controller   controller  đọc IP + host key agent → known_hosts → JCasC → restart/reload → kiểm tra
                                                                                (jenkins_controller/tasks/configure.yml)
```

Controller chạy 2 lần vì agent cần public key của controller (play 2 → 3), còn JCasC của controller lại cần agent đã sẵn sàng. Chỉ có 1 fact truyền giữa các play là `jenkins_controller_pubkey` (controller → agent, qua `hostvars`). IP và host key của agent được play 4 đọc thẳng từ agent bằng `delegate_to`, nên `--limit` chỉ gồm controller và agent mới vẫn chạy được.

## Cấu trúc

```
inventory.example.ini          mẫu inventory (inventory.ini thật: gitignore)
group_vars/all.yml             mọi biến: phần trên người dùng chỉnh, phần cuối đường dẫn / biến suy ra
jenkins.yml / install.sh       playbook chính
bundle.yml                     tạo bundle offline (JRE, jenkins.war, plugin + dependency)
roles/
  jenkins_common/              Java + git + fontconfig (dùng chung controller và agent)
  jenkins_controller/
    tasks/main.yml             play 2: common → install → plugins → SSH key
    tasks/install.yml          online (apt) / offline (war + unit) + drop-in systemd
    tasks/plugins.yml          online (plugin manager) / offline (plugins.tar.gz)
    tasks/configure.yml        play 4: known_hosts → JCasC → restart/reload → kiểm tra
    handlers/main.yml          "Restart pending" → ghi file dấu
    templates/                 jenkins.yaml.j2 (JCasC), override.conf.j2 (drop-in), jenkins.service.j2 (offline)
  jenkins_agent/               play 3: user jenkins + authorized_keys
credentials/, bundle/          sinh ra, gitignore
```

## Biến chính (`group_vars/all.yml`)

| Biến | Mặc định | |
|---|---|---|
| `jenkins_install_source` | `online` | `online` / `offline` |
| `jenkins_version` | `2.580.2` | version war trong bundle (offline) |
| `jenkins_plugins` | 6 plugin | plugin cần có (dependency tự kéo theo) |
| `jenkins_http_port` | `8080` | |
| `jenkins_controller_executors` | `2` | chỉ áp dụng khi standalone |
| `jenkins_agent_executors` / `_labels` | `2` / `linux` | ghi đè được từng host |
| `jenkins_agent_address` | IP nội bộ agent | controller SSH vào địa chỉ này; khác mạng → đặt IP public |
| `jenkins_agent_ssh_port` | `ansible_port` hoặc 22 | port SSH controller → agent |
| `jenkins_bundle_arches` | `[x64]` | kiến trúc CPU cần có trong bundle |

## Giới hạn

- Online chỉ chạy trên Ubuntu/Debian có gói `openjdk-21-jre-headless` (Ubuntu 22.04+, Debian 13+). **Debian 12 chỉ có Java 17**, nên phải dùng offline hoặc đặt `jenkins_java_package`.
- Offline: bundle không chứa gói OS. Bộ cài thử cài `git` và `fontconfig` qua package manager (nếu VM có mirror nội bộ). Nếu không được: agent thiếu git chỉ bị **cảnh báo**, còn controller thiếu fontconfig thì bộ cài **dừng**, vì Jenkins không khởi động được nếu không có font. Image tối giản như Debian 12 trên GCE không có sẵn fontconfig.
- Bộ cài chỉ **thêm** plugin, không gỡ plugin. Muốn nâng thì dùng `jenkins_upgrade` (xem bảng thao tác).
- Không hỗ trợ đổi một máy đang cài online sang offline (hoặc ngược lại): war và unit của hai kiểu cài sẽ đè nhau. Muốn đổi thì cài lên máy mới.
- Bỏ agent khỏi inventory thì node và known_hosts trên controller được dọn, nhưng `authorized_keys` trên máy agent cũ vẫn còn, vì bộ cài không còn quản lý máy đó.
- Offline: mỗi bản JRE nằm ở `/opt/java/<tên bản>`, còn `/opt/java/jre-21` là symlink trỏ tới bản đang dùng (và `/usr/local/bin/java` trỏ vào đó). Khi đổi JRE, agent đang chạy vẫn giữ bản cũ cho tới lần kết nối lại. Bản cũ không bị xoá, xoá tay khi không còn dùng.
- Firewall (port 8080, SSH controller → agent) không nằm trong bộ cài.
