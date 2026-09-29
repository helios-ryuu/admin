# K3S CLUSTER OPERATIONAL RUNBOOK

Tài liệu hướng dẫn chuẩn vận hành (Standard Operating Procedures) cho cụm **K3s Kubernetes** bảo mật trên hạ tầng mạng **Tailscale WireGuard**.

> [!WARNING] **ĐỊNH HƯỚNG VẬN HÀNH (OPERATIONAL PHILOSOPHY)**
> - **Phương pháp chuẩn (Khuyến nghị 100%):** Quản trị viên thực hiện từng bước thủ công bằng file cấu hình Declarative (`/etc/rancher/k3s/config.yaml`), quản lý qua `systemd` và `kubectl`. Điều này đảm bảo tính minh bạch, kiểm soát 100% tham số, loại bỏ nguy cơ "hộp đen" và giúp chuẩn đoán lỗi chính xác.
> - **Script Shell (`*.sh`):** **Chỉ là tuỳ chọn phụ trợ (Không khuyến khích - Unrecommended Helper Option)**. Không khuyến khích sử dụng các script shell (`install-server.sh`, `install-worker.sh`, `update-*.sh`, `uninstall-*.sh`) cho môi trường sản xuất hoặc khi cần kiểm soát trạng thái máy chủ chặt chẽ.

---

