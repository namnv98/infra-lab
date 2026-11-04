# Networking trong Kubernetes — từ dưới lên

Ghi chú cá nhân, dựa trên ý tưởng của bài *"Nobody Understands Kubernetes Networking"* (msalinas92), viết lại cho đúng kỹ thuật và đi sâu tới tầng gói tin. Mỗi mục đi theo thứ tự: **mô hình** (cái gì, vì sao) → **cơ chế** (gói tin đi thế nào) → **lab** (cụ thể trong `layered-infra`) → **debug**.

Ý tưởng xuyên suốt: mỗi tầng giải quyết một vấn đề mà tầng bên dưới còn để ngỏ, và mỗi tầng đặt một thứ ổn định phía trước một thứ không đứng yên.

## Mục lục

- **Phần I — Nền tảng: pod có IP và nói chuyện được với nhau**
  - [1. Bản đồ: ba dải IP, ba thế giới](#1-bản-đồ-ba-dải-ip-ba-thế-giới)
  - [2. CNI: thứ nằm bên dưới tất cả](#2-cni-thứ-nằm-bên-dưới-tất-cả)
  - [3. Pod: một network namespace riêng](#3-pod-một-network-namespace-riêng)
  - [4. Pod-to-pod: cùng node và khác node](#4-pod-to-pod-cùng-node-và-khác-node)
- **Phần II — Đưa traffic tới đúng chỗ**
  - [5. Service: IP ảo và ai đứng sau nó](#5-service-ip-ảo-và-ai-đứng-sau-nó)
  - [6. Traffic từ ngoài vào: NodePort, LoadBalancer, source IP](#6-traffic-từ-ngoài-vào-nodeport-loadbalancer-source-ip)
  - [7. Ingress và Gateway API: tầng L7](#7-ingress-và-gateway-api-tầng-l7)
  - [8. DNS](#8-dns)
- **Phần III — Kiểm soát và bảo mật**
  - [9. NetworkPolicy](#9-networkpolicy)
  - [10. mTLS và Service Mesh](#10-mtls-và-service-mesh)
  - [11. Bảo mật mạng: những lỗ mặc định](#11-bảo-mật-mạng-những-lỗ-mặc-định)
- **Phần IV — Vận hành**
  - [12. Networking của control plane](#12-networking-của-control-plane)
  - [13. Egress: traffic ra khỏi cluster](#13-egress-traffic-ra-khỏi-cluster)
  - [14. Giới hạn của datapath và hiệu năng](#14-giới-hạn-của-datapath-và-hiệu-năng)
  - [15. IPv6 và dual-stack](#15-ipv6-và-dual-stack)
  - [16. Nhiều mạng, nhiều cluster](#16-nhiều-mạng-nhiều-cluster)
- **Phần V — Tổng hợp**
  - [17. Vòng đời của một request trong lab](#17-vòng-đời-của-một-request-trong-lab)
  - [18. Hộp đồ nghề debug](#18-hộp-đồ-nghề-debug)
  - [19. Tổng kết](#19-tổng-kết)

---

# Phần I — Nền tảng: pod có IP và nói chuyện được với nhau

## 1. Bản đồ: ba dải IP, ba thế giới

Một cluster luôn có (ít nhất) ba dải địa chỉ không được chồng lấn nhau:

| Dải                            | Ai cấp                           | Có "thật" không                               | Lab (`group_vars/all/kubernetes.yml`) |
|--------------------------------|----------------------------------|-----------------------------------------------|---------------------------------------|
| **Node**                       | hạ tầng (DHCP / IP tĩnh / cloud) | thật — gắn trên NIC của VM                    | theo `envs/<env>/plan.yml`            |
| **Pod** (`--pod-network-cidr`) | CNI (IPAM)                       | thật — gắn trên interface trong netns của pod | `10.244.0.0/16`                       |
| **Service** (`--service-cidr`) | kube-apiserver                   | **ảo** — không gắn vào interface nào          | `10.96.0.0/12`                        |

Thêm một dải thứ tư cho traffic từ ngoài vào: **IP LoadBalancer** (lab: `metallb_pools` trong `plan.yml`) — phải nằm trong subnet của node để ARP hoạt động (MetalLB L2).

Mô hình mạng Kubernetes đặt ra ba yêu cầu, mọi CNI phải thoả:

1. Pod gọi được mọi pod khác trên mọi node **không qua NAT**.
2. Agent trên node (kubelet…) gọi được mọi pod trên node đó.
3. IP mà pod tự thấy là IP mà pod khác thấy nó.

Kubernetes core **không** hiện thực ba điều này — nó chỉ đặt ra hợp đồng. CNI hiện thực (mục 2).

---

## 2. CNI: thứ nằm bên dưới tất cả

### Spec

CNI là một **spec + bộ binary**, không phải daemon bắt buộc:

- Cấu hình: `/etc/cni/net.d/*.conflist` (file đầu tiên theo thứ tự tên được dùng).
- Binary: `/opt/cni/bin/` (cilium-cni, bridge, host-local, portmap, loopback…).
- Container runtime (containerd / CRI-O — **không phải kubelet** kể từ khi bỏ dockershim) gọi binary với lệnh `ADD` / `DEL` / `CHECK` (spec 1.1 thêm `GC`, `STATUS`), truyền đường dẫn netns qua biến môi trường, cấu hình qua stdin; plugin trả về IP đã cấp qua stdout.
- Plugin có thể xâu chuỗi (`plugins: [...]` trong conflist): một plugin tạo interface, plugin sau thêm port mapping, bandwidth…

Luồng tạo pod:

```text
kubelet ─CRI RunPodSandbox─► containerd ─ tạo netns + pause
                                         └─ CNI ADD ─► cilium-cni ─► cilium-agent: tạo veth, cấp IP, nạp eBPF
kubelet ─CRI CreateContainer×N─► container join netns đó
```

### IPAM — ai quyết định IP

- `host-local`: mỗi node có một dải (`node.spec.podCIDR`), cấp tuần tự, lưu trên đĩa node.
- **Lab:** Cilium `ipam.mode=kubernetes` → dùng `podCIDR` do kube-controller-manager chia từ `10.244.0.0/16`. Mặc định mỗi node một `/24` → tối đa **256 node**, mỗi node ~254 IP (đủ cho `maxPods` mặc định 110).
- Cilium `cluster-pool` / Calico IPAM: tự chia dải theo block, linh hoạt hơn.
- Cloud (AWS VPC CNI, Azure CNI, GKE): pod nhận IP thật của VPC — native routing, nhưng tiêu thụ IP VPC rất nhanh.

### Cluster chưa có CNI

Kubelet báo `NetworkReady=false … cni plugin not initialized` → node `NotReady`; pod không phải hostNetwork (như CoreDNS) kẹt `ContainerCreating`/`Pending`. Chỉ static pod của control plane (hostNetwork) chạy được — đó là lý do kubeadm init xong vẫn phải cài CNI.

### CNI hiện đại làm nhiều hơn "cấp IP"

Cilium trong lab đảm nhận: CNI + IPAM, routing (VXLAN), **thay kube-proxy**, thực thi NetworkPolicy và CiliumNetworkPolicy, **Gateway API** (Envoy), quan sát (Hubble), và có thể mã hoá giữa node / mesh. Gần như cả stack trong ghi chú này chạy trên một datapath eBPF.

---

## 3. Pod: một network namespace riêng

### Mô hình

Trước đây nhiều app trên cùng server dùng chung IP nên tranh nhau port. Kubernetes cấp cho **mỗi pod** một IP riêng, nên các pod khác nhau cùng listen `:8080` thoải mái.

IP được cấp theo **pod**, không theo container. Khi tạo pod, runtime tạo một **network namespace** (giữ bởi container `pause`), rồi mọi container trong pod join vào namespace đó. Hệ quả:

- Các container trong một pod chung IP, chung bảng route, gọi nhau qua `localhost` — và **vẫn tranh port với nhau** (sidecar không được listen trùng port với app).
- `hostNetwork: true` thì pod dùng luôn netns của node: IP node, tranh port với mọi thứ trên node, và thường **không bị NetworkPolicy chi phối**.

### Cơ chế

Bên trong netns của pod thường chỉ có `lo` và `eth0`. `eth0` là một đầu của **cặp veth**; đầu kia nằm trong netns của node. Đầu bên node đi đâu tuỳ CNI:

- **Flannel / bridge plugin:** nối vào bridge `cni0`, node route cả `/24` của mình vào bridge.
- **Cilium (lab):** không có bridge. Đầu veth bên node tên `lxc…`, node có route `/32` cho từng pod, và chương trình eBPF gắn trên `lxc…` xử lý mọi gói ra/vào pod (policy, load-balance, encap).

Route mặc định trong pod trỏ về một gateway mà CNI quản lý; với Cilium đó là IP của `cilium_host` trên node.

### Debug

```bash
# Xem mạng từ bên trong pod (không cần công cụ trong image)
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
ip addr; ip route; ss -lntp

# Từ node: vào netns của một container
crictl inspect <container-id> | jq .info.pid    # lấy PID
nsenter -t <pid> -n ip addr
```

Pod không sống lâu: restart, reschedule, scale — mỗi pod mới một IP mới. Vì vậy cần Service (mục 5).

---

## 4. Pod-to-pod: cùng node và khác node

### Cùng node

Pod A → veth → netns node → route `/32` (Cilium) hoặc bridge (Flannel) → veth → Pod B. Không rời khỏi máy. Với Cilium, gói thường được eBPF chuyển thẳng từ veth này sang veth kia mà không đi qua toàn bộ stack IP của node.

### Khác node — hai cách

**Overlay (encapsulation)** — VXLAN hoặc Geneve:

```text
[ IP ngoài: nodeA → nodeB ][ UDP :8472 ][ VXLAN hdr ][ Ethernet trong ][ IP trong: podA → podB ][ payload ]
```

- Mạng bên dưới chỉ thấy gói UDP giữa hai node; không cần biết gì về `10.244.0.0/16`.
- Cilium mặc định dùng VXLAN trên UDP **8472** (chuẩn IANA là 4789; Geneve là 6081). Firewall giữa các node phải mở port này.
- Tốn **50 byte** (IPv4) cho header → **MTU của pod = MTU của node − 50**. Lab trên GCP: VPC MTU 1460 → pod 1410. Cilium tự dò MTU của `devices` và trừ overhead; nếu tự đặt sai, triệu chứng kinh điển: ping và request nhỏ chạy, TLS handshake / response lớn bị treo (gói vượt MTU bị drop, ICMP "fragmentation needed" bị chặn → PMTUD hỏng).

**Native routing** — không encap:

- Gói pod đi thẳng với IP pod; mạng phải biết `10.244.X.0/24` nằm sau node nào: route tĩnh, BGP (Calico, Cilium BGP control plane), hoặc route của cloud (GCP routes, AWS VPC CNI cấp luôn IP VPC cho pod).
- Không tốn header, dễ quan sát hơn, nhưng đòi hạ tầng mạng hợp tác.

> **Lab:** `cilium install` không đặt `routingMode` → mặc định **tunnel (VXLAN)**. `devices={{ node_interface }}` giới hạn Cilium chỉ gắn eBPF lên card đó.

### Traffic ra ngoài cluster

Pod gọi internet → gói rời node với **source = IP pod**, nhưng mạng ngoài không biết route về `10.244.x.x`. Nên CNI **masquerade (SNAT)** sang IP node khi đích nằm ngoài pod CIDR. Hệ quả: dịch vụ bên ngoài (database ngoài cluster, firewall) thấy IP **node**, không thấy IP pod — viết firewall rule theo IP node, hoặc dùng egress gateway nếu cần IP cố định.

### Debug

```bash
cilium status --verbose          # routing mode, KPR, MTU, health
cilium-health status             # kết nối node↔node, pod↔pod
tcpdump -ni <nic> udp port 8472  # thấy gói VXLAN giữa node
```

---

# Phần II — Đưa traffic tới đúng chỗ

## 5. Service: IP ảo và ai đứng sau nó

### Mô hình

**Service** cho một **ClusterIP** ổn định suốt đời Service, cộng một tên DNS (mục 8). Client gọi `ClusterIP:port`, gói tin được chuyển tới `podIP:targetPort` của một backend.

Service chọn backend bằng **selector** theo label. **EndpointSlice controller** liên tục ghi danh sách backend vào các object `EndpointSlice` (mỗi slice tối đa 100 endpoint mặc định). Mỗi endpoint có điều kiện:

- `ready` — pod Ready (qua readiness probe) và không đang terminating. Chỉ endpoint ready nhận traffic mới.
- `serving` / `terminating` — pod đang tắt nhưng vẫn phục vụ được; dùng để drain êm.

Service không có selector cũng hợp lệ: bạn tự tạo EndpointSlice trỏ tới IP bất kỳ (ví dụ database ngoài cluster).

### Cơ chế — không có proxy nào cả

ClusterIP **không gắn vào interface nào**; không có process nào listen trên nó (nên thường không ping được — chỉ cặp IP:port được khai báo mới được dịch). "Service" thực chất là **rule dịch địa chỉ** được lập trình sẵn trên **mọi node**.

**kube-proxy chế độ iptables** (phổ biến nhất khi không dùng eBPF):

```text
PREROUTING / OUTPUT (bảng nat)
  └─ KUBE-SERVICES
       └─ -d 10.96.12.34/32 -p tcp --dport 80 → KUBE-SVC-ABC123
            ├─ -m statistic --mode random --probability 0.333 → KUBE-SEP-1  (DNAT → 10.244.1.5:8080)
            ├─ -m statistic --mode random --probability 0.5   → KUBE-SEP-2  (DNAT → 10.244.2.7:8080)
            └─                                                 → KUBE-SEP-3  (DNAT → 10.244.3.9:8080)
```

- Chọn backend **ngẫu nhiên theo xác suất** (1/3, rồi 1/2 của phần còn lại, rồi phần cuối → đều nhau). Không phải round-robin, không biết tải.
- Quyết định chỉ xảy ra ở **gói đầu tiên** của kết nối; **conntrack** nhớ ánh xạ, các gói sau và gói trả lời được dịch ngược tự động. Hệ quả quan trọng: **kết nối dài (HTTP/2, gRPC, WebSocket, connection pool) dính cố định vào một pod** → scale thêm pod không chia tải cho kết nối cũ. Cần load-balance ở L7 (client-side gRPC LB, mesh, hoặc giới hạn tuổi kết nối).
- Chi phí rule tăng tuyến tính theo số Service × endpoint; cluster lớn chuyển sang **IPVS** (bảng hash trong kernel, nhiều thuật toán LB) hoặc **nftables** (chế độ mới, thay iptables).
- `sessionAffinity: ClientIP` ghim client vào một pod (theo IP nguồn, timeout mặc định 3 giờ).

**Cilium kube-proxy replacement (lab: `kubeProxyReplacement=true`, không có kube-proxy):**

- Service và backend lưu trong **eBPF map** (`cilium service list`).
- Với traffic xuất phát từ pod: **socket-level LB** — eBPF gắn vào cgroup hook `connect()`/`sendmsg()` đổi đích ClusterIP thành IP pod **ngay khi app mở socket**. Gói tin rời pod đã mang IP pod thật → không cần DNAT từng gói, không cần conntrack cho bước này. (`tcpdump` trong pod sẽ thấy IP backend, không thấy ClusterIP.)
- Với traffic từ ngoài vào NodePort/LoadBalancer: xử lý ở tc/XDP trên NIC, hỗ trợ Maglev (consistent hashing) và DSR.
- Lab đặt `k8sServiceHost={{ api_endpoint }}` vì không còn kube-proxy để dịch ClusterIP của `kubernetes.default` — Cilium phải nói chuyện thẳng với API server qua VIP (kube-vip) trước khi chính nó lập trình được Service.

### Vòng đời và drain

Khi pod bị xoá, hai việc xảy ra **song song, không đồng bộ**: kubelet gửi SIGTERM cho container, và EndpointSlice được cập nhật → kube-proxy/Cilium trên mọi node gỡ backend. Nếu app tắt nhanh hơn việc gỡ, vài request vẫn bị gửi tới pod đã chết → lỗi 502/connection refused lúc rolling update. Cách xử lý chuẩn: `preStop` sleep vài giây + app xử lý SIGTERM bằng cách ngừng nhận kết nối mới rồi đóng dần.

### Các loại Service — xếp chồng

- **ClusterIP** — chỉ trong cluster.
- **NodePort** = ClusterIP + một port (dải `30000–32767`) mở trên **mọi node**. Gói tới `nodeIP:nodePort` được DNAT sang một backend — có thể nằm ở node khác.
- **LoadBalancer** = NodePort + IP bên ngoài do một controller cấp (cloud-controller-manager trên cloud; **MetalLB** trong lab). Không có controller → `EXTERNAL-IP <pending>` mãi.
- **ExternalName** — chỉ là bản ghi DNS **CNAME**, không IP, không proxy, không áp được port mapping. Gọi HTTPS qua nó thì `Host`/SNI vẫn là tên nội bộ → hay lỗi certificate.
- **Headless** (`clusterIP: None`) — không IP ảo; DNS trả thẳng IP từng pod. Dùng cho StatefulSet và client tự load-balance (gRPC, driver database).

`internalTrafficPolicy: Local` buộc traffic nội bộ chỉ tới backend trên cùng node (ví dụ agent DaemonSet). `trafficDistribution: PreferClose` ưu tiên backend cùng zone để tránh phí traffic liên zone.

### Debug

```bash
kubectl get endpointslices -l kubernetes.io/service-name=<svc> -o wide
# Service không có endpoint? → selector sai label, hoặc pod chưa Ready
kubectl get pod -l <selector> -o wide

# kube-proxy iptables
iptables-save -t nat | grep <ClusterIP>
conntrack -L -d <ClusterIP>

# Cilium (lab)
kubectl -n kube-system exec ds/cilium -- cilium service list
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
```

---

## 6. Traffic từ ngoài vào: NodePort, LoadBalancer, source IP

### `externalTrafficPolicy` — đánh đổi quan trọng nhất ở biên

**`Cluster` (mặc định):** gói tới bất kỳ node nào cũng được chuyển tới backend bất kỳ, kể cả ở node khác. Để gói trả lời quay về đúng node (rồi về client), node nhận phải **SNAT source thành IP của chính nó** → **pod mất IP thật của client**. Thêm một hop mạng.

**`Local`:** node chỉ chuyển tới backend **trên chính nó**, không SNAT → pod thấy IP client thật. Node không có backend thì drop. Với LoadBalancer, Kubernetes cấp thêm `healthCheckNodePort` để load balancer bên ngoài chỉ gửi vào node có backend. Đánh đổi: tải có thể lệch (node có 1 pod nhận bằng node có 5 pod).

Cần IP client thật (log, rate limit, allow-list) mà không dùng `Local` → dùng `X-Forwarded-For` / PROXY protocol ở tầng L7, hoặc DSR (Cilium).

### MetalLB — "LoadBalancer" cho bare-metal (lab)

MetalLB không phải load balancer nằm trên đường dữ liệu; nó chỉ **cấp IP** và **làm cho mạng biết gửi IP đó tới node nào**. Phần dịch IP → pod vẫn là Cilium.

**Chế độ L2 (lab dùng — `L2Advertisement`, đã tắt FRR):**

- Với mỗi IP, các speaker bầu ra **một node duy nhất** trả lời ARP "IP này ở MAC của tôi". Toàn bộ traffic tới IP đó vào **một node** rồi mới được chia đi.
- Không thực sự cân bằng tải ở tầng mạng; băng thông bị giới hạn bởi một node.
- Node đó chết → node khác nhận, gửi **gratuitous ARP**; failover mất vài giây và phụ thuộc switch/client cập nhật ARP cache.
- Với `externalTrafficPolicy: Local`, chỉ node có backend mới được bầu.
- Cloud VPC (như GCP) thường **không truyền ARP tự do** giữa VM như switch L2 thật — L2 mode chạy được hay không tuỳ cách mạng được dựng (lab có OPNsense/VLAN riêng); nếu IP LB "không ping được" thì nghi ARP trước.

**Chế độ BGP:** mỗi node quảng bá IP LB tới router; router chia tải ECMP trên nhiều node — load balance thật, failover nhanh, nhưng cần router hỗ trợ BGP.

**kube-vip** trong lab làm việc tương tự (ARP) cho **VIP của API server** (`api_endpoint`), không phải cho Service.

---

## 7. Ingress và Gateway API: tầng L7

### Vì sao cần

Service LoadBalancer hoạt động ở **L4**: thấy IP/port, không đọc được HTTP. Không route theo host/path được, không terminate TLS được, và trên cloud thì mỗi Service một load balancer.

Tầng L7 đặt **một reverse proxy** (nginx, Envoy, HAProxy, Traefik…) làm điểm vào chung:

```text
client ─► IP LoadBalancer (MetalLB) ─► proxy L7 ─► route theo Host/path/header ─► pod backend
```

Chi tiết dễ nhầm: proxy thường gửi **thẳng tới IP pod** đọc từ EndpointSlice, **không đi qua ClusterIP** — để tự load-balance theo request (L7) thay vì theo kết nối, và hỗ trợ retry/sticky session. Bản thân proxy được public bằng **một** Service LoadBalancer.

### Ingress

- Spec chỉ có: host, path (`Exact`/`Prefix`/`ImplementationSpecific`), backend Service, TLS (Secret chứa cert).
- Mọi thứ khác — rewrite, redirect, timeout, canary, header — nằm trong **annotation** riêng từng controller; API server không validate, đổi controller là viết lại.
- `ingressClassName` chọn controller.
- Ingress API đã **đóng băng** (vẫn ổn định, không thêm tính năng). Dự án **ingress-nginx** được SIG Network thông báo ngừng bảo trì từ tháng 3/2026 — cluster mới nên dùng Gateway API.

### Gateway API

Là tập **CRD** cài riêng (lab: `roles/k8s/gateway_api` cài `standard-install.yaml`), được một controller hiện thực.

| Resource                                          | Scope     | Ai sở hữu               | Làm gì                                                                 |
|---------------------------------------------------|-----------|-------------------------|------------------------------------------------------------------------|
| `GatewayClass`                                    | cluster   | platform / nhà cung cấp | chọn controller (`controllerName`)                                     |
| `Gateway`                                         | namespace | cluster operator        | listener: port, protocol, hostname, TLS, `allowedRoutes`               |
| `HTTPRoute`, `GRPCRoute`, `TLSRoute`, `TCPRoute`… | namespace | team app                | match → filter → backend, gắn vào Gateway qua `parentRefs`             |
| `ReferenceGrant`                                  | namespace | chủ namespace đích      | cho phép tham chiếu chéo namespace (route → Service, Gateway → Secret) |

Ví dụ route có những thứ mà Ingress phải nhét vào annotation:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: shop, namespace: shop }
spec:
  parentRefs: [ { name: public, namespace: gateways } ]
  hostnames: [ "myapp.example.com" ]
  rules:
    - matches: [ { path: { type: PathPrefix, value: /shop } } ]
      filters:
        - type: URLRewrite
          urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } }
      backendRefs: # canary 90/10 — field thật, có validate
        - { name: shop-v1, port: 80, weight: 90 }
        - { name: shop-v2, port: 80, weight: 10 }
```

**TLS ở Gateway:**

- `mode: Terminate` — proxy giải mã bằng cert trong Secret (thường do cert-manager cấp/gia hạn), rồi gửi HTTP (hoặc HTTPS lại) tới backend. Proxy đọc được HTTP → route L7 được.
- `mode: Passthrough` (với `TLSRoute`) — proxy chỉ đọc **SNI** trong ClientHello để route, không giải mã; backend tự giữ cert.

> **Lab:** `gatewayClassName: cilium`. Với mỗi `Gateway`, Cilium tạo một Service LoadBalancer `cilium-gateway-<tên>` → MetalLB cấp IP; traffic được eBPF chuyển vào **Envoy chạy trên từng node** do Cilium quản lý, Envoy route theo HTTPRoute rồi gửi tới pod.

### Debug

Gateway API ghi trạng thái rất rõ — đọc `status.conditions` trước khi đoán:

```bash
kubectl get gateway -A                     # PROGRAMMED=True? ADDRESS có IP chưa?
kubectl describe httproute <r> -n <ns>     # Accepted / ResolvedRefs theo từng parentRef
```

- `Accepted=False` → route không được Gateway nhận (sai `parentRefs`, hostname không khớp listener, namespace không nằm trong `allowedRoutes`).
- `ResolvedRefs=False` → backend Service sai tên/port, hoặc thiếu `ReferenceGrant` khi khác namespace.
- Gateway không có ADDRESS → MetalLB hết IP trong pool / chưa cấu hình.

---

## 8. DNS

### Pod tìm DNS server thế nào

Với `dnsPolicy: ClusterFirst` (mặc định), kubelet ghi vào pod:

```text
# /etc/resolv.conf trong pod ở namespace "shop"
nameserver 10.96.0.10                      # ClusterIP của Service kube-dns → pod CoreDNS
search shop.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

Các `dnsPolicy` khác: `Default` (dùng resolv.conf của node — **không** phân giải được tên Service), `ClusterFirstWithHostNet` (bắt buộc cho pod `hostNetwork` muốn dùng CoreDNS), `None` (tự khai báo `dnsConfig`).

### Bản ghi CoreDNS trả lời

- `payment.shop.svc.cluster.local` → **A**: ClusterIP (Service thường) hoặc danh sách IP pod Ready (headless).
- `_http._tcp.payment.shop.svc.cluster.local` → **SRV**: port theo tên port của Service.
- StatefulSet + headless Service: `db-0.db.shop.svc.cluster.local` → IP của đúng pod `db-0` — danh tính mạng ổn định cho từng replica.
- Tên ngoài cluster → plugin `forward` chuyển lên DNS upstream (từ resolv.conf của node).
- Corefile (ConfigMap `coredns` trong `kube-system`) gồm các plugin: `kubernetes` (sinh bản ghi từ API), `forward`, `cache` (mặc định 30s), `loop` (phát hiện vòng lặp forward), `health`, `ready`.

### `ndots:5` và cái giá ẩn

Tên có **ít hơn 5 dấu chấm** bị thử ghép với từng `search` domain **trước**, rồi mới hỏi nguyên văn:

```text
lookup "api.example.com" (2 dấu chấm):
  api.example.com.shop.svc.cluster.local   NXDOMAIN
  api.example.com.svc.cluster.local        NXDOMAIN
  api.example.com.cluster.local            NXDOMAIN
  api.example.com                          OK
× (A + AAAA) = 8 truy vấn cho một lần lookup
```

Giảm tải: gọi FQDN có dấu chấm cuối (`api.example.com.`), hạ `ndots` qua `dnsConfig`, cache trong app, hoặc **NodeLocal DNSCache** (cache DNS chạy trên từng node).

Lỗi kinh điển "DNS chậm đúng 5 giây": glibc gửi A và AAAA song song trên cùng socket UDP, hai gói tạo entry conntrack đua nhau, một gói bị drop → chờ timeout 5s rồi thử lại. Xử lý: NodeLocal DNSCache, `options single-request-reopen`, hoặc datapath không phụ thuộc conntrack cho DNS.

### Tên ngoài cluster: ExternalDNS

ExternalDNS theo dõi Service LoadBalancer, Ingress, Gateway API route, và tạo/cập nhật/xoá record ở nhà cung cấp DNS (Cloudflare, Route 53, Cloud DNS…). Nó đánh dấu record mình sở hữu bằng **TXT registry** để không ghi đè record người khác tạo tay.

### Debug

```bash
kubectl run -it --rm dns --image=nicolaka/netshoot -- dig payment.shop.svc.cluster.local
kubectl -n kube-system logs -l k8s-app=kube-dns
# Không resolve được? kiểm tra: pod CoreDNS Running? NetworkPolicy có chặn egress 53? Service có endpoint?
```

---

# Phần III — Kiểm soát và bảo mật

## 9. NetworkPolicy

### Mô hình

Mặc định không có giới hạn nào giữa các pod. NetworkPolicy là **allow-list** gắn vào pod (chọn bằng `podSelector`), theo hai chiều độc lập: `Ingress` (vào pod) và `Egress` (ra khỏi pod).

**Chỉ có tác dụng khi CNI thực thi.** Kubernetes chỉ lưu object; Cilium, Calico… thực thi, Flannel thuần thì bỏ qua lặng lẽ.

### Ngữ nghĩa chính xác

- Pod **không bị policy nào chọn** → không bị cô lập, mọi thứ được phép.
- Pod bị ít nhất một policy chọn → bị cô lập **theo các chiều ghi trong `policyTypes`** của các policy đó. Theo chiều bị cô lập, chỉ traffic khớp một rule allow nào đó mới đi được.
- Không ghi `policyTypes` → mặc định `[Ingress]`, cộng thêm `Egress` chỉ khi policy có mục `egress`. Một policy rỗng chỉ có `podSelector` → chặn **vào**, không chặn **ra**.
- Các policy **cộng dồn** (union). Không có rule deny, không có thứ tự ưu tiên.
- Kết nối A → B được phép khi **egress của A** và **ingress của B** cùng cho phép. Gói trả lời tự đi qua (stateful, dựa trên conntrack / eBPF CT).
- Policy đánh giá tại **pod**, sau khi Service đã DNAT → `ports` là **port của pod** (`targetPort`), không phải port của Service; và rule cho phép "tới Service" phải viết theo label pod backend.

### Bẫy kinh điển: AND hay OR

```yaml
ingress:
  - from:
      - namespaceSelector: { matchLabels: { team: a } }   # MỘT phần tử có 2 điều kiện:
        podSelector: { matchLabels: { app: web } }         # ns team=a VÀ pod app=web → AND
---
ingress:
  - from:
      - namespaceSelector: { matchLabels: { team: a } }   # phần tử 1: mọi pod trong ns team=a
      - podSelector: { matchLabels: { app: web } }         # phần tử 2: pod app=web cùng ns → OR
```

Chỉ khác nhau một dấu `-`, ý nghĩa ngược hẳn. Lưu ý thêm: `podSelector` đứng một mình chỉ chọn pod **trong namespace của policy**. Từ 1.22, mọi namespace có sẵn label `kubernetes.io/metadata.name`, dùng nó để chọn namespace theo tên.

### Bộ khung chuẩn cho một namespace

```yaml
# 1. Default deny cả hai chiều
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: shop }
spec:
  podSelector: { }
  policyTypes: [ Ingress, Egress ]
---
# 2. Mở lại DNS — quên bước này là mọi thứ "hỏng bí ẩn"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: shop }
spec:
  podSelector: { }
  policyTypes: [ Egress ]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [ { protocol: UDP, port: 53 }, { protocol: TCP, port: 53 } ]
---
# 3. backend → database:5432 (cần cả egress ở backend lẫn ingress ở database)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-from-backend, namespace: shop }
spec:
  podSelector: { matchLabels: { app: database } }
  policyTypes: [ Ingress ]
  ingress:
    - from: [ { podSelector: { matchLabels: { app: backend } } } ]
      ports: [ { protocol: TCP, port: 5432 } ]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: backend-to-db, namespace: shop }
spec:
  podSelector: { matchLabels: { app: backend } }
  policyTypes: [ Egress ]
  egress:
    - to: [ { podSelector: { matchLabels: { app: database } } } ]
      ports: [ { protocol: TCP, port: 5432 } ]
```

Đừng quên: pod cần gọi **API server** (operator, controller) phải được mở egress tới IP API server / port 6443 — với `ipBlock` vì API server không phải pod.

### `ipBlock` và NAT

`ipBlock` khớp theo IP **sau mọi lần NAT trên đường tới pod**. Traffic từ ngoài qua Service với `externalTrafficPolicy: Cluster` đã bị SNAT thành IP node → rule `ipBlock` theo IP client sẽ không khớp. `ipBlock` không nên dùng để chọn pod (IP pod thay đổi).

### Không làm được với NetworkPolicy chuẩn

Rule deny tường minh, policy toàn cluster, ưu tiên giữa policy, rule L7 (method/path HTTP), rule theo tên miền (`*.github.com`), ghi log drop. Những thứ này cần CRD của CNI: `CiliumNetworkPolicy` / `CiliumClusterwideNetworkPolicy` (lab dùng), `GlobalNetworkPolicy` của Calico, hoặc `AdminNetworkPolicy` (API chuẩn mới của SIG Network, cho platform team).

### Cilium thực thi thế nào

Cilium gán mỗi tổ hợp label của pod một **security identity** (một số nguyên), lưu policy trong eBPF map dạng `(identity nguồn, port, proto) → allow/deny`. Gói đi giữa node mang identity trong header VXLAN, nên bên nhận không cần tra IP → pod. Đổi IP pod không ảnh hưởng policy; scale lên hàng nghìn pod cùng label vẫn chỉ là một identity.

### Debug

```bash
# Hubble: thấy trực tiếp gói bị drop và vì sao
hubble observe --verdict DROPPED --namespace shop
kubectl -n kube-system exec ds/cilium -- cilium policy get
kubectl -n kube-system exec ds/cilium -- cilium endpoint list   # policy enforcement ingress/egress từng pod
```

---

## 10. mTLS và Service Mesh

### Vì sao NetworkPolicy chưa đủ

NetworkPolicy quyết định dựa trên IP/label — không chứng minh được bằng mật mã rằng bên gọi đúng là ai, và traffic vẫn là plaintext trên dây. Ai chiếm được node, cắm được vào mạng, hoặc giả mạo được IP là đọc / giả danh được.

### TLS và mTLS

TLS: client và server trao đổi khoá, server gửi certificate, client kiểm tra chữ ký CA và tên trong cert → kênh mã hoá + client biết chắc server là ai. Server **không** biết client là ai.

mTLS: server gửi thêm `CertificateRequest`, client xuất trình cert của mình và chứng minh giữ private key → **cả hai phía** đã xác thực.

### Danh tính workload: SPIFFE

Mesh không dùng IP làm danh tính mà dùng **SPIFFE ID**, gắn với **ServiceAccount**:

```text
spiffe://cluster.local/ns/shop/sa/payment
         ╰─────┬─────╯    ╰┬─╯    ╰──┬──╯
         trust domain  namespace service account
```

ID nằm trong trường SAN (URI) của một X.509 cert ngắn hạn (gọi là SVID, Istio mặc định ~24h), do CA của mesh ký. Quy trình: proxy/agent trên node chứng minh với control plane rằng nó chạy cho pod X (dựa trên token ServiceAccount do kubelet cấp) → nhận cert → tự rotate trước khi hết hạn. Private key không bao giờ rời node.

Có danh tính rồi thì viết **authorization theo danh tính**: "chỉ `sa/checkout` được `POST /charge` vào `sa/payment`" — đúng dù IP, node, số replica thay đổi.

### Các mô hình mesh

**Sidecar** (Istio cổ điển — Envoy; Linkerd — linkerd2-proxy):

- Một proxy được inject vào mỗi pod. Rule iptables trong netns của pod (do init container hoặc CNI plugin của mesh tạo) **chặn mọi traffic** của app và đẩy qua proxy (Istio: outbound → 15001, inbound → 15006).
- App nói plaintext với `localhost`; proxy hai đầu bắt tay mTLS với nhau.
- Đầy đủ L7 (retry, timeout, routing, metrics theo request) nhưng tốn CPU/RAM trên mỗi pod và thêm độ trễ hai hop proxy.

**Không sidecar:**

- **Istio ambient:** `ztunnel` (một agent mỗi node) lo mTLS + authz L4 cho mọi pod trên node; **waypoint proxy** (Envoy, triển khai theo namespace/service account) chỉ dựng khi cần L7.
- **Cilium:** *mutual authentication* (danh tính từ SPIRE, quyết định gắn vào policy) + *transparent encryption* bằng WireGuard hoặc IPsec giữa node; L7 qua Envoy trên node.

Phân biệt: mã hoá **giữa node** (WireGuard/IPsec) bảo vệ dữ liệu trên dây và xác thực *node*; mTLS theo SPIFFE xác thực *workload*. Hai thứ bổ sung chứ không thay nhau.

### Chuyển dần sang mTLS

Istio có `PeerAuthentication`: `PERMISSIVE` (nhận cả plaintext lẫn mTLS — để chuyển dần), rồi `STRICT` (chỉ mTLS). Thêm `AuthorizationPolicy` để giới hạn theo danh tính. Bật `STRICT` khi còn client ngoài mesh → client đó gãy ngay.

### Đánh đổi

Mesh là một hệ phân tán thật: control plane, CA, upgrade proxy, độ trễ thêm, debug thêm một tầng. Đáng dùng khi cần zero-trust/compliance, nhiều team, nhiều service; quá mức với cluster nhỏ — ở đó NetworkPolicy + mã hoá giữa node có thể đã đủ.

---

## 11. Bảo mật mạng: những lỗ mặc định

- **`externalIPs` (CVE-2020-8554):** ai tạo được Service là gán được `spec.externalIPs` bất kỳ → kube-proxy trên mọi node chặn và chuyển traffic tới IP đó vào pod của họ (man-in-the-middle bên trong cluster). Bật admission plugin `DenyServiceExternalIPs` hoặc policy (Kyverno/Gatekeeper) cấm field này. Tương tự với quyền patch `status.loadBalancer`.
- **NodePort mở trên mọi node, mọi interface** — kể cả Service bạn chỉ định dùng nội bộ, nếu ai đó đổi type. Firewall ở biên nên chặn dải `30000–32767` từ ngoài nếu không dùng.
- **`hostNetwork` / `NET_RAW` / `NET_ADMIN`:** pod hostNetwork thấy toàn bộ mạng node và không chịu NetworkPolicy; `NET_RAW` cho phép tạo gói tuỳ ý (ARP/IP spoofing trong mạng L2). Pod Security Standards mức `restricted` cấm những thứ này — nên áp cho namespace workload.
- **Mạng L2 phẳng của node:** MetalLB L2 và kube-vip đều tin vào ARP; máy nào trong cùng segment cũng có thể giành IP bằng ARP giả. Tách VLAN cho node (lab có OPNsense ở biên) là lớp bảo vệ chính.
- **Metadata server** của cloud (mục 13).
- **Không mã hoá mặc định:** traffic pod ↔ pod, kể cả giữa các node qua mạng vật lý, là plaintext trừ khi bật WireGuard/IPsec hoặc mesh (mục 10).

---

# Phần IV — Vận hành

## 12. Networking của control plane

Các mục trên nói về traffic của workload. Bản thân control plane cũng là một tập luồng mạng, và là nguồn lỗi hay bị bỏ quên khi siết firewall / policy.

### Các luồng chính

| Từ → tới                                          | Port                                     | Dùng cho                                                               |
|---------------------------------------------------|------------------------------------------|------------------------------------------------------------------------|
| kubelet, controller, pod → **kube-apiserver**     | 6443                                     | mọi thứ nói chuyện với API (lab: qua VIP của kube-vip, `api_endpoint`) |
| kube-apiserver → **etcd**                         | 2379 (client), 2380 (peer giữa các etcd) | lưu trạng thái                                                         |
| kube-apiserver → **kubelet**                      | 10250                                    | `kubectl exec / logs / attach / port-forward`, metrics                 |
| kube-apiserver → **pod webhook / aggregated API** | port của Service                         | admission webhook, metrics-server, CRD conversion                      |
| scheduler, controller-manager                     | 10259, 10257                             | health/metrics (thường chỉ localhost)                                  |
| Prometheus → kubelet / node-exporter / …          | 10250, 9100, …                           | metrics                                                                |

kube-apiserver, etcd, scheduler, controller-manager chạy dạng **static pod với `hostNetwork`** → nói chuyện bằng IP node, không đi qua CNI, không chịu NetworkPolicy.

### `kubectl exec/logs/port-forward` đi đường nào

```text
kubectl ─HTTPS 6443─► kube-apiserver ─HTTPS 10250─► kubelet ─CRI─► containerd ─► vào netns của pod
```

- Không cần route từ máy admin tới IP pod — mọi thứ được proxy qua API server và kubelet. Firewall chặn 10250 giữa control plane và worker → `exec`/`logs` hỏng dù pod vẫn chạy bình thường.
- `port-forward` cuối cùng kết nối tới `localhost:<port>` **bên trong netns của pod** → **không bị NetworkPolicy chặn**. Đừng dùng "port-forward được" để kết luận "policy cho phép".

### Admission webhook — lỗi kinh điển khi bật default-deny

API server gọi webhook (cert-manager, Kyverno, operator…) như một client bình thường tới Service của webhook. Nhưng nguồn của traffic là **API server trên hostNetwork** → IP node control plane (Cilium xếp nó vào identity `kube-apiserver` / `remote-node`), **không phải một pod**.

- Default-deny ingress ở namespace của webhook mà không mở cho nguồn đó → API server timeout khi gọi webhook → mọi lệnh tạo/sửa resource liên quan bị từ chối (`failurePolicy: Fail`) hoặc âm thầm bỏ qua kiểm tra (`Ignore`).
- NetworkPolicy chuẩn phải mở bằng `ipBlock` theo IP node control plane; Cilium thì gọn hơn: `fromEntities: [kube-apiserver]`.

### Probe của kubelet

Liveness/readiness probe xuất phát từ **kubelet trên chính node đó** (netns của node). Hầu hết CNI luôn cho phép traffic từ host cục bộ vào pod (Cilium: mặc định cho phép từ entity `host`) để probe không bị policy giết. Nếu tắt hành vi này thì phải mở tường minh, nếu không pod bị restart vòng lặp.

### Port cần mở giữa các node (lab)

| Port        | Proto     | Dùng cho                                               |
|-------------|-----------|--------------------------------------------------------|
| 6443        | TCP       | API server (VIP kube-vip)                              |
| 2379–2380   | TCP       | etcd (giữa control plane)                              |
| 10250       | TCP       | kubelet                                                |
| 8472        | UDP       | VXLAN của Cilium (pod ↔ pod khác node)                 |
| 4240        | TCP       | cilium-health (kiểm tra kết nối node ↔ node)           |
| 4244        | TCP       | Hubble server trên từng node (Hubble Relay đọc)        |
| 7946        | TCP + UDP | MetalLB memberlist (speaker phát hiện node chết)       |
| 30000–32767 | TCP/UDP   | NodePort (nếu public trực tiếp)                        |
| ICMP        | —         | PMTUD + cilium-health; chặn hết ICMP là tự gây lỗi MTU |

Bật WireGuard của Cilium thì cần thêm UDP 51871.

---

## 13. Egress: traffic ra khỏi cluster

Phần lớn tài liệu chỉ nói chiều vào; chiều ra mới là chỗ bảo mật và vận hành hay vướng.

### Mặc định: masquerade theo node

Như mục 4: pod gọi ra ngoài → SNAT sang IP node đang chạy pod. Hệ quả:

- IP nguồn **phụ thuộc pod đang nằm ở node nào** → bên ngoài không thể allow-list theo "ứng dụng".
- Mọi pod trên một node chia nhau IP của node đó (xem cạn port SNAT ở mục 14).

### Egress gateway — IP nguồn cố định

Chọn một (vài) node làm cổng ra cho một nhóm pod: traffic của pod khớp selector được chuyển tới node gateway rồi SNAT sang một IP cố định. Dùng khi đối tác/firewall/database bên ngoài chỉ cho phép một IP. Cilium có `CiliumEgressGatewayPolicy`; trên cloud còn có Cloud NAT với IP tĩnh (áp cho cả node).

### Chặn egress theo tên miền

NetworkPolicy chuẩn chỉ có `ipBlock` — vô dụng với dịch vụ SaaS đổi IP liên tục. Cilium có `toFQDNs`:

```yaml
egress:
  - toEndpoints: # bắt buộc: cho Cilium thấy DNS
      - matchLabels: { k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns }
    toPorts:
      - ports: [ { port: "53", protocol: ANY } ]
        rules: { dns: [ { matchPattern: "*" } ] }
  - toFQDNs: [ { matchName: api.github.com }, { matchPattern: "*.githubusercontent.com" } ]
```

Cơ chế: DNS proxy của Cilium đọc câu trả lời DNS của pod, ghi các IP vừa phân giải vào policy (theo TTL). Pod tự hardcode IP hoặc dùng DNS khác → không khớp.

### Proxy HTTP ra ngoài (lab: Squid)

Lab đi ra internet qua **Squid** (`proxy_url: http://proxy.<lab_domain>:3128` trong `group_vars/all/network.yml`): apt trên node đi qua Squid, image được containerd kéo qua **Harbor** (mirror trong `/etc/containerd/certs.d/`). Đây là cấu hình **mức node** — pod không tự động đi qua proxy.

Muốn pod đi qua proxy phải truyền `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` vào container, và `NO_PROXY` là chỗ hay sai:

- Lab đặt `no_proxy` gồm VIP, IP node, `10.0.0.0/8`, `.svc`, `.cluster.local`, `.<lab_domain>`. Tên **ngắn** như `payment` hay `payment.shop` **không** khớp `.svc` → bị đẩy sang Squid → lỗi. Trong pod nên gọi tên đầy đủ, hoặc thêm hậu tố cụ thể.
- CIDR trong `NO_PROXY` (`10.0.0.0/8`) chỉ được một số client hiểu (Go, curl mới, Python requests); Java (`http.nonProxyHosts`) và nhiều tool cũ thì không → phải liệt kê tên miền.
- `HTTPS_PROXY` dùng `CONNECT` → proxy chỉ thấy tên miền (SNI), không thấy nội dung, trừ khi làm TLS interception (cần pod tin CA của proxy).

### Metadata server của cloud — lỗ hổng mặc định

Trên GCP (env `gcp` của lab), mọi VM có metadata server ở `169.254.169.254`. Pod gọi được tới đó qua node → lấy được **access token của service account gắn với VM** và thông tin instance. Chặn bằng egress policy cho mọi namespace workload (Cilium: deny `toCIDR: 169.254.169.254/32` ở `CiliumClusterwideNetworkPolicy`), hoặc gỡ service account / thu hẹp scope của VM.

---

## 14. Giới hạn của datapath và hiệu năng

### Bảng connection tracking

Mọi kết nối qua NAT/Service/policy chiếm một entry conntrack.

- kube-proxy/iptables: bảng `nf_conntrack` của kernel; đầy → `dmesg`: `nf_conntrack: table full, dropping packet`, kết nối mới bị drop ngẫu nhiên. Chỉnh `net.netfilter.nf_conntrack_max` và timeout.
- Cilium: dùng **CT map và NAT map riêng trong eBPF** (kích thước theo `bpf-ct-global-*-max`, mặc định tính theo RAM node). Đầy cũng drop — xem `cilium bpf ct list global | wc -l`, metrics `cilium_bpf_map_pressure`.
- Thủ phạm thường gặp: client mở kết nối ngắn liên tục không keep-alive, UDP không có trạng thái đóng (DNS, syslog) chờ timeout.

### Cạn port SNAT

Một bộ `(IP node, IP đích, port đích, proto)` chỉ có ~28k port nguồn (dải ephemeral mặc định `32768–60999`). Nhiều pod trên một node cùng gọi **một** endpoint bên ngoài (một database, một API, chính Squid của lab) → hết port → `connect` lỗi / timeout dù CPU, mạng rảnh. Giảm bằng connection pool + keep-alive, nhiều IP đích, nhiều IP egress, hoặc mở rộng dải ephemeral.

### Hairpin

Pod gọi Service và được LB chọn trúng **chính nó**. Với bridge + iptables, gói đi ra rồi phải quay lại đúng interface vừa ra → cần `hairpin mode` trên bridge + masquerade, thiếu thì kết nối treo. Cilium socket-LB xử lý trong kernel nên không gặp.

### `hostPort`

Map một port của node vào pod (plugin CNI `portmap`, hoặc Cilium). Pod gắn chặt vào node, hai pod cùng `hostPort` không chạy chung node, và port mở trên mọi interface của node. Gần như luôn có cách tốt hơn (Service, Gateway).

### Tối ưu datapath (biết để đọc tài liệu Cilium)

- **XDP** — xử lý NodePort/LoadBalancer ngay trong driver NIC, trước cả stack mạng; cần driver hỗ trợ.
- **DSR** (Direct Server Return) — backend trả lời thẳng cho client, không vòng qua node nhận ban đầu; giữ được IP client.
- **Bandwidth Manager** — giới hạn băng thông egress từng pod (annotation `kubernetes.io/egress-bandwidth`) bằng EDT thay vì hàng đợi TBF.
- **BIG TCP**, **netkit** (thay veth, kernel mới) — giảm chi phí mỗi gói ở tốc độ cao.

Đều là tuỳ chọn; lab chưa bật, và phần lớn không đáng bận tâm ở quy mô lab.

---

## 15. IPv6 và dual-stack

- Cluster có thể chạy **dual-stack**: pod có cả IPv4 lẫn IPv6, cần khai báo hai dải pod CIDR và hai dải service CIDR.
- Service có `ipFamilyPolicy` (`SingleStack` / `PreferDualStack` / `RequireDualStack`) và `ipFamilies` → một Service có thể có hai ClusterIP.
- DNS trả cả A lẫn AAAA; client tự chọn (thường ưu tiên IPv6). App chỉ listen `0.0.0.0` (IPv4) mà client chọn IPv6 → connection refused khó hiểu.
- IPv6 không cần NAT để ra ngoài nếu pod có địa chỉ global — nhưng cũng có nghĩa pod **có thể bị gọi thẳng từ ngoài** nếu firewall không chặn.

> **Lab:** chỉ chạy IPv4 (`pod_cidr`, `service_cidr` chỉ có một dải).

---

## 16. Nhiều mạng, nhiều cluster

- **Multus** — meta-CNI cho phép một pod có **thêm interface** (macvlan, SR-IOV, VLAN riêng) ngoài `eth0` do CNI chính quản lý. Dùng cho NFV, storage, mạng tốc độ cao. Interface phụ không có Service, DNS hay NetworkPolicy chuẩn.
- **Multi-cluster:** Cilium **ClusterMesh** nối nhiều cluster thành một mặt phẳng pod — pod CIDR các cluster **không được chồng lấn**, Service đánh dấu "global" được load-balance qua các cluster. Chuẩn chung là **MCS API** (`ServiceExport` / `ServiceImport`, tên `<svc>.<ns>.svc.clusterset.local`).
- Mesh (Istio multi-cluster) giải quyết cùng bài toán ở tầng L7 với danh tính chung (trust domain).

---

# Phần V — Tổng hợp

## 17. Vòng đời của một request trong lab

Theo một request `GET https://myapp.example.com/shop/cart` từ trình duyệt, đi qua Gateway tới pod `shop`, rồi `shop` gọi tiếp `payment` trong cluster, cho tới khi response về lại trình duyệt và kết nối được đóng. Mỗi pha ghi: chuyện gì xảy ra → hỏng thì trông thế nào → quan sát ở đâu.

### Toàn cảnh

```text
 Trình duyệt          Node leader (MetalLB)          Node B (pod shop)          Node C (pod payment)
      │                       │                              │                            │
      │ 1. DNS → IP LB        │                              │                            │
      │ 2. ARP → MAC leader   │                              │                            │
      │══ 3-4. TCP + TLS ════►│ eBPF tc → Envoy              │                            │
      │══ 5. GET /shop/cart ═►│ khớp HTTPRoute, chọn pod     │                            │
      │                       │── 6. VXLAN :8472 ───────────►│ policy → pod shop          │
      │                       │                              │ 7. app xử lý               │
      │                       │                              │── 8. DNS + socket-LB ─────►│ policy → pod payment
      │                       │                              │◄─────────── response ──────│
      │                       │◄────────── 9. response ──────│                            │
      │◄═ response (TLS) ═════│                              │                            │
      │   10. keep-alive / đóng kết nối                      │                            │
```

Có **ba kết nối TCP độc lập**: trình duyệt ↔ Envoy, Envoy ↔ pod `shop`, pod `shop` ↔ pod `payment`. Mỗi kết nối có timeout, keep-alive và cách hỏng riêng.

### Pha 0 — trước khi có request: cấu hình được lan truyền

Những thứ phải sẵn sàng từ trước, mỗi thứ do một controller khác nhau đẩy xuống datapath:

1. **Pod `shop` Ready** → EndpointSlice controller thêm IP pod vào EndpointSlice của Service `shop`.
2. **Cilium agent** trên mọi node đọc Service + EndpointSlice → ghi vào eBPF LB map. Đọc label pod → cấp **security identity** → ghi policy map.
3. **`Gateway` + `HTTPRoute`** → cilium-operator dịch thành `CiliumEnvoyConfig` → agent đẩy cấu hình cho Envoy qua **xDS** (listener, route, cluster, endpoint).
4. Service `cilium-gateway-<tên>` type LoadBalancer → **MetalLB** cấp IP từ pool, bầu node leader, leader bắt đầu trả lời ARP cho IP đó.
5. **DNS public** `myapp.example.com` → IP LB (ExternalDNS hoặc tạo tay). Cert TLS nằm trong Secret mà listener của Gateway tham chiếu.

Mọi bước đều **bất đồng bộ, eventual consistency**: pod mới Ready có thể chưa nhận traffic vài trăm ms tới vài giây; pod bị xoá có thể vẫn nhận traffic một lúc (xem pha 10).

### Pha 1 — DNS phía client

Trình duyệt hỏi resolver của nó (OS cache → DNS nội bộ / ISP → authoritative) → nhận A record = IP LB, cache theo TTL.

- **Hỏng:** `NXDOMAIN` / trỏ IP cũ (TTL dài, ExternalDNS chưa cập nhật).
- **Quan sát:** `dig myapp.example.com`, so với `kubectl get gateway -A` (cột ADDRESS).

### Pha 2 — tới được node: L2/L3

Gói SYN đầu tiên đi qua router/firewall biên (OPNsense trong lab) tới subnet của node. Router cần MAC của IP LB → **ARP** → speaker MetalLB trên **node leader** trả lời bằng MAC của nó. Từ giờ **mọi kết nối tới IP này vào node leader**.

- **Hỏng:** không có ai trả lời ARP (MetalLB chưa chạy, pool sai subnet, mạng không truyền ARP) → SYN rơi vào hư không → client timeout khi connect.
- **Quan sát:** `arping <IP LB>` từ máy cùng subnet; `kubectl -n metallb-system logs` speaker; `tcpdump -ni <nic> arp`.

### Pha 3 — vào node, tới Envoy

1. SYN tới NIC `node_interface`. Chương trình **eBPF trên tc ingress** của Cilium thấy đích là IP của Service LoadBalancer `cilium-gateway-…`.
2. Vì đó là Service của Gateway, Cilium chuyển kết nối vào **Envoy trên chính node này** (không DNAT sang node khác). Tạo entry **connection tracking** để các gói sau và gói trả lời đi đúng đường.
3. Envoy nhận kết nối trên listener ứng với port 443 → kết thúc **bắt tay TCP** (client ↔ Envoy).

Envoy chạy trên node nhận, không có SNAT trước nó → Envoy thấy **IP client thật** (trừ khi firewall biên đã NAT trước đó). Nó ghi IP này vào `X-Forwarded-For`.

- **Hỏng:** connection refused (listener chưa được cấu hình — Gateway `Programmed=False`), hoặc reset do policy ở host.
- **Quan sát:** `hubble observe --to-ip <IP LB>`; `kubectl describe gateway`.

### Pha 4 — TLS handshake

1. Client gửi **ClientHello** kèm **SNI** = `myapp.example.com` và danh sách ALPN (`h2`, `http/1.1`).
2. Envoy chọn listener/filter chain theo SNI → chọn cert từ Secret → gửi ServerHello + cert.
3. Trình duyệt kiểm tra cert: chuỗi CA, tên khớp SNI, hạn dùng. Hai bên chốt khoá phiên; ALPN chốt **HTTP/2**.
4. TLS 1.3: 1 RTT (hoặc 0-RTT khi resume). Từ đây mọi byte giữa trình duyệt và Envoy được mã hoá.

- **Hỏng:** cert hết hạn / sai tên (cert-manager chưa cấp lại, Secret nằm khác namespace mà thiếu `ReferenceGrant`), SNI không khớp hostname nào của listener → handshake bị từ chối.
- **Quan sát:** `openssl s_client -connect <IP LB>:443 -servername myapp.example.com`.

### Pha 5 — HTTP và routing ở Envoy

1. Trình duyệt gửi request trên một **stream HTTP/2**: `:authority myapp.example.com`, `:path /shop/cart`.
2. Envoy duyệt các `HTTPRoute` gắn vào listener: khớp `hostnames`, rồi `matches` (path, header, query, method). Match cụ thể hơn thắng (path exact > prefix dài hơn > …).
3. Áp `filters`: rewrite path (`/shop/cart` → `/cart`), thêm/xoá header, redirect (trả 301/302 ngay, không tới backend).
4. Envoy bổ sung header: `X-Forwarded-For`, `X-Forwarded-Proto: https`, `X-Request-Id` (dùng để lần theo request qua log), có thể cả header tracing (`traceparent`) nếu bật.
5. Chọn **backend** theo `backendRefs` + `weight` (ví dụ 90/10 canary), rồi chọn **một endpoint** (IP pod) trong backend đó theo thuật toán LB của Envoy (mặc định round-robin / least-request tuỳ cấu hình) — theo **từng request**, không theo kết nối.

- **Hỏng:** `404` (không route nào khớp — sai hostname/path, route `Accepted=False`); `503` + response flag `NR`/`UH` (không có endpoint khỏe — Service rỗng, selector sai).
- **Quan sát:** access log Envoy (`kubectl -n kube-system logs ds/cilium-envoy`), `hubble observe --protocol http`.

### Pha 6 — Envoy tới pod `shop`

1. Envoy lấy (hoặc mở mới) một kết nối từ **connection pool** tới `10.244.B.x:8080`. Kết nối này được tái sử dụng cho nhiều request — tạo kết nối mới tốn thêm một bắt tay.
2. Nguồn của kết nối là IP thuộc identity đặc biệt **`ingress`** của Cilium (không phải IP client, không phải IP pod nào). Policy của `shop` phải cho phép nguồn này: `fromEntities: [ingress]` (CiliumNetworkPolicy).
3. Pod `shop` nằm ở node B → eBPF trên node leader **đóng gói VXLAN**: IP ngoài node leader → node B, UDP 8472, VNI mang **security identity** của nguồn. MTU đã trừ 50 byte.
4. Node B nhận gói UDP, eBPF **bóc VXLAN**, đọc identity, tra **policy map** của pod `shop` (ingress, port 8080) → allow → đẩy vào veth `lxc…` → `eth0` trong netns pod.

Kết nối Envoy ↔ pod là **plaintext** (TLS đã kết thúc ở Envoy) trừ khi có mesh hoặc WireGuard giữa node.

- **Hỏng:** `503 UF` (upstream connect fail — policy drop, pod chết, sai `targetPort`); treo với payload lớn (MTU); `504 UT` (backend quá chậm, vượt timeout của route — Envoy mặc định 15s nếu không đặt `timeouts` trong HTTPRoute).
- **Quan sát:** `hubble observe --to-pod shop/<pod> --verdict DROPPED`; `tcpdump -ni <nic> udp port 8472` trên hai node.

### Pha 7 — bên trong pod `shop`

1. Kernel trong netns pod hoàn tất bắt tay TCP (nếu là kết nối mới) → kết nối nằm trong **accept queue** của socket đang listen `:8080` (kích thước giới hạn bởi backlog / `net.core.somaxconn`).
2. App `accept()`, đọc request (`GET /cart`, `Host: myapp.example.com`, `X-Forwarded-For: <IP client>`).
3. App xử lý: đọc session, gọi service khác (pha 8), truy vấn database…

- **Hỏng:** accept queue đầy (app quá tải / thread pool cạn) → SYN bị drop hoặc kết nối bị reset → Envoy thấy connect timeout. App chỉ listen `127.0.0.1` thay vì `0.0.0.0` → connection refused từ ngoài pod dù `curl localhost` trong pod vẫn chạy.
- **Quan sát:** log app, `ss -lnt` trong pod (cột Recv-Q của socket LISTEN = hàng đợi accept).

### Pha 8 — `shop` gọi `payment` (east-west)

1. **DNS:** app gọi `payment` → resolver trong pod đọc `/etc/resolv.conf` → vì `ndots:5`, thử `payment.shop.svc.cluster.local` trước → gửi tới `10.96.0.10` (kube-dns). Socket-LB của Cilium đổi đích ClusterIP của kube-dns thành IP một pod CoreDNS. Egress policy của `shop` phải cho phép UDP/TCP 53 tới CoreDNS. CoreDNS trả **ClusterIP** của Service `payment` (cache TTL 30s). Nếu có policy `toFQDNs`, DNS proxy của Cilium đứng ở giữa và đọc câu trả lời để cập nhật policy.
2. **`connect()` tới ClusterIP:8080:** hook eBPF trên cgroup của pod đổi đích thành IP một pod `payment` **ngay trong syscall** — gói tin rời pod đã mang IP pod thật, không có DNAT trên đường đi.
3. **Egress policy** của `shop` (tới identity của `payment`, port 8080) → VXLAN sang node C → **ingress policy** của `payment` → vào pod.
4. Nếu có service mesh: proxy hai đầu (sidecar hoặc ztunnel) bắt tay **mTLS** với SPIFFE ID của `sa/shop` và `sa/payment` trước khi dữ liệu đi; `AuthorizationPolicy` quyết định theo danh tính.
5. `payment` trả lời; kết nối có thể được giữ lại trong pool của client HTTP trong app — **và dính vào pod `payment` đó** cho mọi request sau (LB theo kết nối, mục 5).

- **Hỏng:** DNS timeout (quên mở egress 53), DNS chậm 5s (conntrack race), `NXDOMAIN` khi gọi tên ngắn từ namespace khác, request đi nhầm qua Squid (`NO_PROXY` không khớp), tải lệch do kết nối dài.
- **Quan sát:** `hubble observe --from-pod shop/<pod>` (thấy cả DNS lẫn TCP, kèm verdict).

### Pha 9 — response quay về

1. `payment` → `shop`: đi ngược đường, policy là **stateful** nên gói trả lời không cần rule riêng.
2. `shop` ghi response → kernel gửi về Envoy (VXLAN ngược lại node leader).
3. Envoy nhận response từ upstream, áp filter phía response (thêm/xoá header), ghi **access log** (status, thời gian upstream, response flags), mã hoá bằng khoá phiên TLS và gửi trên stream HTTP/2 về trình duyệt.
4. Ở node leader, entry connection tracking của pha 3 giúp gói trả lời rời NIC với **source = IP LB** (không lộ IP node hay IP Envoy).

Tổng độ trễ ≈ DNS (nếu không cache) + RTT tới node + TLS handshake (nếu kết nối mới) + thời gian xử lý của `shop` (bao gồm cả lượt gọi `payment`) + vài hop mạng nội bộ. Trong thực tế, phần lớn nằm ở app và lượt gọi nội bộ, không phải ở datapath.

### Pha 10 — sau response: tái sử dụng và đóng kết nối

- **Trình duyệt ↔ Envoy:** HTTP/2 giữ kết nối mở để gửi tiếp các request khác (ảnh, API) trên cùng kết nối TLS — không phải bắt tay lại. Đóng khi idle quá lâu (idle timeout phía Envoy hoặc trình duyệt) bằng `GOAWAY` + FIN.
- **Envoy ↔ pod:** nằm lại trong connection pool, bị đóng khi idle quá lâu, khi endpoint biến mất khỏi EndpointSlice, hoặc khi Envoy nhận cấu hình mới.
- **shop ↔ payment:** tuỳ client HTTP trong app (keep-alive, pool size, idle timeout).
- Khi TCP đóng, entry conntrack/CT map chuyển sang trạng thái đóng rồi bị dọn sau timeout. Client mở kết nối ngắn liên tục thì bảng này phình to (mục 14).

**Timeout phải xếp bậc:** timeout ngoài cùng (client) > timeout route của Envoy > timeout gọi nội bộ của app. Ngược lại thì bên ngoài bỏ cuộc trong khi bên trong vẫn cặm cụi xử lý — tốn tài nguyên và gây retry chồng chất.

### Khi pod `shop` bị xoá giữa chừng (rolling update)

```text
t0  kubectl rollout / scale down → pod chuyển Terminating
    ├─ EndpointSlice: endpoint ready=false, terminating=true ─► Cilium agent mọi node + Envoy (xDS) gỡ dần
    └─ kubelet: chạy preStop (ví dụ sleep 5) → rồi gửi SIGTERM cho container
t0+5s  app nhận SIGTERM: ngừng accept kết nối mới, xử lý xong request đang dở, đóng kết nối keep-alive
t0+terminationGracePeriodSeconds (mặc định 30s)  SIGKILL nếu app chưa thoát
```

- Không có `preStop`, app tắt **trước khi** Envoy/Cilium kịp gỡ endpoint → request mới vẫn được gửi tới → `503 UF` / connection refused trong vài giây.
- App tắt cứng (không chờ request đang dở) → request đang xử lý bị cắt → client thấy `502` / reset.
- Kết nối keep-alive tới pod cũ phải được **đóng chủ động** (header `Connection: close`, `GOAWAY` cho HTTP/2), nếu không client sẽ thử gửi request tiếp lên kết nối đã chết.

### Bảng tóm tắt theo pha

| Pha             | Thành phần                        | Lỗi điển hình                       | Nơi xem                                |
|-----------------|-----------------------------------|-------------------------------------|----------------------------------------|
| 1 DNS ngoài     | resolver, ExternalDNS             | NXDOMAIN, IP cũ                     | `dig`                                  |
| 2 L2/L3         | router, MetalLB ARP               | connect timeout                     | `arping`, log speaker                  |
| 3 Vào node      | Cilium tc, conntrack              | refused / reset                     | `hubble observe`, `describe gateway`   |
| 4 TLS           | Envoy, Secret, cert-manager       | lỗi cert, SNI không khớp            | `openssl s_client`                     |
| 5 Routing       | Envoy, HTTPRoute                  | 404, 503 `NR`/`UH`                  | access log Envoy, `describe httproute` |
| 6 Tới pod       | VXLAN, policy, identity `ingress` | 503 `UF`, 504 `UT`, treo do MTU     | Hubble DROPPED, `tcpdump` 8472         |
| 7 Trong pod     | accept queue, app                 | timeout, refused (listen 127.0.0.1) | `ss -lnt`, log app                     |
| 8 East-west     | CoreDNS, socket-LB, policy, mesh  | DNS lỗi/chậm, tải lệch, sai proxy   | `hubble observe --from-pod`            |
| 9 Response      | conntrack, Envoy                  | — (đi ngược đường cũ)               | access log                             |
| 10 Đóng / drain | keep-alive, EndpointSlice         | 502/503 khi rollout                 | log Envoy theo thời gian rollout       |

---

## 18. Hộp đồ nghề debug

| Triệu chứng                                 | Kiểm tra trước                                                                                                  |
|---------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| Service không trả lời                       | `kubectl get endpointslices` — có endpoint Ready không? selector khớp label? `targetPort` đúng port app listen? |
| Chỉ một số pod nhận tải                     | kết nối dài (gRPC/HTTP2/pool) dính một backend — cần LB L7                                                      |
| Lỗi 502 lúc rolling update                  | thiếu `preStop` sleep / app không xử lý SIGTERM                                                                 |
| Request nhỏ OK, lớn treo                    | MTU / PMTUD (overlay trừ 50 byte, firewall chặn ICMP)                                                           |
| DNS chậm ~5s                                | conntrack race UDP — NodeLocal DNSCache, `single-request-reopen`                                                |
| DNS lỗi sau khi bật policy                  | quên allow egress UDP/TCP 53 tới CoreDNS                                                                        |
| Policy "không có tác dụng"                  | CNI không thực thi; sai AND/OR trong `from`; `ports` dùng port Service thay vì port pod                         |
| App không thấy IP client                    | `externalTrafficPolicy: Cluster` SNAT → `Local` hoặc `X-Forwarded-For`                                          |
| `EXTERNAL-IP <pending>`                     | không có MetalLB/cloud controller, hoặc pool hết IP                                                             |
| IP LoadBalancer không ping được             | ARP không tới (L2 mode trên mạng không phải L2 thật), leader node có vấn đề                                     |
| HTTPRoute không chạy                        | `kubectl describe httproute` → `Accepted` / `ResolvedRefs`                                                      |
| Node `NotReady` sau `kubeadm init`          | chưa cài CNI                                                                                                    |
| `kubectl exec/logs` lỗi, pod vẫn chạy       | firewall chặn API server → kubelet 10250                                                                        |
| Tạo resource bị timeout ở webhook           | default-deny chặn API server (hostNetwork, IP node) gọi vào pod webhook                                         |
| Pod gọi service nội bộ lỗi qua proxy        | `NO_PROXY` không khớp tên ngắn / client không hiểu CIDR                                                         |
| Kết nối ra ngoài lỗi ngẫu nhiên khi tải cao | cạn port SNAT hoặc bảng conntrack / CT map đầy                                                                  |
| App lỗi khi client dùng IPv6                | app chỉ listen IPv4, DNS trả AAAA                                                                               |

Công cụ: `kubectl debug` + `nicolaka/netshoot`, `tcpdump`, `dig`, `conntrack`, `iptables-save`, `cilium status`, `cilium service list`, `hubble observe`.

---

## 19. Tổng kết

1. **CNI** dựng mạng phẳng không NAT và cấp IP cho mỗi pod (lab: Cilium, VXLAN, `10.244.0.0/16`) — nhưng pod dùng xong bỏ, IP thay đổi liên tục.
2. **Service** đặt một IP ảo ổn định phía trước một nhóm pod; thực chất là rule DNAT trên mọi node (kube-proxy) hoặc socket-LB eBPF (lab) — nhưng chỉ ở L4, theo kết nối, và ClusterIP chỉ trong cluster.
3. **NodePort / LoadBalancer** mở đường từ ngoài vào (lab: MetalLB L2 cấp IP và trả lời ARP) — với đánh đổi source IP qua `externalTrafficPolicy`.
4. **Ingress → Gateway API** đặt một proxy L7 làm điểm vào chung: route theo host/path/header, terminate TLS, chia traffic — config nằm trong spec thay vì annotation, quyền sở hữu tách theo vai trò.
5. **DNS** đặt tên phía trước mọi IP — CoreDNS trong cluster (cẩn thận `ndots`), ExternalDNS cho domain public.
6. **NetworkPolicy** (do CNI thực thi) biến "ai cũng gọi được ai" thành allow-list theo từng chiều — nhưng vẫn dựa trên IP/label, chưa mã hoá.
7. **mTLS / service mesh** gán mỗi workload một danh tính mật mã (SPIFFE, theo ServiceAccount), mã hoá và cho phép authorization theo danh tính.

Bên cạnh mạch chính: **control plane** có luồng mạng riêng (6443, 10250, webhook từ hostNetwork), **egress** cần được thiết kế (masquerade, egress gateway, `toFQDNs`, proxy, chặn metadata server), và datapath có **giới hạn vật lý** (conntrack, port SNAT, MTU) cần biết trước khi nó thành sự cố.

Mỗi tầng tin vào thứ ổn định mà tầng dưới trao cho nó và che đi sự lộn xộn bên dưới. Khi debug thì đi ngược lại: từ tầng trên xuống, tầng nào hỏng thì mọi thứ phía trên nó hỏng theo.
