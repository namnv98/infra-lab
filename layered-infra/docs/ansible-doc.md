# Ansible — từng file làm gì

Thư mục `ansible/` của layered-infra. Chạy lệnh trong `ansible/` (đã có `ansible.cfg`); `out/<env>/` = thư mục bí mật/log của từng môi trường ở gốc dự án (không commit).
Ansible không biết máy do ai tạo (tofu, tay, hypervisor…): chỉ đọc `envs/<env>/plan.yml` (+ `provisioned.yml` nếu bộ tạo máy ghi ra).

```
ansible/
├── ansible.cfg                       # cấu hình Ansible: inventory mặc định (gcp), roles_path, SSH keepalive, log ra out/logs/ansible.log
├── .ansible-lint                     # luật ansible-lint của dự án (bỏ các luật thuần phong cách)
├── requirements.yml                  # collection cần cài (ansible-galaxy collection install -r requirements.yml), đã ghim phiên bản
├── site.yml                          # TOÀN BỘ quy trình dựng theo thứ tự, mỗi bước 1 tag (--tags network, --tags security…)
│
├── 00-firewall-bootstrap.yml         # [bootstrap] lần đầu: nạp config 2 firewall (GCP console / on-prem USB), dựng VPN, bật VPN
├── 10-network.yml                    # [network] luật/NAT/DNS 2 firewall, jump server, DNS+NTP cho mọi VM
├── 20-kubernetes.yml                 # [kubernetes] containerd, kubeadm, master (kube-vip), worker, Cilium
├── 30-cluster-addons.yml             # [addons] Helm, chứng chỉ kubelet, MetalLB, Gateway API, cert-manager, 2 Gateway, metrics-server, StorageClass
├── 40-shared-services.yml            # [services] Harbor + Squid + S3 Garage trên infra-01; node kéo image qua Harbor
├── 50-apps-edge.yml                  # [apps] app demo + HAProxy/WAF trên edge-01
├── 60-security.yml                   # [security] siết apiserver, PSA, LimitRange/Quota, Kyverno, NetworkPolicy mọi namespace, kube-bench, backup etcd
├── 70-observability.yml              # [observability] metrics: Prometheus · siem: Loki/Alloy/Grafana, syslog, auditd, Wazuh
├── 80-backup.yml                     # [backup] Velero (cả dữ liệu volume, node-agent) → S3 trên infra-01
├── ops-harbor-prewarm.yml            # [prewarm] nạp cache Harbor bằng mọi image đang chạy (trước khi khoá đường ra Internet)
├── ops-etcd-restore.yml              # chạy tay: KHÔI PHỤC etcd từ snapshot (phá huỷ thay đổi sau snapshot)
├── ops-upgrade-cluster.yml           # chạy tay: NÂNG CẤP K8s lên k8s_version (snapshot etcd, kubeadm upgrade, drain từng node)
│
├── inventories/
│   ├── plan_inventory.py             # sinh inventory từ envs/<env>/plan.yml (qua scripts/plan.py): nhóm theo vai trò + vùng, ansible_host, biến `plan`, `lab_env`
│   ├── gcp/                          # MÔI TRƯỜNG GCP (đang chạy, mặc định)
│   │   ├── inventory.py              #   symlink → ../plan_inventory.py (đọc envs/gcp/plan.yml)
│   │   └── host_vars/
│   │       ├── firewall-edge-01.yml  #   luật firewall biên (WAN, VPN, DMZ), NAT ra Internet, IP VPN riêng
│   │       └── firewall-core-01.yml  #   luật firewall core (DMZ→trong, LAN, MGMT)
│   └── onprem/                       # MÔI TRƯỜNG ON-PREM (bản mẫu) — cùng cấu trúc như gcp/
│       ├── README.md                 #   khác GCP ở đâu, đã làm gì, còn thiếu gì
│       ├── inventory.py              #   symlink → ../plan_inventory.py (đọc envs/onprem/plan.yml: VLAN + transit, 3 master)
│       └── host_vars/                #   luật 2 firewall (biên: lan=transit, opt1=DMZ · core: wan=transit)
│
├── group_vars/                       # BIẾN DÙNG CHUNG mọi môi trường (giá trị IP đều lấy từ plan.yml)
│   ├── all/
│   │   ├── versions.yml              #   MỌI phiên bản phần mềm (K8s, Cilium, Harbor…)
│   │   ├── network.yml               #   tên dễ dùng cho IP trong plan: svc_ip, mon_ip, jump_ip, api_vip, proxy_url, proxy_no…
│   │   ├── paths.yml                 #   đường dẫn trên máy admin (lab_root, lab_out = out/<env>), SSH xuyên jump-01
│   │   ├── platform.yml              #   đặc thù máy từ plan.yml: card mạng, dhcp/static, NTP (node.*), IP public của biên (public.*)
│   │   ├── kubernetes.yml            #   dải pod/service, master đầu tiên, namespace PSA restricted, nơi lưu + số bản backup etcd
│   │   ├── services.yml              #   Harbor (proxy cache), Squid (tên miền được phép), biến proxy, mở egress tạm
│   │   ├── observability.yml         #   cổng syslog/Wazuh, thời gian giữ log, SMTP + email nhận cảnh báo
│   │   ├── edge.yml                  #   WAF: mức paranoia, ngưỡng điểm chặn (anomaly)
│   │   └── secrets.yml               #   MỌI mật khẩu: tự sinh lần đầu vào out/<env>/, lần sau đọc lại
│   ├── firewalls.yml                 # 2 OPNsense: gọi API trên máy admin, alias dùng chung, bản ghi DNS nội bộ
│   ├── linux.yml                     # user SSH (ubuntu) cho mọi VM
│   └── zone_dmz.yml, zone_lan.yml, zone_mgmt.yml   # zone_fw = firewall làm DNS/NTP của vùng đó
│
├── host_vars/                        # BIẾN RIÊNG TỪNG MÁY, dùng chung mọi môi trường
│   ├── edge-01.yml                   #   user dịch vụ auditd theo dõi (haproxy)
│   └── infra-01.yml                  #   user dịch vụ (proxy) + file log ứng dụng gửi về SIEM (Squid)
│
└── roles/                            # mỗi role: tasks/ (việc) · templates/ (file cấu hình .j2) · defaults/ (biến riêng) · handlers/ (restart)
    ├── base/                         # MỌI VM
    │   ├── network/                  #   DNS + NTP trỏ về firewall của vùng (netplan, chrony)
    │   ├── quiet_os/                 #   tắt dịch vụ ồn của image (snapd, agent Google) tránh báo động giả
    │   └── egress_client/            #   apt/containerd đi Internet qua Squid, kéo image qua Harbor
    ├── network/
    │   ├── opnsense/                 #   cấu hình OPNsense qua REST API
    │   │   ├── tasks/main.yml        #     alias, Virtual IP, luật (thêm/sửa/xoá theo mô tả), bật/tắt luật mặc định
    │   │   ├── tasks/wireguard.yml   #     VPN WireGuard (chỉ firewall biên)
    │   │   └── tasks/full.yml        #     port forward, Source NAT, DNS nội bộ (Unbound), syslog, xoá luật BOOTSTRAP
    │   └── edge_lb_waf/              #   edge-01: HAProxy (TLS, LB) → WAF ModSecurity + OWASP CRS → Gateway public
    ├── k8s/
    │   ├── node_prep/                #   kernel module, sysctl, tắt swap, cài kubelet/kubeadm/kubectl
    │   ├── containerd/               #   container runtime
    │   ├── control_plane/            #   main.yml chọn: init.yml (master đầu) hoặc join.yml (master sau)
    │   ├── kube_vip/                 #   VIP cho API server (gọi từ control_plane)
    │   ├── worker/                   #   join worker
    │   ├── kubelet_csr_approver/     #   tự duyệt CSR chứng chỉ phục vụ của kubelet (tên + IP node khớp)
    │   ├── kubelet_tls/              #   kubelet dùng chứng chỉ do CA cluster ký (serverTLSBootstrap), quyền file 600
    │   ├── metrics_server/           #   kubectl top, HPA (TLS kiểm chứng 2 chiều, cert từ cert-manager)
    │   ├── storage/                  #   StorageClass "standard" mặc định (local-path-provisioner)
    │   ├── cilium/                   #   CNI
    │   ├── helm/                     #   helm + thư viện Python kubernetes trên master
    │   ├── metallb/                  #   IP cho Service LoadBalancer (2 pool public/internal)
    │   ├── gateway_api/              #   CRD Gateway API, bật Gateway trong Cilium
    │   ├── cert_manager/             #   CA riêng của lab, cấp cert TLS
    │   └── gateways/                 #   Gateway public (.200) và internal (.210)
    ├── services/                     # TRÊN infra-01
    │   ├── harbor/                   #   registry + proxy cache Docker Hub/quay/ghcr…
    │   ├── squid/                    #   proxy đi ra có allowlist tên miền
    │   └── s3_garage/                #   kho S3 nội bộ cho Velero
    ├── security/
    │   ├── bastion/                  #   jump-01: siết SSH, ghi lại lệnh gõ trong phiên (pam_tty_audit)
    │   ├── apiserver/                #   audit log, mã hoá Secret, tắt profiling
    │   ├── pod_security/             #   Pod Security Admission (restricted cho namespace app)
    │   ├── resource_policy/          #   LimitRange (mặc định + trần) + ResourceQuota cho namespace app
    │   ├── kyverno/                  #   policy: app chỉ chạy image từ Harbor; bắt buộc requests/limits, cấm :latest
    │   ├── netpol/                   #   CiliumNetworkPolicy mặc định chặn mọi namespace (trừ kube-system) + mở đúng luồng
    │   └── kube_bench/               #   chấm điểm CIS Benchmark; ngoại lệ có lý do ở defaults (kube_bench_accepted)
    ├── observability/
    │   ├── siem/                     #   siem-01: Loki, Alloy (nhận syslog), Grafana (dashboard, cảnh báo email), Mailpit, Wazuh manager
    │   ├── loki_replica/             #   bản sao Loki trên infra-01 (dùng lại loki.yaml của siem)
    │   ├── log_forwarder/            #   rsyslog mọi VM → siem-01
    │   ├── auditd/                   #   luật auditd (danh tính, persistence, user dịch vụ chạy lệnh)
    │   ├── wazuh_agent/              #   Wazuh agent → manager trên siem-01
    │   └── prometheus/               #   Prometheus + node-exporter + kube-state-metrics, route qua Gateway internal
    ├── backup/
    │   ├── etcd/                     #   etcdctl + script snapshot etcd hằng ngày (systemd timer)
    │   └── velero/                   #   Velero backup namespace/app + dữ liệu volume → S3 Garage
    └── apps/
        └── whoami/                   #   app demo (image qua Harbor) sau Gateway public
```
