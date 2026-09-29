#!/usr/bin/env bash
# =============================================================================
# uninstall-worker.sh
# Gỡ bỏ K3s Agent và dọn dẹp sạch sẽ tài nguyên trên Worker Node.
# Hỗ trợ:
#   - Gỡ bỏ từ xa qua SSH: ./uninstall-worker.sh <user@worker-ip> [-y]
#   - Gỡ bỏ cục bộ: sudo ./uninstall-worker.sh --local [-y]
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
Usage: $0 [OPTIONS] [USER@HOST]

Gỡ bỏ K3s Agent và dọn dẹp sạch sẽ mạng ảo, cấu hình trên Worker Node.

Chế độ 1: Gỡ bỏ từ xa qua SSH (Khuyến nghị - Chạy từ máy quản trị):
  $0 <user@worker-ip> [-y]
  Ví dụ:
    $0 user@100.64.0.0 -y

Chế độ 2: Gỡ bỏ cục bộ trên máy Worker:
  sudo $0 --local [-y]

Options:
  -p, --port PORT     Cổng SSH của Worker (Mặc định: 22)
  -i, --identity KEY  Đường dẫn SSH private key
  --local             Gỡ bỏ trên máy cục bộ
  -y, --yes           Tự động đồng ý gỡ bỏ không cần hỏi xác nhận
  -h, --help          Hiển thị hướng dẫn này
EOF
}

TARGET_SSH=""
SSH_PORT="22"
SSH_KEY=""
IS_LOCAL=false
AUTO_APPROVE=false

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
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
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
            fi
            shift
            ;;
    esac
done

log_warn "[LƯU Ý] Chạy script shell là tùy chọn phụ trợ (KHÔNG KHUYẾN KHÍCH)."
log_warn "Khuyến nghị thực hiện theo RUNBOOK.md phần 'Gỡ bỏ & Dọn dẹp Sạch sẽ'."

# GỠ BỎ TỪ XA QUA SSH
if [[ "$IS_LOCAL" = false && -n "$TARGET_SSH" ]]; then
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  UNINSTALL K3S WORKER NODE OVER SSH                                  ${NC}"
    echo -e "${CYAN}  Target: ${BOLD}${TARGET_SSH}${NC} (Port: ${SSH_PORT})"
    echo -e "${CYAN}======================================================================${NC}\n"

    SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    if [[ -n "${SSH_KEY}" ]]; then
        SSH_OPTS+=(-i "${SSH_KEY}")
    fi

    if [[ "$AUTO_APPROVE" = false ]]; then
        echo -e "${YELLOW}[CẢNH BÁO] Toàn bộ dữ liệu và tiến trình k3s-agent trên ${TARGET_SSH} sẽ bị gỡ bỏ.${NC}"
        read -r -p "Bạn có chắc chắn muốn tiếp tục không? [y/N]: " confirm
        if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
            log_info "Hủy bỏ tiến trình gỡ bỏ."
            exit 0
        fi
    fi

    log_info "Kiểm tra kết nối SSH tới ${TARGET_SSH}..."
    if ! ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "true" 2>/dev/null; then
        log_error "Không thể kết nối SSH tới ${TARGET_SSH}."
        exit 1
    fi

    REMOTE_USER="${TARGET_SSH%@*}"
    SUDO_PREFIX="sudo"
    if [[ "$REMOTE_USER" == "root" || "$TARGET_SSH" == "root" ]]; then
        SUDO_PREFIX=""
    fi

    NODE_HOSTNAME=$(ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "hostname" 2>/dev/null | tr -d '\r\n ')

    log_info "Đang thực thi script gỡ bỏ và dọn dẹp trên Worker..."
    CLEANUP_SCRIPT='
set -e
if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    /usr/local/bin/k3s-agent-uninstall.sh >/dev/null 2>&1 || true
fi
rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /etc/cni/net.d /var/lib/cni/ /run/k3s /run/flannel
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
'
    ENCODED_CLEANUP=$(echo "$CLEANUP_SCRIPT" | base64 -w 0)

    if [[ -n "$SUDO_PREFIX" ]]; then
        ssh -t "${SSH_OPTS[@]}" "${TARGET_SSH}" "sudo bash -c 'echo ${ENCODED_CLEANUP} | base64 -d | bash'"
    else
        ssh "${SSH_OPTS[@]}" "${TARGET_SSH}" "bash -c 'echo ${ENCODED_CLEANUP} | base64 -d | bash'"
    fi

    log_success "Đã gỡ bỏ sạch sẽ K3s Agent trên ${TARGET_SSH}!"

    # Dọn node khỏi Kubernetes cluster nếu có kubectl
    if command -v kubectl &>/dev/null && [[ -n "$NODE_HOSTNAME" ]]; then
        log_info "Đang xóa node '${NODE_HOSTNAME}' khỏi cluster qua kubectl cục bộ..."
        kubectl delete node "${NODE_HOSTNAME}" --timeout=15s 2>/dev/null || true
    fi

    log_success "Quy trình gỡ bỏ Worker hoàn tất!"
    exit 0
fi

# GỠ BỎ CỤC BỘ
if [[ ${EUID} -ne 0 ]]; then
    log_error "Vui lòng chạy với quyền sudo/root: sudo $0 --local"
    exit 1
fi

log_info "1. Chạy script gỡ bỏ K3s Agent..."
if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    /usr/local/bin/k3s-agent-uninstall.sh
fi

log_info "2. Xóa sạch thư mục cấu hình và containerd..."
rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /etc/cni/net.d /var/lib/cni/ /run/k3s /run/flannel

log_info "3. Dọn dẹp interface mạng ảo..."
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

log_info "4. Flush iptables rules..."
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

log_success "Đã dọn dẹp sạch sẽ Worker Node cục bộ!"
