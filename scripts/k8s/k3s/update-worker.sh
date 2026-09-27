#!/usr/bin/env bash

# =============================================================================
# K3s Worker Node Upgrade Script (update-worker.sh)
# Hỗ trợ nâng cấp Worker Node an toàn qua SSH hoặc chạy cục bộ
# Pattern: scripts/k8s/k3s/update-worker.sh
# =============================================================================

set -eo pipefail

# Màu sắc thông báo
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [USER@WORKER_HOST]

Nâng cấp K3s Agent trên Worker Node (hỗ trợ qua SSH từ máy quản trị hoặc trực tiếp trên Worker).
Mặc định tự động đồng bộ theo phiên bản của Master Node.

Chế độ 1: Nâng cấp từ xa qua SSH (Khuyến nghị - Chạy từ máy quản trị):
  $0 <user@worker-ip> [OPTIONS]
  Ví dụ:
    # Kiểm tra trạng thái nâng cấp của Worker 1 (Dry-Run):
    $0 user@100.64.0.0

    # Nâng cấp Worker 1 đồng bộ với phiên bản Master:
    $0 user@100.64.0.0 -y

    # Nâng cấp Worker 2 với SSH port riêng và di tản Pod an toàn (--drain):
    $0 user@100.64.0.0 -p 22 --drain -y

    # Chỉ định cụ thể phiên bản mục tiêu:
    $0 user@100.64.0.0 -p 22 --version=v1.36.4+k3s1 -y

Chế độ 2: Nâng cấp cục bộ (Chạy trực tiếp trên chính máy Worker):
  sudo $0 --local [OPTIONS] [-y]

Options:
  -t, --target USER@HOST  Địa chỉ SSH của Worker Node
  --nodename NAME         Tên định danh Node (Mặc định: Tự nhận diện từ cụm hoặc hostname)
  --token TOKEN           K3s Node Token (Mặc định: Tự nạp từ secrets/k3s-node-token)
  -v, --version VERSION   Phiên bản K3s mục tiêu (Mặc định: Tự đồng bộ với Master)
  --server HOST/IP        Địa chỉ Master IP (Mặc định: Tự lấy từ ~/.kube/config)
  -p, --port PORT         Cổng SSH của Worker (Mặc định: 22)
  -i, --identity KEY      Đường dẫn SSH private key
  --drain                 Cordon và di tản Pod an toàn trước khi nâng cấp (tự uncordon sau khi xong)
  -f, --force             Cài đè lại ngay cả khi phiên bản hiện tại đã trùng khớp
  --local                 Chạy ở chế độ cục bộ trên máy hiện tại
  -y, --yes               Tự động xác nhận nâng cấp (bỏ qua bước hỏi)
  -h, --help              Hiển thị hướng dẫn này

EOF
}

# ==========================================
# 1. PARSE THAM SỐ ĐẦU VÀO
# ==========================================
NODE_NAME=""
NODE_TOKEN=""
TARGET_SSH=""
MASTER_IP=""
TARGET_VERSION=""
SSH_PORT="22"
SSH_KEY=""
DRAIN_NODE=false
IS_LOCAL=false
AUTO_APPROVE=false
FORCE_UPDATE=false

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
        --nodename=*)
            NODE_NAME="${1#*=}"
            shift
            ;;
        --nodename)
            NODE_NAME="$2"
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
        -t|--target)
            TARGET_SSH="$2"
            shift 2
            ;;
        --target=*)
            TARGET_SSH="${1#*=}"
            shift
            ;;
        --server)
            MASTER_IP="$2"
            shift 2
            ;;
        --server=*)
            MASTER_IP="${1#*=}"
            shift
            ;;
        -v|--version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --version=*)
            TARGET_VERSION="${1#*=}"
            shift
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        --drain)
            DRAIN_NODE=true
            shift
            ;;
        -f|--force)
            FORCE_UPDATE=true
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
            if [[ "$1" =~ @ ]] || [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                TARGET_SSH="$1"
            elif [[ "$1" =~ ^v[0-9]+\.[0-9]+ ]]; then
                TARGET_VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Tự động nạp Node Token từ secrets nếu có
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)"
TOKEN_FILE="${REPO_ROOT}/secrets/k3s-node-token"
if [[ -z "$NODE_TOKEN" && -s "$TOKEN_FILE" ]]; then
    NODE_TOKEN="$(cat "$TOKEN_FILE" | tr -d '\r\n ')"
