# `shared/` — phần chung của 3 team

Ansible chia 3 team, mỗi team một thư mục và **không thấy biến hay role của nhau**:

| Team | Thư mục | Lo |
|---|---|---|
| network | `../network/` | 2 firewall, VPN, bastion, DNS/NTP mọi VM, Squid, vùng biên (HAProxy + WAF) |
| platform | `../platform/` | K8s, addon, Harbor + S3, app, bảo mật cluster, Prometheus, backup |
| observability | `../observability/` | SIEM trên siem-01, bản sao log, agent log/audit/Wazuh mọi máy |

Thứ mà **một team cung cấp, team khác dùng** thì nằm ở đây. Team nào chạy cũng đọc thư mục này.

## Có gì trong này

| File | Nội dung | Khi nào sửa |
|---|---|---|
| `inventory/hosts.yml` | **Máy, nhóm, IP, vùng, VPN, VIP/Gateway** — viết tay, nguồn duy nhất của mọi IP (tofu và script cũng đọc file này) | thêm/đổi máy, chuyển nơi chạy |
| `inventory/group_vars/all/contract.yml` | **Hợp đồng**: biến team này cung cấp cho team khác (IP dịch vụ, Gateway, cổng syslog/Wazuh, Harbor, proxy, CA, cert vùng biên), chia theo team cung cấp | đổi giao diện giữa các team → cả 3 team duyệt |
| `inventory/group_vars/all/paths.yml` | thư mục trên máy admin (`lab_out` = `out/`), cách SSH xuyên jump-01 | hiếm khi |
| `inventory/group_vars/linux.yml` | user SSH của mọi VM | hiếm khi |
| `inventory/host_vars/<máy>.yml` | sự thật về 1 máy mà team khác cần (máy tự ra Internet, user dịch vụ, file log) | thêm dịch vụ lên máy đó |

**Không có ở đây**: biến chỉ một team dùng (ở `<team>/group_vars/`), role (ở `<team>/roles/`).

## Hai team trao đổi thế nào

1. **Qua biến** trong `contract.yml` — vd. observability công bố `mon_ip` + `mon_syslog_port`, network đọc để mở luật firewall và
   cấu hình firewall gửi syslog về đó.
2. **Qua file** trong `out/` khi một team tạo ra thứ team khác cần — vd. platform ký cert vùng biên, ghi `edge_tls_file`;
   network đọc file đó cài lên HAProxy. Không team nào gọi playbook hay `hostvars` của team khác.
3. **Thứ tự** giữa các team (ai chạy trước) nằm ở `lab.sh cluster`, không nằm ở đây.

## Thêm / đổi một biến dùng chung

1. Biến có thật sự được **từ 2 team trở lên** dùng không? Không → để ở `<team>/group_vars/` của team đó.
2. Đặt vào đúng mục "**<team> cung cấp**" trong `contract.yml`, ghi chú `→ team nào dùng`.
3. Giá trị là IP → lấy từ inventory (`hostvars[groups['infra'][0]].ansible_host`, `zones.lan.fw`, `api_vip`…), không ghi số.
4. `make lint validate` rồi mở PR cho cả 3 team duyệt.

## `inventory/`

```
inventory/
├── hosts.yml            # VIẾT TAY: máy theo nhóm vai trò (ansible_host, zone…) + all.vars (vùng, VPN, VIP, Gateway, card mạng VM…)
├── provisioned.yml      # (nếu có) bộ tạo máy ghi IP public sau khi tạo máy — không commit
├── group_vars/          # biến chung (contract.yml, paths.yml, linux.yml) — nằm CẠNH inventory nên team nào chạy cũng thấy
└── host_vars/           # sự thật về từng máy mà team khác cần (edge-01, infra-01)
```

Ansible không quan tâm máy chạy ở đâu (GCP, on-prem…): **chuyển nơi chạy = sửa IP trong `hosts.yml`** (+ luật firewall
`../network/host_vars/` nếu topology đổi). Ví dụ on-prem đầy đủ: `docs/examples/onprem/`. Xem thử: `cd ansible && ansible-inventory --graph`.