## MỤC LỤC
1. [Kiến trúc & Thông số Mạng](#1-kiến-trúc--thông-số-mạng)
2. [Bước 1: Chuẩn bị Hệ thống (Pre-flight Checklist)](#2-bước-1-chuẩn-bị-hệ-thống-pre-flight-checklist)
3. [Bước 2: Cài đặt Server Node (Master / Control Plane)](#3-bước-2-cài-đặt-server-node-master--control-plane)
4. [Bước 3: Cài đặt Worker Node (Agent)](#4-bước-3-cài-đặt-worker-node-agent)
5. [Bước 4: Quy trình Cập nhật & Nâng cấp (Upgrade Runbook)](#5-bước-4-quy-trình-cập-nhật--nâng-cấp-upgrade-runbook)
6. [Bước 5: Quy trình Gỡ bỏ & Dọn dẹp Sạch sẽ (Uninstall & Deep Clean)](#6-bước-5-quy-trình-gỡ-bỏ--dọn-dẹp-sạch-sẽ-uninstall--deep-clean)
7. [Bước 6: Khắc phục Sự cố Thường gặp (Troubleshooting)](#7-bước-6-khắc-phục-sự-cố-thường-gặp-troubleshooting)
8. [Phụ lục: Tuỳ chọn Script Shell (Không khuyến khích)](#8-phụ-lục-tuỳ-chọn-script-shell-không-khuyến-khích)

---

## 1. Kiến trúc & Thông số Mạng

Hệ thống định tuyến Pod-to-Pod và Node-to-Node được mã hóa và cô lập hoàn toàn qua giao diện mạng của Tailscale (`tailscale0`).

| Thành phần | Giá trị cấu hình | Mô tả |
| :--- | :--- | :--- |
| **Giao diện mạng overlay** | `tailscale0` | Toàn bộ traffic K8s đi qua WireGuard Mesh |
| **Flannel Backend** | `vxlan` qua `tailscale0` | CNI định tuyến Pod-to-Pod |
| **Pod CIDR** | `10.42.0.0/16` | Dải mạng cấp phát cho Pod |
| **Service CIDR** | `10.43.0.0/16` | Dải IP ClusterIP của Service |
| **API Server Port** | `6443/tcp` | Lắng nghe trực tiếp trên IP Tailscale của Server |
| **Tailscale Port** | `41641/udp` | Port WireGuard của Tailscale |
| **Ingress Controller** | `Disable Traefik` | Tắt Traefik mặc định để dùng Ingress riêng |
| **Bảo mật Secret** | `secrets-encryption: true` | Kích hoạt mã hóa Secret at-rest (AES-CBC) |

---

## 2. Bước 1: Chuẩn bị Hệ thống (Pre-flight Checklist)

Thực hiện các bước sau trên **CẢ SERVER LẪN WORKER** trước khi cài đặt.

### 2.1. Tắt Swap vĩnh viễn
Kubernetes yêu cầu tắt Swap hoàn toàn để Kubelet quản lý bộ nhớ chính xác:
```bash
# 1. Tắt swap ngay lập tức
sudo swapoff -a

# 2. Xóa hoặc comment dòng swap trong fstab để không kích hoạt lại sau khi reboot
sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# 3. Kiểm tra lại (kết quả phải trống)
swapon --show
```

### 2.2. Bật IP Forwarding & Nạp Kernel Modules
```bash
# Cấu hình IP Forwarding
sudo tee /etc/sysctl.d/99-kubernetes.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Áp dụng cấu hình ngay
sudo sysctl --system

# Xác nhận lại
sysctl net.ipv4.ip_forward
# Kết quả mong muốn: net.ipv4.ip_forward = 1
```

### 2.3. Cấu hình Firewall UFW
Đảm bảo tường lửa không chặn lưu lượng nội bộ giữa các Pod và kết nối Tailscale:
```bash
# 1. Cho phép cổng UDP Tailscale WireGuard
sudo ufw allow 41641/udp

# 2. Cho phép toàn bộ lưu lượng trên giao diện tailscale0
sudo ufw allow in on tailscale0

# 3. Cho phép Pod CIDR và Service CIDR
sudo ufw allow from 10.42.0.0/16
sudo ufw allow from 10.43.0.0/16

# 4. Cho phép cổng K3s API Server trên mạng Tailscale
sudo ufw allow in on tailscale0 to any port 6443 proto tcp

# 5. Cấu hình chính sách Forward của UFW sang ACCEPT
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo sed -i 's/DEFAULT_FORWARD_POLICY="REJECT"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# 6. Tải lại UFW và kiểm tra trạng thái
sudo ufw reload
sudo ufw status verbose
```

### 2.4. Kiểm tra IP Tailscale
Lấy địa chỉ IPv4 Tailscale của máy chủ:
```bash
TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP của máy này: ${TAILSCALE_IP}"
```
> [!IMPORTANT]
> Nếu lệnh trên trả về trống hoặc báo lỗi, hãy kích hoạt Tailscale trước: `sudo tailscale up`.

---

## 3. Bước 2: Cài đặt Server Node (Master / Control Plane)

> [!NOTE]
> K3s hỗ trợ đọc trực tiếp cấu hình Declarative từ `/etc/rancher/k3s/config.yaml`. Phương pháp này ưu việt hơn việc truyền hàng loạt cờ qua dòng lệnh, giúp dễ quản lý phiên bản và bảo trì sau này.

### 3.1. Tạo file cấu hình `/etc/rancher/k3s/config.yaml`
Thay thế `<MASTER_TAILSCALE_IP>` bằng IP Tailscale thực tế của Master (ví dụ: `100.x.y.z`) và `<SERVER_NODE_NAME>` bằng tên máy chủ bạn muốn đặt:

```bash
# Tạo thư mục cấu hình K3s
sudo mkdir -p /etc/rancher/k3s

# Lấy tự động IP Tailscale
MASTER_TS_IP=$(tailscale ip -4)
SERVER_NAME="node-server-1" # Đổi tên theo ý muốn

# Tạo file cấu hình chuẩn
sudo tee /etc/rancher/k3s/config.yaml <<EOF
# --- Định danh & Mạng Node ---
node-name: "${SERVER_NAME}"
bind-address: "${MASTER_TS_IP}"
advertise-address: "${MASTER_TS_IP}"
node-ip: "${MASTER_TS_IP}"
node-external-ip: "${MASTER_TS_IP}"

# --- SANs cho TLS Certificate ---
tls-san:
  - "${MASTER_TS_IP}"
  - "127.0.0.1"
  - "localhost"

# --- Cấu hình CNI Mạng Flannel qua Tailscale ---
flannel-iface: "tailscale0"
flannel-backend: "vxlan"

# --- Thông tin & Mạng Cluster (Tùy chọn nâng cao) ---
# cluster-domain: "cluster.local"        # Tên miền DNS nội bộ của cluster (mặc định: cluster.local)
# cluster-cidr: "10.42.0.0/16"           # Dải mạng cấp phát cho Pod
# service-cidr: "10.43.0.0/16"           # Dải mạng cấp phát cho Service
# cluster-dns: "10.43.0.10"             # IP CoreDNS của cluster

# --- Metadata & Nhãn Node (Node Labels / Taints) ---
# node-label:
#   - "environment=production"
#   - "topology.kubernetes.io/zone=tailscale"

# --- Tinh chỉnh Dịch vụ & Add-ons ---
disable:
  - "traefik"

# --- Bảo mật & Phân quyền ---
secrets-encryption: true
write-kubeconfig-mode: "0644"
debug: false
EOF

# Phân quyền an toàn cho file cấu hình
sudo chmod 600 /etc/rancher/k3s/config.yaml
```

### 3.2. Cài đặt và Khởi động K3s Server
Chạy lệnh cài đặt chính thức của K3s (K3s sẽ tự động phát hiện và áp dụng file `config.yaml` vừa tạo):

```bash
curl -sfL https://get.k3s.io | sh -
```

Kiểm tra trạng thái dịch vụ systemd:
```bash
sudo systemctl status k3s --no-pager
```

### 3.3. Thu thập và Sao lưu Node Token
Token dùng để xác thực cho Worker Node kết nối vào:
```bash
# Hiển thị token
sudo cat /var/lib/rancher/k3s/server/node-token

# Lưu token vào thư mục secrets của repository quản trị (phân quyền bảo mật 0600)
mkdir -p secrets
sudo cat /var/lib/rancher/k3s/server/node-token > secrets/k3s-node-token
chmod 600 secrets/k3s-node-token
echo "[✓] Đã sao lưu token vào secrets/k3s-node-token"
```

### 3.4. Kiểm tra Trạng thái Cụm trên Server
```bash
# Kiểm tra node
kubectl get nodes -o wide

# Kiểm tra các Pod hệ thống (kube-system)
kubectl get pods -A
```
*Trạng thái `Ready` hiển thị kèm IP Tailscale tại cột `INTERNAL-IP` là thành công.*

### 3.5. Đồng bộ Kubeconfig về máy quản trị (Nếu cần)
Nếu bạn quản trị từ xa qua laptop/PC:
```bash
# Trên máy quản trị: Lấy kubeconfig từ Server về ~/.kube/config
mkdir -p ~/.kube
scp user@<MASTER_TAILSCALE_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Đổi server endpoint từ 127.0.0.1 sang IP Tailscale của Server
sed -i "s/127.0.0.1/<MASTER_TAILSCALE_IP>/g" ~/.kube/config
chmod 600 ~/.kube/config

# Đổi tên Context và Tên Cluster (Mặc định K3s đặt tên là 'default')
# Ví dụ đổi thành 'helios-k3s':
CLUSTER_NAME="helios-k3s"
kubectl config rename-context default "${CLUSTER_NAME}"
sed -i "s/name: default/name: ${CLUSTER_NAME}/g" ~/.kube/config
kubectl config set-context helios-k3s-cluster --cluster=helios-k3s-cluster --user=helios-k3s-cluster
kubectl config use-context helios-k3s-cluster

# Kiểm tra context và kết nối từ xa
kubectl config get-contexts
kubectl get nodes
```

---

## 4. Bước 3: Cài đặt Worker Node (Agent)

Thực hiện các bước dưới đây trên **Worker Node**.

### 4.1. Chuẩn bị biến môi trường
Xác định các thông tin cần thiết:
- `MASTER_IP`: IP Tailscale của Server Node (ví dụ `100.64.0.1`).
- `NODE_TOKEN`: Chuỗi token lấy từ `/var/lib/rancher/k3s/server/node-token` trên Server.
- `WORKER_NAME`: Tên hiển thị của Worker trong cụm (ví dụ: `node-worker-1`).

### 4.2. Tạo file cấu hình `/etc/rancher/k3s/config.yaml` trên Worker
```bash
# Tạo thư mục cấu hình
sudo mkdir -p /etc/rancher/k3s

# Lấy tự động IP Tailscale của Worker
WORKER_TS_IP=$(tailscale ip -4)
WORKER_NAME="node-worker-1"         # Đổi theo ý muốn
MASTER_IP="<MASTER_TAILSCALE_IP>"   # Điền IP Master vào đây
TOKEN="<CHUỖI_NODE_TOKEN>"          # Điền Token vào đây

# Tạo file cấu hình agent
sudo tee /etc/rancher/k3s/config.yaml <<EOF
server: "https://${MASTER_IP}:6443"
token: "${TOKEN}"
node-name: "${WORKER_NAME}"
node-ip: "${WORKER_TS_IP}"
node-external-ip: "${WORKER_TS_IP}"
flannel-iface: "tailscale0"
EOF

sudo chmod 600 /etc/rancher/k3s/config.yaml
```

### 4.3. Cài đặt và Khởi động K3s Agent
Kích hoạt cài đặt K3s ở chế độ **Agent**:
```bash
curl -sfL https://get.k3s.io | sh -s - agent
```

Kiểm tra tiến trình dịch vụ:
```bash
sudo systemctl status k3s-agent --no-pager
```

### 4.4. Xác nhận Worker đã gia nhập Cụm
Quay lại máy **Master** hoặc máy quản trị có `kubectl`:
```bash
kubectl get nodes -o wide
```
Kết quả mong muốn:
```text
NAME            STATUS   ROLES                  AGE     VERSION        INTERNAL-IP
node-server-1   Ready    control-plane,master   10m     v1.36.4+k3s1   100.x.y.z
node-worker-1   Ready    <none>                 1m      v1.36.4+k3s1   100.x.y.w
```

---

## 5. Bước 4: Quy trình Cập nhật & Nâng cấp (Upgrade Runbook)

> [!IMPORTANT] **NGUYÊN TẮC VÀNG KHI NÂNG CẤP KUBERNETES**
> 1. **Thứ tự bắt buộc:** Luôn nâng cấp **Control Plane (Server)** trước, sau đó nâng cấp lần lượt từng **Worker**.
> 2. **Chênh lệch phiên bản (Skew Policy):** Phiên bản Worker không được cao hơn phiên bản Server.
> 3. **Bảo vệ Pod (Zero-Downtime):** Cần Cordon và Drain Worker trước khi khởi động lại dịch vụ k3s-agent.

### 5.1. Kiểm tra Phiên bản Mới nhất
```bash
# Xem phiên bản hiện tại
k3s --version

# Kiểm tra phiên bản Stable mới nhất của K3s
curl -s https://update.k3s.io/v1-release/channels/stable | grep -oP '"latest":\s*"\K[^"]+'
```

### 5.2. Nâng cấp Server Node (Master)

#### Bước 5.2.1: Sao lưu dữ liệu
```bash
# 1. Sao lưu cấu hình K3s
sudo cp -r /etc/rancher/k3s /etc/rancher/k3s.bak-$(date +%Y%m%d)

# 2. Tạo snapshot dữ liệu etcd (nếu chạy etcd nhúng) hoặc sao lưu sqlite
if sudo k3s etcd-snapshot 2>/dev/null; then
    echo "Đã tạo etcd snapshot tại /var/lib/rancher/k3s/server/db/snapshots/"
fi
```

#### Bước 5.2.2: Thực hiện nâng cấp Server
Chỉ định phiên bản mong muốn qua biến `INSTALL_K3S_VERSION` (hoặc để trống nếu muốn lên bản mới nhất của channel stable):
```bash
# Ví dụ nâng cấp lên v1.36.4+k3s1 (hoặc thay bằng phiên bản mong muốn)
TARGET_VERSION="v1.36.4+k3s1"

# Tải và chạy installer chính thức (sẽ tự động tái sử dụng /etc/rancher/k3s/config.yaml)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${TARGET_VERSION}" sh -

# Khởi động lại dịch vụ
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

#### Bước 5.2.3: Xác minh Server sau nâng cấp
```bash
# Kiểm tra dịch vụ
sudo systemctl is-active k3s

# Kiểm tra phiên bản hiển thị trong cụm
kubectl get nodes
```

---

### 5.3. Nâng cấp Worker Node (Quy trình An toàn Pod)

Thực hiện lần lượt cho từng Worker để đảm bảo dịch vụ không bị gián đoạn.

#### Bước 5.3.1: Di tản Pod trên Worker (Từ máy Master/Admin)
```bash
WORKER_NAME="node-worker-1"

# 1. Chặn pod mới schedule vào node này
kubectl cordon "${WORKER_NAME}"

# 2. Di tản an toàn các Pod hiện có sang node khác
kubectl drain "${WORKER_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=120s
```

#### Bước 5.3.2: Thực hiện nâng cấp trên Worker
Đăng nhập vào máy Worker cần nâng cấp:
```bash
TARGET_VERSION="v1.36.4+k3s1"

# Chạy installer cập nhật k3s-agent
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${TARGET_VERSION}" sh -s - agent

# Khởi động lại dịch vụ agent
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent

# Kiểm tra trạng thái
sudo systemctl status k3s-agent --no-pager
```

#### Bước 5.3.3: Mở lại tiếp nhận Pod (Từ máy Master/Admin)
```bash
# Khôi phục trạng thái hoạt động bình thường cho node
kubectl uncordon "${WORKER_NAME}"

# Xác nhận trạng thái Ready và phiên bản mới
kubectl get nodes -o wide
```

---

## 6. Bước 5: Quy trình Gỡ bỏ & Dọn dẹp Sạch sẽ (Uninstall & Deep Clean)

Khi cần xóa bỏ K3s để cài lại từ đầu hoặc giải phóng máy chủ, phải thực hiện dọn dẹp triệt để các tàn dư mạng ảo (CNI), cấu hình Kubelet và bảng `iptables`.

### 6.1. Gỡ bỏ Worker Node

#### Bước 6.1.1: Xóa Node khỏi Cụm (Thực hiện trên Master)
```bash
WORKER_NAME="node-worker-1"

# Cordon và drain node
kubectl cordon "${WORKER_NAME}" || true
kubectl drain "${WORKER_NAME}" --ignore-daemonsets --delete-emptydir-data --force --timeout=30s || true

# Xóa node khỏi etcd của cluster
kubectl delete node "${WORKER_NAME}" --timeout=30s
```

#### Bước 6.1.2: Gỡ cài đặt và dọn dẹp sạch sẽ (Thực hiện trên Worker)
Chạy script uninstall chính thức của K3s Agent và xóa sạch tàn dư:
```bash
# 1. Chạy script gỡ bỏ mặc định của K3s Agent
if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    sudo /usr/local/bin/k3s-agent-uninstall.sh
fi

# 2. Xóa toàn bộ thư mục dữ liệu, socket, certs còn sót lại
sudo rm -rf /etc/rancher/k3s \
            /var/lib/rancher/k3s \
            /var/lib/kubelet \
            /etc/cni/net.d \
            /var/lib/cni/ \
            /run/k3s \
            /run/flannel

# 3. Dọn dẹp card mạng ảo CNI
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true

# 4. Flush sạch bảng iptables về mặc định
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X

echo "[✓] Worker Node đã được dọn dẹp sạch sẽ 100%!"
```

---

### 6.2. Gỡ bỏ Master / Server Node

Thực hiện trực tiếp trên máy chủ **Server**:

```bash
# 1. Chạy script gỡ bỏ K3s Server chính thức
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    sudo /usr/local/bin/k3s-uninstall.sh
fi

# 2. Xóa triệt để toàn bộ thư mục cấu hình, database và chứng chỉ
sudo rm -rf /etc/rancher/k3s \
            /var/lib/rancher/k3s \
            /var/lib/kubelet \
            /etc/cni/net.d \
            /var/lib/cni/ \
            /run/k3s \
            /run/flannel

# 3. Xóa các card mạng ảo CNI
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true

# 4. Flush sạch toàn bộ iptables rules của K8s
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X

# 5. Xóa file token trong repo quản trị nếu không dùng nữa
rm -f secrets/k3s-node-token

echo "[✓] Master Node đã được gỡ bỏ hoàn toàn và dọn sạch hệ thống!"
```

---

## 7. Bước 6: Khắc phục Sự cố Thường gặp (Troubleshooting)

### 7.1. Node ở trạng thái `NotReady`
- **Nguyên nhân:** CNI Flannel chưa khởi động được do không tìm thấy interface `tailscale0` hoặc thiếu cờ mạng.
- **Cách kiểm tra:**
  ```bash
  kubectl describe node <tên-node>
  # Kiểm tra log dịch vụ
  sudo journalctl -u k3s -n 50 --no-pager        # trên Server
  sudo journalctl -u k3s-agent -n 50 --no-pager  # trên Worker
  ```
- **Xử lý:** Đảm bảo `tailscale0` đang `UP` (`ip addr show tailscale0`) và file `/etc/rancher/k3s/config.yaml` có khai báo `flannel-iface: "tailscale0"`.

### 7.2. Pod không thể gọi sang Pod ở Node khác
- **Nguyên nhân:** UFW Forwarding bị DROP hoặc chưa mở dải `10.42.0.0/16`.
- **Xử lý:**
  ```bash
  sudo ufw allow in on tailscale0
  sudo ufw allow from 10.42.0.0/16
  sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  sudo ufw reload
  ```

### 7.3. K3s Server báo lỗi chứng chỉ TLS SAN
- **Nguyên nhân:** Truy cập API Server qua một IP hoặc Hostname chưa được đăng ký trong certificate của K3s.
- **Xử lý:** Thêm IP/DNS vào mục `tls-san` trong `/etc/rancher/k3s/config.yaml`, sau đó khởi động lại K3s:
  ```bash
  sudo systemctl restart k3s
  ```

### 7.4. Kiểm tra mã hóa Secret (Secrets Encryption)
Để xác nhận tính năng `secrets-encryption` hoạt động:
```bash
# Tạo một secret thử nghiệm
kubectl create secret generic test-secret --from-literal=password=mysecretpassword

# Kiểm tra dữ liệu thô trong sqlite / etcd (dữ liệu phải ở dạng mã hóa k3s:enc:...)
sudo strings /var/lib/rancher/k3s/server/db/state.db 2>/dev/null | grep "k3s:enc:aesgcm" || echo "Mã hóa hoạt động bình thường!"

# Dọn dẹp
kubectl delete secret test-secret
```

---

## 8. Phụ lục: Tuỳ chọn Script Shell (Không khuyến khích)

> [!CAUTION] **TÙY CHỌN KHÔNG KHUYẾN KHÍCH (LEGACY / AUTOMATION HELPER)**
> Các script cùng thư mục được giữ lại chỉ phục vụ mục đích tham khảo hoặc hỗ trợ automation nhanh trong môi trường phát triển cục bộ. Không khuyến khích dùng trong vận hành chính thức vì che giấu cấu hình và khó debug.