fi

# =============================================================================
# CHẾ ĐỘ 1: NÂNG CẤP TỪ XA QUA SSH (REMOTE UPGRADE MODE)
# =============================================================================
if [[ "$IS_LOCAL" = false ]]; then
    if [[ -z "$TARGET_SSH" ]]; then
        log_error "Vui lòng chỉ định địa chỉ Worker Node cần nâng cấp: $0 <user@worker-ip>"
        show_help
        exit 1
    fi

    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  K3S WORKER NODE UPGRADE OVER SSH                                    ${NC}"
    echo -e "${CYAN}  Target Worker: ${BOLD}${TARGET_SSH}${NC} (Port: ${SSH_PORT})"
    echo -e "${CYAN}======================================================================${NC}\n"

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
        exit 1
    fi
    log_success "Kết nối SSH thành công!"

    # 2. Xác định quyền người dùng từ xa
    REMOTE_USER="${TARGET_SSH%@*}"
    SUDO_PREFIX="sudo"
    if [[ "$REMOTE_USER" == "root" || "$TARGET_SSH" == "root" ]]; then
        SUDO_PREFIX=""
        log_info "Kết nối trực tiếp dưới quyền root."
    else
        log_info "Người dùng từ xa: ${BOLD}${REMOTE_USER}${NC} (Sử dụng sudo khi cập nhật)."
    fi

    # 3. Thu thập thông tin định danh Worker Node (Hostname, IP, K8s Node Name)
    log_info "Bước 2/6: Thu thập thông tin định danh Worker..."
    WORKER_HOSTNAME=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "hostname" 2>/dev/null | tr -d '\r\n ')
    WORKER_TS_IP=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "tailscale ip -4 2>/dev/null || true" | head -n1 | tr -d '\r\n ')
    
    # Tìm tên node trên Kubernetes qua kubectl hoặc cờ dòng lệnh
    K8S_NODE_NAME=""
    if [[ -n "$NODE_NAME" ]]; then
        K8S_NODE_NAME="$NODE_NAME"
    elif command -v kubectl &>/dev/null; then
        if [[ -n "$WORKER_TS_IP" ]]; then
            K8S_NODE_NAME=$(kubectl get nodes -o wide 2>/dev/null | awk -v ip="$WORKER_TS_IP" '$6 == ip || $7 == ip {print $1}' | head -n1 || true)
        fi
        if [[ -z "$K8S_NODE_NAME" && -n "$WORKER_HOSTNAME" ]]; then
            K8S_NODE_NAME=$(kubectl get nodes -o wide 2>/dev/null | awk -v h="$WORKER_HOSTNAME" '$1 == h {print $1}' | head -n1 || true)
        fi
    fi

    if [[ -z "$K8S_NODE_NAME" ]]; then
        REMOTE_EXEC_NAME=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "grep -oP '--node-name=\K[^ \"]+' /etc/systemd/system/k3s-agent.service 2>/dev/null" | head -n1 | tr -d '\r\n ' || true)
        if [[ -n "$REMOTE_EXEC_NAME" ]]; then
            K8S_NODE_NAME="$REMOTE_EXEC_NAME"
        else
            K8S_NODE_NAME="${WORKER_HOSTNAME}"
        fi
    fi

    if [[ -z "$WORKER_TS_IP" ]]; then
        WORKER_TS_IP=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "grep -oP '--node-ip=\K[^ \"]+' /etc/systemd/system/k3s-agent.service 2>/dev/null" | head -n1 | tr -d '\r\n ' || true)
    fi
    if [[ -z "$WORKER_TS_IP" ]]; then
        WORKER_TS_IP="${TARGET_SSH#*@}"
    fi

    log_info "Định danh Node: ${BOLD}${K8S_NODE_NAME}${NC} (Tailscale IP: ${WORKER_TS_IP})"

    # 4. Kiểm tra phiên bản hiện tại trên Worker
    log_info "Bước 3/6: Kiểm tra phiên bản hiện tại trên Worker..."
    CURRENT_VERSION=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "k3s --version 2>/dev/null | awk '{print \$3}' | head -n1" 2>/dev/null || true)
    
    if [[ -z "$CURRENT_VERSION" && -n "$K8S_NODE_NAME" ]] && command -v kubectl &>/dev/null; then
        CURRENT_VERSION=$(kubectl get node "$K8S_NODE_NAME" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
    fi

    if [[ -z "$CURRENT_VERSION" ]]; then
        CURRENT_VERSION="Chưa rõ"
        log_warn "Không thể xác định phiên bản hiện tại của k3s-agent."
    else
        log_info "Phiên bản Worker hiện tại: ${BOLD}${CURRENT_VERSION}${NC}"
    fi

    # 5. Xác định phiên bản mục tiêu (Tự đồng bộ theo Master nếu chưa truyền)
    log_info "Bước 4/6: Xác định phiên bản mục tiêu..."
    
    # Tự động lấy Master IP từ kubeconfig hoặc remote service nếu chưa có
    if [[ -z "$MASTER_IP" ]]; then
        KUBE_CONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
        if [[ -f "$KUBE_CONFIG" ]]; then
            DETECTED_SERVER=$(grep -oP 'server:\s*https?://\K[^:/]+' "$KUBE_CONFIG" 2>/dev/null | head -n1 || true)
            if [[ -n "$DETECTED_SERVER" && "$DETECTED_SERVER" != "127.0.0.1" && "$DETECTED_SERVER" != "localhost" ]]; then
                MASTER_IP="$DETECTED_SERVER"
            fi
        fi
    fi

    if [[ -z "$MASTER_IP" ]]; then
        REMOTE_URL=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "grep -oP '^K3S_URL=\K.*' /etc/systemd/system/k3s-agent.service.env 2>/dev/null" | tr -d '"'\'' ' || true)
        if [[ -n "$REMOTE_URL" ]]; then
            MASTER_IP=$(echo "$REMOTE_URL" | sed -E 's|^https?://||; s|:[0-9]+$||')
        fi
    fi

    if [[ -z "$NODE_TOKEN" ]]; then
        REMOTE_TOKEN=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "grep -oP '^K3S_TOKEN=\K.*' /etc/systemd/system/k3s-agent.service.env 2>/dev/null" | tr -d '"'\'' ' || true)
        if [[ -n "$REMOTE_TOKEN" ]]; then
            NODE_TOKEN="$REMOTE_TOKEN"
        fi
    fi

    if [[ -z "$MASTER_IP" ]]; then
        log_error "Không thể xác định địa chỉ Master IP cho Worker! Hãy chỉ định với --server <ip>."
        exit 1
    fi
    if [[ -z "$NODE_TOKEN" ]]; then
        log_error "Không thể nạp K3s Node Token! Hãy chỉ định với --token <token> hoặc đặt vào secrets/k3s-node-token."
        exit 1
    fi

    # Nếu người dùng truyền channel thay vì version cụ thể
    if [[ "$TARGET_VERSION" =~ ^(latest|stable|testing)$ ]] || [[ -n "$TARGET_VERSION" && ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        WORKER_CHANNEL="$TARGET_VERSION"
        TARGET_VERSION=""
    fi

    if [[ -z "$TARGET_VERSION" ]]; then
        # Thử lấy version của Control Plane từ kubectl
        if command -v kubectl &>/dev/null; then
            TARGET_VERSION=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane=="true")].status.nodeInfo.kubeletVersion}' 2>/dev/null | awk '{print $1}' || true)
        fi

        # Nếu không lấy được, thử lấy qua API Master /version
        if [[ -z "$TARGET_VERSION" && -n "$MASTER_IP" ]]; then
            TARGET_VERSION=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "curl -k -s -m 4 'https://${MASTER_IP}:6443/version' 2>/dev/null | grep -oP '\"gitVersion\":\s*\"\K[^\"]+'" 2>/dev/null || true)
        fi

        # Nếu vẫn không được, truy vấn kênh stable hoặc kênh chỉ định
        if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
            TARGET_VERSION=$(curl -sIL -m 6 -o /dev/null -w '%{url_effective}' "https://update.k3s.io/v1-release/channels/${WORKER_CHANNEL:-stable}" 2>/dev/null | awk -F'/' '{print $NF}' || true)
        fi

        if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
            TARGET_VERSION=$(curl -sL -m 5 "https://update.k3s.io/v1-release/channels/${WORKER_CHANNEL:-stable}" 2>/dev/null | grep -oP '"latest":\s*"\K[^"]+' | head -n1 || true)
        fi

        TARGET_VERSION="${TARGET_VERSION%%\?*}"
        TARGET_VERSION="$(echo -n "$TARGET_VERSION" | tr -d '\r\n ')"
    fi

    if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        log_error "Không thể xác định phiên bản mục tiêu hợp lệ để nâng cấp Worker (nhận diện: '${TARGET_VERSION:-trống}')."
        log_warn "Vui lòng chỉ định phiên bản cụ thể qua cờ: $0 ${TARGET_SSH} --version=<version>"
        exit 1
    fi

    log_success "Phiên bản mục tiêu (Đồng bộ cụm): ${BOLD}${TARGET_VERSION}${NC}"

    # Kiểm tra trùng phiên bản
    if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" && "$FORCE_UPDATE" = false ]]; then
        echo ""
        log_success "Worker Node '${K8S_NODE_NAME}' đã ở phiên bản mới nhất (${CURRENT_VERSION})!"
        echo -e "${CYAN}[GỢI Ý]${NC} Nếu bạn muốn ép buộc cài đè lại, hãy thêm cờ: ${BOLD}-f${NC} hoặc ${BOLD}--force${NC}"
        exit 0
    fi

    # 6. Chế độ Dry-Run / Confirmation
    if [[ "$AUTO_APPROVE" = false ]]; then
        echo ""
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "${YELLOW} [DRY-RUN MODE] Kế hoạch nâng cấp Worker Node:                   ${NC}"
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "  - Worker Target     : ${BOLD}${TARGET_SSH}${NC}"
        echo -e "  - Kubernetes Node   : ${BOLD}${K8S_NODE_NAME}${NC}"
        echo -e "  - Tailscale IP      : ${BOLD}${WORKER_TS_IP}${NC}"
        echo -e "  - Master API        : ${BOLD}https://${MASTER_IP}:6443${NC}"
        echo -e "  - Phiên bản hiện tại: ${BOLD}${CURRENT_VERSION}${NC}"
        echo -e "  - Phiên bản cập nhật: ${GREEN}${BOLD}${TARGET_VERSION}${NC}"
        echo -e "  - Di tản Pod (Drain): $(if [ "$DRAIN_NODE" = true ]; then echo -e "${GREEN}Có (An toàn Pod)${NC}"; else echo "Không (Cập nhật In-place)"; fi)"
        echo -e "  - Cờ agent áp dụng  : ${CYAN}--node-name=${K8S_NODE_NAME} --node-ip=${WORKER_TS_IP} --node-external-ip=${WORKER_TS_IP} --flannel-iface=tailscale0${NC}"
        echo "================================================================="
        
        HINT_CMD="$0 ${TARGET_SSH} --version=${TARGET_VERSION}"
        [[ "$SSH_PORT" != "22" ]] && HINT_CMD+=" -p ${SSH_PORT}"
        [[ "$DRAIN_NODE" = true ]] && HINT_CMD+=" --drain"
        HINT_CMD+=" -y"
        
        echo -e "${CYAN}[GỢI Ý]${NC} Để thực thi nâng cấp chính thức, vui lòng chạy lệnh sau:"
        echo -e "  ${BOLD}${HINT_CMD}${NC}"
        exit 0
    fi

    # 7. Di tản Pod (Drain) nếu được yêu cầu
    if [[ "$DRAIN_NODE" = true ]] && command -v kubectl &>/dev/null && [[ -n "$K8S_NODE_NAME" ]]; then
        log_info "Đang Cordon và Drain node '${K8S_NODE_NAME}' để đảm bảo an toàn cho Pod..."
        kubectl cordon "${K8S_NODE_NAME}" || true
        kubectl drain "${K8S_NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --force --timeout=90s || {
            log_warn "Drain node có cảnh báo/timeout, tiếp tục nâng cấp..."
        }
    fi

    # 8. Thực thi nâng cấp trên Worker qua SSH
    log_info "Bước 5/6: Đang thực thi nâng cấp k3s-agent trên ${TARGET_SSH}..."

    URLSAFE_TARGET_VERSION="${TARGET_VERSION/+/%2B}"
    REMOTE_SCRIPT="set -e

