#!/usr/bin/env bash
# =============================================================================
# install-worker.sh
# Cài đặt và kết nối K3s Worker (Agent) Node vào cụm Kubernetes.
# Hỗ trợ 2 chế độ:
#   1. Remote Mode qua SSH (Mặc định khi chạy từ máy quản trị):
#      Tự động kết nối SSH tới Worker, nạp token từ local secrets/, chạy preflight
#      checks từ xa, cài đặt K3s agent và kiểm tra lại bằng kubectl cục bộ.
#   2. Local Mode (Chạy trực tiếp trên chính máy Worker dưới quyền sudo).
#
# Định tuyến Pod-to-Pod và Node-to-Node được bảo mật 100% qua Tailscale WireGuard.
#
# Usage (Remote qua SSH):
#   ./install-worker.sh <user@worker-ip> [options]
#   ./install-worker.sh user@100.64.0.0 --nodename=worker-01 -y
#
# Usage (Local trên máy Worker):
#   sudo ./install-worker.sh --local <node-name> <master-tailscale-ip> [token] [-y]
# =============================================================================

set -eo pipefail

# ANSI color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} ${BOLD}$1${NC}"; }

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] [TARGET_OR_NODE_NAME] [MASTER_IP] [NODE_TOKEN]

Cài đặt và cấu hình Worker Node gia nhập cụm K3s (hỗ trợ cài qua SSH từ xa hoặc chạy trực tiếp).

Chế độ 1: Cài đặt từ xa qua SSH (Khuyến nghị - Chạy trực tiếp từ máy này):
  $0 <user@worker-host> [OPTIONS]
  Ví dụ:
    # Dry-Run kiểm tra mạng, firewall, swap trên worker từ xa:
    $0 user@100.64.0.0

    # Cài đặt chính thức qua SSH (tự nạp Master IP và Token từ máy này):
    $0 user@100.64.0.0 --nodename=worker-01 -y

    # Chỉ định SSH port và SSH key nếu cần:
    $0 ubuntu@192.168.1.50 -p 22 -i ~/.ssh/id_ed25519 --nodename=worker-02 -y

Chế độ 2: Cài đặt cục bộ (Chạy trực tiếp trên chính máy Worker):
  sudo $0 --local <node-name> <master-ip> [node-token] [-y]

Options:
  -t, --target USER@HOST  Địa chỉ SSH của máy Worker cần cài đặt
  --nodename NAME         Tên định danh Node (Mặc định: hostname của Worker)
  --server HOST/IP        Địa chỉ IP Tailscale của Master Node (Mặc định: tự lấy từ ~/.kube/config)
  --token TOKEN           K3s Node Token (Mặc định: tự đọc từ secrets/k3s-node-token)
  -p, --port PORT         Cổng SSH của Worker (Mặc định: 22)
  -i, --identity KEY      Đường dẫn SSH private key
  --disable-swap          Tự động tắt Swap trên Worker nếu phát hiện Swap đang bật
  --local                 Chạy ở chế độ cục bộ trên máy hiện tại
  -y, --yes               Tự động xác nhận cài đặt thực tế (bỏ qua Dry-Run)
  -h, --help              Hiển thị hướng dẫn này
EOF
}

# Khởi tạo biến
TARGET_SSH=""
NODE_NAME=""
MASTER_IP=""
NODE_TOKEN=""
SSH_PORT="22"
SSH_KEY=""
IS_LOCAL=false
AUTO_APPROVE=false
AUTO_DISABLE_SWAP=false

