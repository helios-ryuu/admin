#!/usr/bin/env bash

# =============================================================================
# K3s Server Node Upgrade Script (update-server.sh)
# Hỗ trợ nâng cấp Master / Control Plane từ xa qua SSH hoặc chạy cục bộ
# Pattern: scripts/k8s/k3s/update-server.sh
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
Usage: $0 [OPTIONS] [USER@MASTER_HOST]

Nâng cấp K3s Server (Control Plane Node) an toàn qua SSH hoặc trực tiếp trên máy chủ.

Chế độ 1: Nâng cấp từ xa qua SSH (Khuyến nghị - Chạy từ máy quản trị):
  $0 [OPTIONS] [user@master-ip]
  Ví dụ:
    # Kiểm tra phiên bản hiện tại so với bản mới nhất (Dry-Run):
    $0

    # Nâng cấp chính thức lên phiên bản Stable mới nhất:
    $0 -y

    # Chỉ định cụ thể máy chủ SSH và phiên bản cần nâng cấp:
    $0 user@100.64.0.0 --version=v1.36.4+k3s1 -y

    # Chỉ định channel nâng cấp (mặc định: stable):
    $0 --channel=latest -y

Chế độ 2: Nâng cấp cục bộ (Chạy trực tiếp trên chính máy Server):
  sudo $0 --local [OPTIONS] [-y]

Options:
  -t, --target USER@HOST  Địa chỉ SSH của Master Node (Mặc định: tự lấy từ ~/.kube/config)
  --nodename NAME         Tên định danh Node Master (Mặc định: tự phát hiện hostname hoặc node-server-1)
  -c, --channel CHANNEL   Kênh phát hành K3s (Mặc định: stable. Tùy chọn: stable, latest, v1.36, ...)
  -v, --version VERSION   Chỉ định phiên bản K3s cụ thể (vd: v1.36.4+k3s1)
  -p, --port PORT         Cổng SSH của Master Node (Mặc định: 22)
  -i, --identity KEY      Đường dẫn SSH private key
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
TARGET_SSH=""
TARGET_CHANNEL="stable"
TARGET_VERSION=""
SSH_PORT="22"
SSH_KEY=""
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
        -t|--target)
            TARGET_SSH="$2"
            shift 2
            ;;
        --target=*)
            TARGET_SSH="${1#*=}"
            shift
            ;;
        -c|--channel)
            TARGET_CHANNEL="$2"
            shift 2
            ;;
        --channel=*)
            TARGET_CHANNEL="${1#*=}"
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

log_warn "[LƯU Ý] Chạy script shell là tùy chọn phụ trợ (KHÔNG KHUYẾN KHÍCH)."
log_warn "Khuyến nghị thực hiện theo RUNBOOK.md với quy trình nâng cấp chuẩn."