# 1. Bật IP Forwarding nếu chưa bật
if [ \$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0) -ne 1 ]; then
    echo '  - [Worker] Bật net.ipv4.ip_forward = 1...'
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
fi

# 2. Mở Firewall UFW (nếu có)
if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        echo '  - [Worker] Cấu hình UFW cho phép tailscale0 & routed traffic...'
        ufw allow in on tailscale0 >/dev/null 2>&1 || true
        sed -i 's/DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw 2>/dev/null || true
        ufw reload >/dev/null 2>&1 || true
    fi
fi

# 3. Tải trước binary K3s với retry (chống rớt mạng khi tải từ GitHub)
echo '  - [Worker] Chuẩn bị binary K3s phiên bản ${TARGET_VERSION} (retry 5 lần)...'
curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
    \"https://github.com/k3s-io/k3s/releases/download/${URLSAFE_TARGET_VERSION}/k3s\" \
    -o /usr/local/bin/k3s.tmp

chmod 755 /usr/local/bin/k3s.tmp
mv /usr/local/bin/k3s.tmp /usr/local/bin/k3s

# 4. Tái tạo cấu hình k3s-agent.service với toàn bộ cờ hệ thống chuẩn từ install-worker.sh
echo '  - [Worker] Cấu hình k3s-agent service với toàn bộ cờ hệ thống từ install-worker.sh...'
export K3S_URL='https://${MASTER_IP}:6443'
export K3S_TOKEN='${NODE_TOKEN}'
export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_EXEC='agent --node-name=${K8S_NODE_NAME} --node-ip=${WORKER_TS_IP} --node-external-ip=${WORKER_TS_IP} --flannel-iface=tailscale0'