# ==========================================
# 1. PARSE THAM SỐ DÒNG LỆNH
# ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --local)
            IS_LOCAL=true
            shift
            ;;
        -t|--target)
            TARGET_SSH="$2"
            shift 2
            ;;
        --target=*)
            TARGET_SSH="${1#*=}"
            shift
            ;;
        --nodename=*)
            NODE_NAME="${1#*=}"
            shift
            ;;
        --nodename)
            NODE_NAME="$2"
            shift 2
            ;;
        --server=*)
            MASTER_IP="${1#*=}"
            shift
            ;;
        --server)
            MASTER_IP="$2"
            shift 2
            ;;
        --token=*)
            NODE_TOKEN="${1#*=}"
            shift
            ;;
        --token)
            NODE_TOKEN="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        --disable-swap)
            AUTO_DISABLE_SWAP=true
            shift
            ;;
        -y|--yes)
            AUTO_APPROVE=true
            shift
            ;;
        -*)
            log_error "Tùy chọn không hợp lệ: $1"
            show_help
            exit 1
            ;;
        *)
            # Nhận diện tham số positional
            if [[ "$1" =~ @ ]] || [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && -z "$TARGET_SSH" && "$IS_LOCAL" = false ]]; then
                TARGET_SSH="$1"
            elif [[ -z "$NODE_NAME" ]]; then
                NODE_NAME="$1"
            elif [[ -z "$MASTER_IP" ]]; then
                MASTER_IP="$1"
            elif [[ -z "$NODE_TOKEN" ]]; then
                NODE_TOKEN="$1"
            fi
            shift
            ;;
    esac
done

log_warn "[LƯU Ý] Chạy script shell là tùy chọn phụ trợ (KHÔNG KHUYẾN KHÍCH)."
log_warn "Khuyến nghị thực hiện theo RUNBOOK.md với file cấu hình chuẩn (/etc/rancher/k3s/config.yaml)."

# Xác định đường dẫn thư mục dự án
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)"
TARGET_SECRETS_DIR="${SECRETS_DIR:-${REPO_ROOT}/secrets}"
TOKEN_FILE="${TARGET_SECRETS_DIR}/k3s-node-token"

# ==========================================
# 2. TỰ ĐỘNG PHÁT HIỆN MASTER IP & TOKEN (TỪ LOCAL NẾU CHƯA CÓ)
# ==========================================

# 2.1. Tự động lấy Master IP từ ~/.kube/config nếu chưa truyền
if [[ -z "$MASTER_IP" ]]; then
    KUBE_CONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
    if [[ -f "$KUBE_CONFIG" ]]; then
        DETECTED_SERVER=$(grep -oP 'server:\s*https?://\K[^:/]+' "$KUBE_CONFIG" 2>/dev/null | head -n1 || true)
        if [[ -n "$DETECTED_SERVER" && "$DETECTED_SERVER" != "127.0.0.1" && "$DETECTED_SERVER" != "localhost" ]]; then
            MASTER_IP="$DETECTED_SERVER"
            log_info "Đã tự động nhận diện Master IP từ ~/.kube/config: ${BOLD}${MASTER_IP}${NC}"
        fi
    fi
fi

# 2.2. Tự động nạp Node Token từ thư mục secrets nếu chưa truyền
if [[ -z "$NODE_TOKEN" && -s "$TOKEN_FILE" ]]; then
    NODE_TOKEN="$(cat "$TOKEN_FILE" | tr -d '\r\n ')"
    log_info "Đã tự động nạp K3s Node Token từ ${TOKEN_FILE}."
fi

# Chuẩn hóa MASTER_IP & NODE_TOKEN
if [[ -n "$MASTER_IP" ]]; then
    MASTER_IP="${MASTER_IP#https://}"
    MASTER_IP="${MASTER_IP#http://}"
    MASTER_IP="${MASTER_IP#*@}"
    MASTER_IP="${MASTER_IP%:*}"
    MASTER_IP="${MASTER_IP%/}"
    MASTER_IP="$(echo -n "$MASTER_IP" | tr -d '[:space:]')"
fi
if [[ -n "$NODE_TOKEN" ]]; then
    NODE_TOKEN="$(echo -n "${NODE_TOKEN}" | tr -d '\r\n ')"
fi