# =============================================================================
# CHẾ ĐỘ 1: NÂNG CẤP TỪ XA QUA SSH (REMOTE UPGRADE MODE)
# =============================================================================
if [[ "$IS_LOCAL" = false ]]; then
    # 1.1. Tự động nhận diện Master IP từ ~/.kube/config nếu chưa truyền
    if [[ -z "$TARGET_SSH" ]]; then
        KUBE_CONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
        if [[ -f "$KUBE_CONFIG" ]]; then
            DETECTED_SERVER=$(grep -oP 'server:\s*https?://\K[^:/]+' "$KUBE_CONFIG" 2>/dev/null | head -n1 || true)
            if [[ -n "$DETECTED_SERVER" && "$DETECTED_SERVER" != "127.0.0.1" && "$DETECTED_SERVER" != "localhost" ]]; then
                CURRENT_USER=$(id -un 2>/dev/null || echo "user")
                TARGET_SSH="${CURRENT_USER}@${DETECTED_SERVER}"
                log_info "Đã tự động nhận diện Master Node từ ~/.kube/config: ${BOLD}${TARGET_SSH}${NC}"
            fi
        fi
    fi

    if [[ -z "$TARGET_SSH" ]]; then
        log_error "Không xác định được máy chủ Master! Vui lòng truyền địa chỉ: $0 <user@master-ip>"
        exit 1
    fi

    # Chuẩn hóa TARGET_SSH
    TARGET_HOST="${TARGET_SSH#*@}"
    TARGET_HOST="${TARGET_HOST%:*}"

    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  K3S SERVER NODE UPGRADE OVER SSH                                    ${NC}"
    echo -e "${CYAN}  Target Master: ${BOLD}${TARGET_SSH}${NC} (Port: ${SSH_PORT})"
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

    # 1.2. Kiểm tra kết nối SSH
    log_info "Bước 1/5: Kiểm tra kết nối SSH tới Master (${TARGET_SSH})..."
    if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "true" 2>/dev/null; then
        log_error "Không thể kết nối SSH tới ${TARGET_SSH} qua cổng ${SSH_PORT}."
        exit 1
    fi
    log_success "Kết nối SSH thành công!"

    # 1.3. Xác định quyền người dùng từ xa
    REMOTE_USER="${TARGET_SSH%@*}"
    SUDO_PREFIX="sudo"
    if [[ "$REMOTE_USER" == "root" || "$TARGET_SSH" == "root" ]]; then
        SUDO_PREFIX=""
        log_info "Kết nối trực tiếp dưới quyền root."
    else
        log_info "Người dùng từ xa: ${BOLD}${REMOTE_USER}${NC} (Sẽ sử dụng sudo khi cập nhật)."
    fi

    # 1.4. Lấy phiên bản hiện tại của K3s Server
    log_info "Bước 2/5: Kiểm tra phiên bản K3s hiện tại trên Master..."
    CURRENT_VERSION=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "k3s --version 2>/dev/null | awk '{print \$3}' | head -n1" 2>/dev/null || true)
    
    if [[ -z "$CURRENT_VERSION" ]]; then
        # Thử lấy qua kubectl cục bộ nếu có
        if command -v kubectl &>/dev/null; then
            CURRENT_VERSION=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane=="true")].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
        fi
    fi

    if [[ -z "$CURRENT_VERSION" ]]; then
        log_warn "Không thể xác định phiên bản hiện tại trên server. Có thể K3s chưa được cài đặt."
        CURRENT_VERSION="Chưa xác định"
    else
        log_info "Phiên bản Master hiện tại: ${BOLD}${CURRENT_VERSION}${NC}"
    fi

    # 1.5. Xác định phiên bản mục tiêu
    log_info "Bước 3/5: Xác định phiên bản nâng cấp mục tiêu..."

    # Nếu người dùng truyền tên channel (latest, stable, testing, ...) vào cờ version, chuyển thành TARGET_CHANNEL
    if [[ "$TARGET_VERSION" =~ ^(latest|stable|testing)$ ]] || [[ -n "$TARGET_VERSION" && ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        TARGET_CHANNEL="$TARGET_VERSION"
        TARGET_VERSION=""
    fi

    if [[ -z "$TARGET_VERSION" ]]; then
        CHANNEL_URL="https://update.k3s.io/v1-release/channels/${TARGET_CHANNEL}"
        log_info "Đang truy vấn phiên bản mới nhất từ kênh '${TARGET_CHANNEL}'..."
        
        # 1. Thử lấy từ redirect URL hiệu dụng của kênh (trỏ tới github tag)
        TARGET_VERSION=$(curl -sIL -m 6 -o /dev/null -w '%{url_effective}' "${CHANNEL_URL}" 2>/dev/null | awk -F'/' '{print $NF}' || true)
        if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
            TARGET_VERSION=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "curl -sIL -m 6 -o /dev/null -w '%{url_effective}' '${CHANNEL_URL}'" 2>/dev/null | awk -F'/' '{print $NF}' || true)
        fi

        # 2. Nếu chưa được, truy vấn JSON tổng thể từ /channels
        if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
            ALL_CHANNELS_JSON=$(curl -sL -m 6 "https://update.k3s.io/v1-release/channels" 2>/dev/null || true)
            if [[ -z "$ALL_CHANNELS_JSON" ]]; then
                ALL_CHANNELS_JSON=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "curl -sL -m 6 'https://update.k3s.io/v1-release/channels'" 2>/dev/null || true)
            fi
            TARGET_VERSION=$(echo "$ALL_CHANNELS_JSON" | grep -oP "{\"id\":\"${TARGET_CHANNEL}\"[^}]+" | grep -oP "\"latest\":\"\K[^\"]+" || true)
        fi

        # 3. Làm sạch TARGET_VERSION (loại bỏ query params hoặc url-encoding thừa)
        TARGET_VERSION="${TARGET_VERSION%%\?*}"
        TARGET_VERSION="$(echo -n "$TARGET_VERSION" | tr -d '\r\n ')"
    fi

    if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        log_error "Không thể xác định phiên bản hợp lệ cho kênh '${TARGET_CHANNEL}' (nhận diện: '${TARGET_VERSION:-trống}')."
        log_warn "Vui lòng chỉ định phiên bản cụ thể: $0 --version=v1.36.4+k3s1"
        exit 1
    fi

    log_success "Phiên bản nâng cấp mục tiêu: ${BOLD}${TARGET_VERSION}${NC}"

    # 1.6. So sánh phiên bản
    if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" && "$FORCE_UPDATE" = false ]]; then
        echo ""
        log_success "Master Node (${TARGET_HOST}) đã ở phiên bản mới nhất (${CURRENT_VERSION})!"
        echo -e "${CYAN}[GỢI Ý]${NC} Nếu bạn muốn ép buộc cài đè lại, hãy thêm cờ: ${BOLD}-f${NC} hoặc ${BOLD}--force${NC}"
        exit 0
    fi

    # 1.7. Chế độ Dry-Run / Confirmation
    if [[ "$AUTO_APPROVE" = false ]]; then
        echo ""
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "${YELLOW} [DRY-RUN MODE] Kế hoạch nâng cấp Master Node:                   ${NC}"
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "  - Máy chủ Master    : ${BOLD}${TARGET_SSH}${NC}"
        echo -e "  - Phiên bản hiện tại: ${BOLD}${CURRENT_VERSION}${NC}"
        echo -e "  - Phiên bản cập nhật: ${GREEN}${BOLD}${TARGET_VERSION}${NC}"
        echo "================================================================="
        
        HINT_CMD="$0 ${TARGET_SSH} --version=${TARGET_VERSION}"
        [[ "$SSH_PORT" != "22" ]] && HINT_CMD+=" -p ${SSH_PORT}"
        HINT_CMD+=" -y"
        
        echo -e "${CYAN}[GỢI Ý]${NC} Để thực thi nâng cấp chính thức, vui lòng chạy lệnh sau:"
        echo -e "  ${BOLD}${HINT_CMD}${NC}"
        exit 0
    fi

    # 1.8. Thực thi nâng cấp qua SSH
    log_info "Bước 4/5: Đang chuẩn bị cấu hình và nâng cấp K3s Server trên ${TARGET_SSH}..."

    # Thu thập thông tin server để tái lập chính xác các cờ ban đầu từ install-server.sh
    SERVER_NODE_NAME="${NODE_NAME}"
    if [[ -z "$SERVER_NODE_NAME" ]]; then
        SERVER_NODE_NAME=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "hostname" 2>/dev/null | tr -d '\r\n ')
    fi
    if [[ -z "$SERVER_NODE_NAME" ]]; then
        SERVER_NODE_NAME="node-server-1"
    fi

    SERVER_TS_IP=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "tailscale ip -4 2>/dev/null || true" | head -n1 | tr -d '\r\n ')
    if [[ -z "$SERVER_TS_IP" ]]; then
        SERVER_TS_IP="${TARGET_HOST}"
    fi

    log_info "Áp dụng cấu hình Master: Node Name=${BOLD}${SERVER_NODE_NAME}${NC}, Tailscale IP=${BOLD}${SERVER_TS_IP}${NC}"

    URLSAFE_TARGET_VERSION="${TARGET_VERSION/+/%2B}"
    REMOTE_SCRIPT="set -e

