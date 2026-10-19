# Ansible — từng file làm gì

Thư mục `ansible/` của layered-infra. Chạy lệnh trong `ansible/` (đã có `ansible.cfg`); `out/` = thư mục bí mật/log ở gốc dự án (không commit).
Ansible không biết máy do ai tạo hay chạy ở đâu (tofu, tay, GCP, on-prem…): chỉ đọc **một** inventory viết tay `shared/inventory/hosts.yml`
(+ `provisioned.yml` nếu bộ tạo máy ghi IP public). Chuyển nơi chạy = sửa IP trong `hosts.yml` (ví dụ on-prem: `docs/examples/onprem/`).

## Chia theo team

Mỗi team một thư mục, có `site.yml`, `group_vars/` và `roles/` riêng. Ansible chỉ nạp `group_vars/` và tìm `roles/` **cạnh
playbook đang chạy**, và `ansible.cfg` không đặt `roles_path` — nên playbook của team này không gọi được role, không đọc được biến
của team khác. Thứ chung nằm ở `shared/inventory/` (biến chung đặt cạnh inventory, nên team nào chạy cũng thấy):

- **Hợp đồng** = `shared/inventory/hosts.yml` (máy, IP, vùng) + `shared/inventory/group_vars/all/contract.yml` (biến team này cung cấp cho team khác:
  `mon_ip` + `mon_syslog_port`, `gateways`, `harbor_host`, `proxy_url`/`egress_env`, `egress_temp_open`…). Sửa hợp đồng = cả 3 team duyệt.
- **Trao đổi qua file** trong `out/` khi một team tạo ra thứ team khác cần: platform ký cert vùng biên → `edge-tls.pem` → network
  cài lên HAProxy. Không team nào gọi `hostvars` của play thuộc team khác.
- **Thứ tự giữa các team**: `lab.sh cluster` (network → platform → network biên + khoá egress → platform ‖ observability → backup).
  Thứ tự trong một team: `<team>/site.yml`. Chạy riêng 1 team: `make <team> ARGS='--tags …'` (= `./lab.sh <team> …`).
- **Ngoại lệ có chủ đích**: observability cài agent (rsyslog, auditd, Wazuh) lên mọi máy Linux; network cấu hình DNS/NTP + mạng của
  mọi VM (`node_network`) và chạy Squid trên infra-01 (máy của platform). Mỗi role chỉ đụng file/dịch vụ của chính nó.