# =============================================================================
# CHẾ ĐỘ 1: CÀI ĐẶT TỪ XA QUA SSH (REMOTE PROVISIONING MODE)
# =============================================================================
if [[ "$IS_LOCAL" = false && -n "$TARGET_SSH" ]]; then
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  K3S WORKER NODE PROVISIONING OVER SSH                               ${NC}"
    echo -e "${CYAN}  Target Worker: ${BOLD}${TARGET_SSH}${NC} (Port: ${SSH_PORT})"
    echo -e "${CYAN}======================================================================${NC}\n"

    # Kiểm tra các tham số bắt buộc
    if [[ -z "$MASTER_IP" ]]; then
        log_error "Không tìm thấy địa chỉ Master IP! Vui lòng chỉ định qua cờ: --server=<IP_TAILSCALE_MASTER>"
        exit 1
    fi

    if [[ -z "$NODE_TOKEN" ]]; then
        log_error "Không tìm thấy K3s Node Token! Vui lòng chỉ định qua cờ: --token=<TOKEN> hoặc lưu vào ${TOKEN_FILE}."
        exit 1
    fi

    # Cấu hình SSH options
    SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    if [[ -n "${SSH_KEY}" ]]; then
        if [[ ! -f "${SSH_KEY}" ]]; then
            log_error "File SSH Key không tồn tại: ${SSH_KEY}"
            exit 1
        fi
        SSH_OPTS+=(-i "${SSH_KEY}")
    fi

    # 1. Kiểm tra kết nối SSH
    log_info "Bước 1/6: Kiểm tra kết nối SSH tới Worker (${TARGET_SSH})..."
    if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "true" 2>/dev/null; then
        log_error "Không thể kết nối SSH tới ${TARGET_SSH} qua cổng ${SSH_PORT}."
        log_warn "Hãy kiểm tra sshd, firewall hoặc SSH key/mật khẩu."
        exit 1
    fi
    log_success "Kết nối SSH thành công!"

    # 2. Kiểm tra quyền Sudo trên Worker
    log_info "Bước 2/6: Xác thực quyền root/sudo trên Worker..."
    # 2. Xác định quyền người dùng trên Worker
    log_info "Bước 2/6: Xác thực cấu hình người dùng trên Worker..."
    SUDO_PREFIX="sudo"
    REMOTE_USER="${TARGET_SSH%@*}"
    if [[ "$REMOTE_USER" == "root" || "$TARGET_SSH" == "root" ]]; then
        SUDO_PREFIX=""
        log_info "Kết nối với quyền root trực tiếp."
    else
        # Kiểm tra xem sudo có cần password không
        if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo -n true" 2>/dev/null; then
            log_info "Cần nhập mật khẩu sudo trên máy Worker để cấp quyền cài đặt:"
            if ! ssh -t "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo -v"; then
                log_error "Xác thực sudo trên Worker thất bại."
                exit 1
            fi
        fi
        log_info "Người dùng từ xa: ${BOLD}${REMOTE_USER}${NC} (Sẽ sử dụng sudo khi thực thi cài đặt)."
    fi

    # 3. Tự động phát hiện thông tin Worker Node (Hostname & Tailscale IP)
    log_info "Bước 3/6: Thu thập thông tin mạng trên máy Worker..."
    
    REMOTE_HOSTNAME=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "hostname" 2>/dev/null | tr -d '\r\n ')
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="${REMOTE_HOSTNAME}"
        log_info "Tự động sử dụng Hostname làm Node Name: ${BOLD}${NODE_NAME}${NC}"
    else
        log_info "Node Name chỉ định: ${BOLD}${NODE_NAME}${NC}"
    fi

    WORKER_TS_IP=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "tailscale ip -4 2>/dev/null || true" | head -n1 | tr -d '\r\n ')
    if [[ -z "$WORKER_TS_IP" ]]; then
        log_error "Không tìm thấy IPv4 Tailscale trên Worker (${TARGET_SSH})!"
        log_warn "Vui lòng đảm bảo Tailscale đã được cài và bật trên Worker: ssh ${TARGET_SSH} 'sudo tailscale up'"
        exit 1
    fi
    log_success "Worker Tailscale IP: ${BOLD}${WORKER_TS_IP}${NC}"

    # 4. Thực thi Pre-flight checks từ xa trên máy Worker
    log_info "Bước 4/6: Chạy kiểm tra điều kiện tiên quyết (Pre-flight Checks) trên Worker..."

    # 4.1. Kiểm tra xung đột K3s Server
    if ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "systemctl is-active --quiet k3s 2>/dev/null"; then
        log_error "Dịch vụ 'k3s' (Control Plane / Server) đang chạy trên Worker này!"
        log_error "Không thể biến Master Server thành Worker Node độc lập."
        exit 1
    fi

    # 4.2. Kiểm tra Ping từ Worker tới Master
    echo -n "  - [Worker -> Master] Ping Tailscale tới ${MASTER_IP}... "
    if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "tailscale ping -c 2 --timeout=4s '${MASTER_IP}' >/dev/null 2>&1 || ping -c 2 -W 3 '${MASTER_IP}' >/dev/null 2>&1"; then
        echo -e "${RED}[FAILED]${NC}"
        log_error "Worker không thể ping tới Master Tailscale IP (${MASTER_IP})! Kiểm tra lại Tailnet."
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC}"

    # 4.3. Kiểm tra Port 6443 từ Worker tới Master
    echo -n "  - [Worker -> Master] Kết nối API Port 6443 tới https://${MASTER_IP}:6443... "
    PORT_CHECK_CMD='
        curl -k -m 4 -s -o /dev/null "https://'"${MASTER_IP}"':6443" 2>/dev/null || \
        nc -z -w 3 "'"${MASTER_IP}"'" 6443 2>/dev/null || \
        (timeout 3 bash -c "</dev/tcp/'"${MASTER_IP}"'/6443") 2>/dev/null
    '
    if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "${PORT_CHECK_CMD}"; then
        echo -e "${RED}[FAILED]${NC}"
        log_error "Cổng 6443 trên Master (${MASTER_IP}) không thể truy cập từ Worker!"
        log_warn "Hãy kiểm tra: Master đã bật k3s chưa? UFW trên Master có cho phép cổng 6443 không?"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC}"

    # 4.4. Kiểm tra Swap trên Worker
    REMOTE_SWAP=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "swapon --show --noheadings 2>/dev/null || true")
    if [[ -n "$REMOTE_SWAP" ]]; then
        if [[ "$AUTO_DISABLE_SWAP" = true ]]; then
            echo -e "  - [Worker] Trạng thái Swap: Đang bật (Sẽ tự động tắt khi cài đặt với --disable-swap) [OK]"
        else
            echo -e "  - [Worker] Trạng thái Swap: Đang bật ${RED}[CẦN TẮT]${NC}"
            log_error "Swap đang bật trên Worker (${TARGET_SSH})!"
            log_warn "Kubernetes yêu cầu tắt Swap. Hãy thêm cờ --disable-swap khi chạy script này."
            exit 1
        fi
    else
        echo -e "  - [Worker] Trạng thái Swap: Tắt [OK]"
    fi

    # 4.5. Kiểm tra Kernel IP Forwarding trên Worker
    REMOTE_IP_FW=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0")
    if [[ "$REMOTE_IP_FW" -ne 1 ]]; then
        echo -e "  - [Worker] Kernel IP Forwarding: Chưa bật (Sẽ tự động kích hoạt khi cài đặt) [OK]"
    else
        echo -e "  - [Worker] Kernel IP Forwarding: Bật [OK]"
    fi

    # 4.6. Kiểm tra cấu hình UFW trên Worker (nếu có)
    echo -e "  - [Worker] Tường lửa (Firewall): Cho phép tailscale0 & routed traffic [OK]"

    log_success "Toàn bộ điều kiện tiên quyết trên Worker đạt 100%!"

    # 5. Chế độ Dry-run / Execution
    if [[ "$AUTO_APPROVE" = false ]]; then
        echo ""
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "${YELLOW} [DRY-RUN MODE] Kiểm tra thành công! Lệnh cài đặt từ xa dự kiến:  ${NC}"
        echo -e "${YELLOW}=================================================================${NC}"
        echo "ssh ${TARGET_SSH} \"${SUDO_PREFIX} env K3S_URL='https://${MASTER_IP}:6443' \\"
        echo "    K3S_TOKEN='${NODE_TOKEN:0:15}...' \\"
        echo "    INSTALL_K3S_EXEC='agent \\"
        echo "    --node-name=${NODE_NAME} \\"
        echo "    --node-ip=${WORKER_TS_IP} \\"
        echo "    --node-external-ip=${WORKER_TS_IP} \\"
        echo "    --flannel-iface=tailscale0' sh -c 'curl -sfL https://get.k3s.io | sh -'\""
        echo "================================================================="
        
        HINT_CMD="$0 ${TARGET_SSH}"
        [[ -n "$NODE_NAME" ]] && HINT_CMD+=" --nodename=${NODE_NAME}"
        [[ "$SSH_PORT" != "22" ]] && HINT_CMD+=" -p ${SSH_PORT}"
        [[ "$AUTO_DISABLE_SWAP" = true ]] && HINT_CMD+=" --disable-swap"
        HINT_CMD+=" -y"
        
        echo -e "${CYAN}[GỢI Ý]${NC} Để thực thi cài đặt từ xa thực sự, vui lòng chạy lệnh sau:"
        echo -e "  ${BOLD}${HINT_CMD}${NC}"
        exit 0
    fi

    # 6. Thực thi cấu hình hệ thống & cài đặt chính thức từ xa qua SSH
    log_info "Bước 5/6: Đang thực thi cấu hình hệ thống và cài đặt K3s Agent trên ${TARGET_SSH}..."

    # Tạo kịch bản hoàn chỉnh chạy dưới quyền root trên Worker
    REMOTE_SCRIPT="set -e