echo '  - [Master] Chuẩn bị binary K3s phiên bản ${TARGET_VERSION}...'
curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
    \"https://github.com/k3s-io/k3s/releases/download/${URLSAFE_TARGET_VERSION}/k3s\" \
    -o /usr/local/bin/k3s.tmp

chmod 755 /usr/local/bin/k3s.tmp
mv /usr/local/bin/k3s.tmp /usr/local/bin/k3s

echo '  - [Master] Tái tạo cấu hình k3s.service với toàn bộ cờ hệ thống chuẩn từ install-server.sh...'
export INSTALL_K3S_SKIP_DOWNLOAD=true
curl -sfL https://get.k3s.io | sh -s - server \
    --node-name '${SERVER_NODE_NAME}' \
    --write-kubeconfig-mode 644 \
    --bind-address '${SERVER_TS_IP}' \
    --advertise-address '${SERVER_TS_IP}' \
    --tls-san '${SERVER_TS_IP}' \
    --tls-san=127.0.0.1 \
    --tls-san=localhost \
    --node-ip '${SERVER_TS_IP}' \
    --node-external-ip '${SERVER_TS_IP}' \
    --flannel-iface=tailscale0 \
    --flannel-backend=vxlan \
    --disable traefik \
    --secrets-encryption=true \
    --debug