curl -sfL https://get.k3s.io | sh -

echo '  - [Worker] Khởi động lại dịch vụ k3s-agent...'
systemctl daemon-reload
systemctl restart k3s-agent
"

    ENCODED_SCRIPT=$(echo "$REMOTE_SCRIPT" | base64 -w 0)

    if [[ -n "$SUDO_PREFIX" ]]; then
        ssh -t "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    else
        ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    fi

    # 9. Khôi phục trạng thái nhận Pod (Uncordon) nếu đã drain
    if [[ "$DRAIN_NODE" = true ]] && command -v kubectl &>/dev/null && [[ -n "$K8S_NODE_NAME" ]]; then
        log_info "Uncordon node '${K8S_NODE_NAME}' để tiếp nhận Pod trở lại..."
        kubectl uncordon "${K8S_NODE_NAME}" || true
    fi

    # 10. Xác minh trạng thái sau nâng cấp
    log_info "Bước 6/6: Xác minh trạng thái dịch vụ trên Worker..."
    sleep 4

    if ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "systemctl is-active --quiet k3s-agent"; then
        NEW_VER=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "k3s --version 2>/dev/null | awk '{print \$3}' | head -n1" || true)
        echo ""
        echo -e "${CYAN}=================================================================${NC}"
        log_success "WORKER NODE '${K8S_NODE_NAME}' ĐÃ NÂNG CẤP LÊN ${BOLD}${NEW_VER}${NC} THÀNH CÔNG!"
        echo -e "${CYAN}=================================================================${NC}"
    else
        log_error "Dịch vụ k3s-agent trên Worker chưa hoạt động bình thường!"
        echo "  ssh ${TARGET_SSH} 'sudo journalctl -u k3s-agent -xe --no-pager | tail -n 30'"
        exit 1
    fi

    # Xác nhận qua kubectl cục bộ nếu có
    if command -v kubectl &>/dev/null; then
        echo ""
        log_info "Trạng thái các node trên cụm qua kubectl cục bộ:"
        kubectl get nodes -o wide --request-timeout=10s || true
    fi

    echo ""
    log_success "Hoàn tất quy trình nâng cấp Worker Node!"
    exit 0