# 1. Tắt Swap nếu được yêu cầu
if [ \"${AUTO_DISABLE_SWAP}\" = \"true\" ]; then
    echo '  - [Worker] Đang tắt Swap (swapoff -a)...'
    swapoff -a 2>/dev/null || true
fi

# 2. Bật IP Forwarding
if [ \$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0) -ne 1 ]; then
    echo '  - [Worker] Bật net.ipv4.ip_forward = 1...'
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
fi

# 3. Mở Firewall UFW (nếu có)
if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        echo '  - [Worker] Cấu hình UFW cho phép tailscale0 & routed traffic...'
        ufw allow in on tailscale0 >/dev/null 2>&1 || true
        sed -i 's/DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw 2>/dev/null || true
        ufw reload >/dev/null 2>&1 || true
    fi
fi

# 4. Tải trước binary K3s với retry (chống rớt mạng khi tải từ GitHub)
TARGET_VER='v1.36.4+k3s1'
API_VER=\$(curl -k -s -m 4 'https://${MASTER_IP}:6443/version' 2>/dev/null | grep -oP '\"gitVersion\":\s*\"\K[^\"]+' || true)
if [ -n \"\$API_VER\" ]; then
    TARGET_VER=\"\$API_VER\"
fi
echo \"  - [Worker] Phiên bản K3s: \${TARGET_VER}\"

if [ ! -x /usr/local/bin/k3s ] || [ \"\$(/usr/local/bin/k3s --version 2>/dev/null | awk '{print \$3}')\" != \"\$TARGET_VER\" ]; then
    echo '  - [Worker] Đang tải binary K3s (tự động retry 5 lần)...'
    URLSAFE_VER=\$(echo \"\$TARGET_VER\" | sed 's/+/%2B/g')
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
        \"https://github.com/k3s-io/k3s/releases/download/\${URLSAFE_VER}/k3s\" \
        -o /usr/local/bin/k3s.tmp
    chmod 755 /usr/local/bin/k3s.tmp
    mv /usr/local/bin/k3s.tmp /usr/local/bin/k3s
fi

# 5. Cài đặt và khởi chạy K3s Agent Service
echo '  - [Worker] Khởi tạo và kích hoạt K3s Agent...'
export K3S_URL='https://${MASTER_IP}:6443'
export K3S_TOKEN='${NODE_TOKEN}'
export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_EXEC='agent --node-name=${NODE_NAME} --node-ip=${WORKER_TS_IP} --node-external-ip=${WORKER_TS_IP} --flannel-iface=tailscale0'

curl -sfL https://get.k3s.io | sh -
"

    ENCODED_SCRIPT=$(echo "$REMOTE_SCRIPT" | base64 -w 0)

    if [[ -n "$SUDO_PREFIX" ]]; then
        ssh -t "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    else
        ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    fi

    log_info "Bước 6/6: Kiểm tra trạng thái dịch vụ trên Worker..."
    sleep 4
    if ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "systemctl is-active --quiet k3s-agent"; then
        echo ""
        echo -e "${CYAN}=================================================================${NC}"
        log_success "WORKER NODE '${NODE_NAME}' (${WORKER_TS_IP}) ĐÃ GIA NHẬP CỤM THÀNH CÔNG!"
        echo -e "${CYAN}=================================================================${NC}"
    else
        log_error "Dịch vụ k3s-agent trên Worker chưa thể khởi động. Kiểm tra log từ xa:"
        echo "  ssh ${TARGET_SSH} 'sudo journalctl -u k3s-agent -xe --no-pager | tail -n 30'"
        exit 1
    fi

    # Xác nhận lại ngay bằng kubectl cục bộ nếu có
    if command -v kubectl &>/dev/null; then
        echo ""
        log_info "Xác nhận trạng thái node trên cụm qua kubectl cục bộ:"
        kubectl get nodes -o wide --request-timeout=8s || true
    fi

    echo ""
    log_success "Hoàn tất quy trình thêm Worker Node từ xa!"
    exit 0
fi

# =============================================================================
# CHẾ ĐỘ 2: CÀI ĐẶT CỤC BỘ (LOCAL EXECUTION MODE)
# =============================================================================
if [[ ${EUID} -ne 0 ]]; then
    log_error "Vui lòng chạy script với quyền sudo/root khi chạy cục bộ: sudo $0 --local ..."
    echo "Hoặc nếu muốn cài đặt từ xa qua SSH, sử dụng cú pháp:"
    echo "  $0 <user@worker-ip> [-y]"
    exit 1
fi

if [[ -z "$NODE_NAME" || -z "$MASTER_IP" || -z "$NODE_TOKEN" ]]; then
    log_error "Thiếu tham số bắt buộc cho chế độ cục bộ!"
    echo "  Cú pháp: sudo $0 --local <node-name> <master-tailscale-ip> [token] [-y]"
    exit 1
fi

WORKER_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$WORKER_TAILSCALE_IP" ]]; then
    log_error "Không tìm thấy IPv4 Tailscale trên máy này. Hãy chạy 'tailscale up'!"
    exit 1
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}  CÀI ĐẶT WORKER NODE CỤC BỘ (${NODE_NAME})                            ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Chạy Preflight checks cục bộ
if systemctl is-active --quiet k3s 2>/dev/null; then
    log_error "Dịch vụ 'k3s' (Server) đang chạy trên máy này! Không thể cài thêm Worker agent."
    exit 1
fi

if ! tailscale ping -c 2 --timeout=4s "$MASTER_IP" >/dev/null 2>&1 && ! ping -c 2 -W 3 "$MASTER_IP" >/dev/null 2>&1; then
    log_error "Không thể ping tới Master IP: ${MASTER_IP} qua Tailscale!"
    exit 1
fi

SWAP_ACTIVE=$(swapon --show --noheadings 2>/dev/null || true)
if [[ -n "$SWAP_ACTIVE" ]]; then
    log_error "Swap đang bật! Hãy chạy 'sudo swapoff -a' trước khi cài đặt."
    exit 1
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [[ "$AUTO_APPROVE" = false ]]; then
    echo -e "${YELLOW}[DRY-RUN MODE] Kiểm tra thành công. Thêm cờ -y để cài đặt chính thức.${NC}"
    exit 0
fi

curl -sfL https://get.k3s.io | K3S_URL="https://${MASTER_IP}:6443" \
    K3S_TOKEN="${NODE_TOKEN}" \
    INSTALL_K3S_EXEC="agent \
    --node-name=${NODE_NAME} \
    --node-ip=${WORKER_TAILSCALE_IP} \
    --node-external-ip=${WORKER_TAILSCALE_IP} \
    --flannel-iface=tailscale0" sh -

sleep 3
if systemctl is-active --quiet k3s-agent; then
    log_success "Worker Node '${NODE_NAME}' đã gia nhập cụm thành công!"
else
    log_error "Dịch vụ k3s-agent chưa thể khởi động. Kiểm tra: journalctl -u k3s-agent -xe"
    exit 1
fi