echo '  - [Master] Khởi động lại dịch vụ k3s...'
systemctl daemon-reload
systemctl restart k3s
"

    ENCODED_SCRIPT=$(echo "$REMOTE_SCRIPT" | base64 -w 0)

    if [[ -n "$SUDO_PREFIX" ]]; then
        ssh -t "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    else
        ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "bash -c 'echo ${ENCODED_SCRIPT} | base64 -d | bash'"
    fi

    # 1.9. Kiểm tra kết quả
    log_info "Bước 5/5: Xác minh trạng thái cụm sau nâng cấp..."
    sleep 5

    if ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "systemctl is-active --quiet k3s"; then
        NEW_VER=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "k3s --version 2>/dev/null | awk '{print \$3}' | head -n1" || true)
        echo ""
        echo -e "${CYAN}=================================================================${NC}"
        log_success "MASTER NODE ĐÃ NÂNG CẤP LÊN ${BOLD}${NEW_VER}${NC} THÀNH CÔNG!"
        echo -e "${CYAN}=================================================================${NC}"
    else
        log_error "Dịch vụ k3s trên Master chưa hoạt động bình thường!"
        echo "  ssh ${TARGET_SSH} 'sudo journalctl -u k3s -xe --no-pager | tail -n 30'"
        exit 1
    fi

    # Xác nhận qua kubectl cục bộ nếu có
    if command -v kubectl &>/dev/null; then
        echo ""
        log_info "Trạng thái các node trên cụm qua kubectl cục bộ:"
        kubectl get nodes -o wide --request-timeout=10s || true
    fi

    echo ""
    log_success "Hoàn tất quy trình nâng cấp Master Node!"
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
echo -e "${CYAN}  NÂNG CẤP K3S SERVER CỤC BỘ                                          ${NC}"
echo -e "${CYAN}======================================================================${NC}"

CURRENT_VER=$(k3s --version 2>/dev/null | awk '{print $3}' | head -n1 || echo "unknown")
log_info "Phiên bản hiện tại: ${BOLD}${CURRENT_VER}${NC}"