```
ansible/
├── ansible.cfg                       # inventory = shared/inventory/, KHÔNG roles_path, SSH keepalive, log ra out/logs/ansible.log
├── .ansible-lint                     # luật ansible-lint của dự án (bỏ các luật thuần phong cách)
├── requirements.yml                  # collection cần cài (ansible-galaxy collection install -r requirements.yml), đã ghim phiên bản
│
├── shared/                           # HỢP ĐỒNG giữa 3 team — mọi team đều đọc, cả 3 cùng duyệt khi sửa (đọc shared/README.md)
│   ├── README.md                     #   có gì, hai team trao đổi thế nào, cách thêm biến dùng chung
│   ├── inventory/
│   │   ├── hosts.yml                 #   VIẾT TAY: máy theo nhóm vai trò (ansible_host, zone…) + vùng, VPN, VIP, Gateway, card mạng VM — nguồn duy nhất của IP
│   │   ├── provisioned.yml           #   (nếu có) IP public do bộ tạo máy ghi — không commit
│       ├── group_vars/               #   biến chung, nằm cạnh inventory nên team nào chạy cũng thấy
│       │   ├── all/
│       │   │   ├── contract.yml      #     biến team này cung cấp cho team khác, chia theo team cung cấp (proxy, Gateway, Harbor, CA, cert biên, siem-01)
│       │   │   └── paths.yml         #     thư mục trên máy admin (lab_root, lab_out = out/), SSH xuyên jump-01
│       │   └── linux.yml             #     user SSH (ubuntu) cho mọi VM
│       └── host_vars/                #   sự thật về từng máy mà nhiều team cần
│           ├── edge-01.yml           #     ra thẳng Internet (egress_env: {}), user dịch vụ auditd theo dõi (haproxy)
│           └── infra-01.yml          #     ra thẳng Internet, user dịch vụ (proxy) + file log ứng dụng gửi về SIEM (Squid)
│
├── network/                          # TEAM NETWORK — tag: bootstrap (never) · firewall · edge
│   ├── site.yml
│   ├── 00-firewall-bootstrap.yml     # [bootstrap] lần đầu: chờ API biên qua IP public, dựng VPN, bật VPN, chờ API core
│   ├── 10-firewall.yml               # [firewall] luật/NAT/DNS/syslog 2 firewall, jump server, DNS+NTP cho mọi VM, Squid trên infra-01
│   ├── 20-edge.yml                   # [edge] HAProxy + WAF trên edge-01 (cert vùng biên do platform ghi ra out/edge-tls.pem)
│   ├── host_vars/firewall-*.yml      # luật từng firewall — biên: WAN/VPN/DMZ + NAT · core: DMZ/LAN/MGMT
│   ├── group_vars/
│   │   ├── all/network.yml           #   zone_fw (DNS/NTP của máy theo vùng), VPN, WAF, tên miền Squid cho phép
│   │   └── firewalls.yml             #   2 OPNsense: gọi API trên máy admin, alias dùng chung, bản ghi DNS nội bộ
│   └── roles/
│       ├── opnsense/                 #   cấu hình OPNsense qua REST API
│       │   ├── tasks/main.yml        #     alias, Virtual IP, luật (thêm/sửa/xoá theo mô tả), bật/tắt luật mặc định
│       │   ├── tasks/wireguard.yml   #     VPN WireGuard (chỉ firewall biên)
│       │   └── tasks/full.yml        #     port forward, Source NAT, DNS nội bộ (Unbound), syslog → siem-01, xoá luật BOOTSTRAP
│       ├── bastion/                  #   jump-01: siết SSH, ghi lại lệnh gõ trong phiên (pam_tty_audit)
│       ├── node_network/             #   mọi VM: IP tĩnh/MTU (nếu node_network_mode: static), DNS + NTP trỏ về firewall của vùng
│       ├── squid/                    #   infra-01: proxy đi ra có allowlist tên miền
│       └── edge_lb_waf/              #   edge-01: HAProxy (TLS, LB) → WAF ModSecurity + OWASP CRS → Gateway public
│
├── platform/                         # TEAM PLATFORM — tag: kubernetes (coredns) · addons · services · apps · prewarm · security · metrics · backup
│   ├── site.yml
│   ├── 20-kubernetes.yml             # [kubernetes] containerd, kubeadm, master (kube-vip), worker, Cilium; [coredns] CoreDNS đọc lại DNS khi node đổi DNS
│   ├── 30-cluster-addons.yml         # [addons] Helm, chứng chỉ kubelet, MetalLB, Gateway API, cert-manager, 2 Gateway, metrics-server, StorageClass
│   ├── 40-shared-services.yml        # [services] Harbor + S3 Garage trên infra-01; node kéo image qua Harbor, apt qua Squid
│   ├── 50-apps.yml                   # [apps] app demo + cert vùng biên → out/edge-tls.pem (cho network)
│   ├── 60-security.yml               # [security] siết apiserver, PSA, LimitRange/Quota, Kyverno, NetworkPolicy mọi namespace, kube-bench, backup etcd
│   ├── 70-metrics.yml                # [metrics] Prometheus + node-exporter + kube-state-metrics
│   ├── 80-backup.yml                 # [backup] Velero (cả dữ liệu volume, node-agent) → S3 trên infra-01
│   ├── ops-harbor-prewarm.yml        # [prewarm] nạp cache Harbor bằng mọi image đang chạy (trước khi khoá đường ra Internet)
│   ├── ops-etcd-restore.yml          # chạy tay: KHÔI PHỤC etcd từ snapshot (phá huỷ thay đổi sau snapshot)
│   ├── ops-upgrade-cluster.yml       # chạy tay: NÂNG CẤP K8s lên k8s_version (snapshot etcd, kubeadm upgrade, drain từng node)
│   ├── group_vars/all/
│   │   ├── versions.yml              #   phiên bản K8s, Cilium, Helm chart, Harbor…
│   │   ├── kubernetes.yml            #   dải pod/service, VIP API, MetalLB, master đầu tiên, PSA restricted, backup etcd, kubeconfig trên máy admin
│   │   ├── services.yml              #   Harbor: proxy cache từng registry
│   │   └── secrets.yml               #   mật khẩu Harbor, key S3/Velero, Garage: tự sinh lần đầu vào out/, lần sau đọc lại
│   └── roles/                        # mỗi role: tasks/ · templates/ (.j2) · defaults/ · handlers/
│       ├── base/egress_client/       #   tin CA lab, apt qua Squid, containerd kéo image qua Harbor
│       ├── k8s/
│       │   ├── node_prep/            #   kernel module, sysctl, tắt swap, cài kubelet/kubeadm/kubectl
│       │   ├── containerd/           #   container runtime
│       │   ├── control_plane/        #   main.yml chọn: init.yml (master đầu) hoặc join.yml (master sau)
│       │   ├── kube_vip/             #   VIP cho API server (gọi từ control_plane)
│       │   ├── worker/               #   join worker
│       │   ├── kubelet_csr_approver/ #   tự duyệt CSR chứng chỉ phục vụ của kubelet (tên + IP node khớp)
│       │   ├── kubelet_tls/          #   kubelet dùng chứng chỉ do CA cluster ký (serverTLSBootstrap), quyền file 600
│       │   ├── metrics_server/       #   kubectl top, HPA (TLS kiểm chứng 2 chiều, cert từ cert-manager)
│       │   ├── storage/              #   StorageClass "standard" mặc định (local-path-provisioner)
│       │   ├── cilium/               #   CNI
│       │   ├── helm/                 #   helm + thư viện Python kubernetes trên master
│       │   ├── metallb/              #   IP cho Service LoadBalancer (2 pool public/internal)
│       │   ├── gateway_api/          #   CRD Gateway API, bật Gateway trong Cilium
│       │   ├── cert_manager/         #   CA riêng của lab, cấp cert TLS
│       │   ├── gateways/             #   Gateway public (.200) và internal (.210)
│       │   └── prometheus/           #   Prometheus + node-exporter + kube-state-metrics, route qua Gateway internal
│       ├── services/                 # TRÊN infra-01
│       │   ├── harbor/               #   registry + proxy cache Docker Hub/quay/ghcr…
│       │   └── s3_garage/            #   kho S3 nội bộ cho Velero
│       ├── security/
│       │   ├── apiserver/            #   audit log, mã hoá Secret, tắt profiling
│       │   ├── pod_security/         #   Pod Security Admission (restricted cho namespace app)
│       │   ├── resource_policy/      #   LimitRange (mặc định + trần) + ResourceQuota cho namespace app
│       │   ├── kyverno/              #   policy: app chỉ chạy image từ Harbor; bắt buộc requests/limits, cấm :latest
│       │   ├── netpol/               #   CiliumNetworkPolicy mặc định chặn mọi namespace (trừ kube-system) + mở đúng luồng
│       │   └── kube_bench/           #   chấm điểm CIS Benchmark; ngoại lệ có lý do ở defaults (kube_bench_accepted)
│       ├── backup/
│       │   ├── etcd/                 #   etcdctl + script snapshot etcd hằng ngày (systemd timer)
│       │   └── velero/               #   Velero backup namespace/app + dữ liệu volume → S3 Garage
│       └── apps/
│           └── whoami/               #   app demo (image qua Harbor) sau Gateway public
│
└── observability/                    # TEAM OBSERVABILITY — chạy cả file (song song với platform security,metrics)
    ├── site.yml                      # bản sao log trên infra-01 → siem-01 → rsyslog, auditd, Wazuh agent mọi máy Linux
    ├── group_vars/all/
    │   ├── observability.yml         #   thời gian giữ log, cổng Wazuh, SMTP + email nhận cảnh báo
    │   ├── versions.yml              #   Wazuh, image Loki/Alloy/Grafana/Mailpit (kéo qua Harbor)
    │   └── secrets.yml               #   mật khẩu Grafana, SMTP thật
    └── roles/
        ├── siem/                     #   siem-01: Loki, Alloy (nhận syslog), Grafana (dashboard, cảnh báo email), Mailpit, Wazuh manager
        ├── loki_replica/             #   bản sao Loki trên infra-01 (dùng lại loki.yaml của siem)
        ├── log_forwarder/            #   rsyslog mọi VM → siem-01
        ├── auditd/                   #   luật auditd (danh tính, persistence, user dịch vụ chạy lệnh)
        ├── quiet_os/                 #   tắt dịch vụ ồn của image (snapd, agent Google) tránh báo động giả
        └── wazuh_agent/              #   Wazuh agent → manager trên siem-01
```