fi

# =============================================================================
# CHẾ ĐỘ 2: NÂNG CẤP CỤC BỘ (LOCAL UPGRADE MODE)
# =============================================================================
if [[ ${EUID} -ne 0 ]]; then
    log_error "Vui lòng chạy script với quyền sudo/root khi chạy cục bộ: sudo $0 --local ..."
    exit 1
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}  NÂNG CẤP K3S WORKER AGENT CỤC BỘ                                     ${NC}"
echo -e "${CYAN}======================================================================${NC}"

CURRENT_VER=$(k3s --version 2>/dev/null | awk '{print $3}' | head -n1 || echo "unknown")
log_info "Phiên bản hiện tại: ${BOLD}${CURRENT_VER}${NC}"

if [[ "$TARGET_VERSION" =~ ^(latest|stable|testing)$ ]] || [[ -n "$TARGET_VERSION" && ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
    WORKER_CHANNEL="$TARGET_VERSION"
    TARGET_VERSION=""
fi

if [[ -z "$TARGET_VERSION" ]]; then
    log_info "Đang truy vấn phiên bản mục tiêu từ kênh ${WORKER_CHANNEL:-stable}..."
    TARGET_VERSION=$(curl -sIL -m 6 -o /dev/null -w '%{url_effective}' "https://update.k3s.io/v1-release/channels/${WORKER_CHANNEL:-stable}" 2>/dev/null | awk -F'/' '{print $NF}' || true)
    if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        TARGET_VERSION=$(curl -sL -m 6 "https://update.k3s.io/v1-release/channels/${WORKER_CHANNEL:-stable}" 2>/dev/null | grep -oP '"latest":\s*"\K[^"]+' | head -n1 || true)
    fi
    TARGET_VERSION="${TARGET_VERSION%%\?*}"
    TARGET_VERSION="$(echo -n "$TARGET_VERSION" | tr -d '\r\n ')"
fi

if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
    log_error "Không thể xác định phiên bản nâng cấp mục tiêu hợp lệ!"
    exit 1
fi
log_info "Phiên bản mục tiêu: ${BOLD}${TARGET_VERSION}${NC}"

if [[ "$CURRENT_VER" == "$TARGET_VERSION" && "$FORCE_UPDATE" = false ]]; then
    log_success "Worker đã ở phiên bản mới nhất (${CURRENT_VER})!"
    exit 0
fi

if [[ "$AUTO_APPROVE" = false ]]; then
    echo -e "${YELLOW}[DRY-RUN MODE] Kiểm tra hoàn tất. Thêm cờ -y để nâng cấp chính thức.${NC}"
    exit 0
fi

# Thu thập thông tin cấu hình agent cục bộ
LOCAL_TS_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$LOCAL_TS_IP" && -f /etc/systemd/system/k3s-agent.service ]]; then
    LOCAL_TS_IP=$(grep -oP '--node-ip=\K[^ \"]+' /etc/systemd/system/k3s-agent.service | head -n1 || true)
fi

LOCAL_NODE_NAME="${NODE_NAME}"
if [[ -z "$LOCAL_NODE_NAME" && -f /etc/systemd/system/k3s-agent.service ]]; then
    LOCAL_NODE_NAME=$(grep -oP '--node-name=\K[^ \"]+' /etc/systemd/system/k3s-agent.service | head -n1 || true)
fi
if [[ -z "$LOCAL_NODE_NAME" ]]; then
    LOCAL_NODE_NAME="$(hostname 2>/dev/null || echo "worker-node")"
fi

if [[ -z "$NODE_TOKEN" && -f /etc/systemd/system/k3s-agent.service.env ]]; then
    NODE_TOKEN=$(grep -oP '^K3S_TOKEN=\K.*' /etc/systemd/system/k3s-agent.service.env | tr -d '"'\'' ' || true)
fi

if [[ -z "$MASTER_IP" && -f /etc/systemd/system/k3s-agent.service.env ]]; then
    EXTRACTED_URL=$(grep -oP '^K3S_URL=\K.*' /etc/systemd/system/k3s-agent.service.env | tr -d '"'\'' ' || true)
    if [[ -n "$EXTRACTED_URL" ]]; then
        MASTER_IP=$(echo "$EXTRACTED_URL" | sed -E 's|^https?://||; s|:[0-9]+$||')
    fi
fi

if [[ -z "$MASTER_IP" ]]; then
    log_error "Không tìm thấy Master IP! Vui lòng truyền qua --server <ip>"
    exit 1
fi
if [[ -z "$NODE_TOKEN" ]]; then
    log_error "Không tìm thấy K3s Node Token! Vui lòng truyền qua --token <token>"
    exit 1
fi

log_info "Đang tải binary K3s ${TARGET_VERSION} (retry 5 lần)..."
URLSAFE_VER="${TARGET_VERSION/+/%2B}"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
    "https://github.com/k3s-io/k3s/releases/download/${URLSAFE_VER}/k3s" \
    -o /usr/local/bin/k3s.tmp

chmod 755 /usr/local/bin/k3s.tmp
mv /usr/local/bin/k3s.tmp /usr/local/bin/k3s

log_info "Cập nhật dịch vụ k3s-agent với toàn bộ cờ hệ thống từ install-worker.sh..."
export K3S_URL="https://${MASTER_IP}:6443"
export K3S_TOKEN="${NODE_TOKEN}"
export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_EXEC="agent --node-name=${LOCAL_NODE_NAME} --node-ip=${LOCAL_TS_IP} --node-external-ip=${LOCAL_TS_IP} --flannel-iface=tailscale0"

curl -sfL https://get.k3s.io | sh -

systemctl daemon-reload
systemctl restart k3s-agent
sleep 4

if systemctl is-active --quiet k3s-agent; then
    NEW_VER=$(k3s --version 2>/dev/null | awk '{print $3}' | head -n1 || true)
    log_success "Nâng cấp K3s Agent cục bộ thành công lên ${BOLD}${NEW_VER}${NC}!"
else
    log_error "Dịch vụ k3s-agent chưa thể khởi động. Kiểm tra: journalctl -u k3s-agent -xe"
    exit 1
fi