if [[ "$TARGET_VERSION" =~ ^(latest|stable|testing)$ ]] || [[ -n "$TARGET_VERSION" && ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
    TARGET_CHANNEL="$TARGET_VERSION"
    TARGET_VERSION=""
fi

if [[ -z "$TARGET_VERSION" ]]; then
    CHANNEL_URL="https://update.k3s.io/v1-release/channels/${TARGET_CHANNEL}"
    log_info "Kiểm tra phiên bản mới từ ${CHANNEL_URL}..."
    TARGET_VERSION=$(curl -sIL -m 6 -o /dev/null -w '%{url_effective}' "${CHANNEL_URL}" 2>/dev/null | awk -F'/' '{print $NF}' || true)
    if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
        TARGET_VERSION=$(curl -sL -m 6 "${CHANNEL_URL}" 2>/dev/null | grep -oP '"latest":\s*"\K[^"]+' | head -n1 || true)
    fi
    TARGET_VERSION="${TARGET_VERSION%%\?*}"
    TARGET_VERSION="$(echo -n "$TARGET_VERSION" | tr -d '\r\n ')"
fi

if [[ -z "$TARGET_VERSION" || ! "$TARGET_VERSION" =~ ^v[0-9] ]]; then
    log_error "Không thể tìm thấy phiên bản nâng cấp hợp lệ cho '${TARGET_CHANNEL}'!"
    exit 1
fi
log_info "Phiên bản mục tiêu: ${BOLD}${TARGET_VERSION}${NC}"

if [[ "$CURRENT_VER" == "$TARGET_VERSION" && "$FORCE_UPDATE" = false ]]; then
    log_success "Máy chủ đã ở phiên bản mới nhất (${CURRENT_VER})!"
    exit 0
fi

if [[ "$AUTO_APPROVE" = false ]]; then
    echo -e "${YELLOW}[DRY-RUN MODE] Kiểm tra hoàn tất. Thêm cờ -y để nâng cấp chính thức.${NC}"
    exit 0
fi

log_info "Đang tải binary K3s ${TARGET_VERSION}..."
URLSAFE_VER="${TARGET_VERSION/+/%2B}"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
    "https://github.com/k3s-io/k3s/releases/download/${URLSAFE_VER}/k3s" \
    -o /usr/local/bin/k3s.tmp

chmod 755 /usr/local/bin/k3s.tmp
mv /usr/local/bin/k3s.tmp /usr/local/bin/k3s

LOCAL_TS_IP=$(tailscale ip -4 2>/dev/null || true)
LOCAL_NODE_NAME="${NODE_NAME:-$(hostname 2>/dev/null || echo "node-server-1")}"

log_info "Cập nhật dịch vụ K3s Server với toàn bộ cờ hệ thống chuẩn từ install-server.sh..."
export INSTALL_K3S_SKIP_DOWNLOAD=true
curl -sfL https://get.k3s.io | sh -s - server \
    --node-name "${LOCAL_NODE_NAME}" \
    --write-kubeconfig-mode 644 \
    --bind-address "${LOCAL_TS_IP}" \
    --advertise-address "${LOCAL_TS_IP}" \
    --tls-san "${LOCAL_TS_IP}" \
    --tls-san=127.0.0.1 \
    --tls-san=localhost \
    --node-ip "${LOCAL_TS_IP}" \
    --node-external-ip "${LOCAL_TS_IP}" \
    --flannel-iface=tailscale0 \
    --flannel-backend=vxlan \
    --disable traefik \
    --secrets-encryption=true \
    --debug

systemctl daemon-reload
systemctl restart k3s
sleep 4

if systemctl is-active --quiet k3s; then
    NEW_VER=$(k3s --version 2>/dev/null | awk '{print $3}' | head -n1 || true)
    log_success "Nâng cấp K3s Server cục bộ thành công lên ${BOLD}${NEW_VER}${NC}!"
else
    log_error "Dịch vụ k3s chưa thể khởi động. Kiểm tra: journalctl -u k3s -xe"
    exit 1
fi

