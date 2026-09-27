#!/usr/bin/env bash
# =============================================================================
# uninstall-kubectl.sh
# uninstall.sh (kubectl)
# Gỡ bỏ nhị phân kubectl và tùy chọn dọn dẹp cấu hình ~/.kube
#
# Usage: ./uninstall-kubectl.sh [-y]
# Usage: ./uninstall.sh [-y]
# =============================================================================

set -euo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

AUTO_CONFIRM=false
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) AUTO_CONFIRM=true ;;
        -h|--help)
            echo "Usage: $0 [-y|--yes] [-h|--help]"
            echo ""
            echo "Gỡ bỏ nhị phân kubectl và tùy chọn dọn dẹp cấu hình ~/.kube."
            echo "Options:"
            echo "  -y, --yes    Tự động xác nhận xóa ~/.kube không cần hỏi"
            echo "  -h, --help   Hiển thị hướng dẫn này"
            exit 0
            ;;
        *)
            log_error "Tùy chọn không hợp lệ: ${arg}"
            exit 1
            ;;
    esac
done

# 1. Xóa file thực thi kubectl
KUBECTL_PATH=$(command -v kubectl 2>/dev/null || true)
if [[ -n "${KUBECTL_PATH}" && -f "${KUBECTL_PATH}" ]]; then
    log_info "Đang gỡ bỏ binary: ${KUBECTL_PATH}..."
    if [[ ${EUID} -eq 0 ]]; then
        rm -f "${KUBECTL_PATH}"
    else
        sudo rm -f "${KUBECTL_PATH}"
    fi
    log_success "Đã xóa ${KUBECTL_PATH}."
else
    log_warn "Không tìm thấy file thực thi kubectl trong PATH."
fi

# 2. Xóa các file thừa nếu còn sót trong các đường dẫn quen thuộc
for extra in /usr/local/bin/kubectl ~/kubectl /etc/bash_completion.d/kubectl; do
    if [[ -f "${extra}" ]]; then
        log_info "Dọn dẹp file còn sót tại ${extra}..."
        sudo rm -f "${extra}" 2>/dev/null || rm -f "${extra}"
    fi
done

# 3. Dọn dẹp thư mục cấu hình cá nhân (~/.kube)
if [[ -d "${HOME}/.kube" ]]; then
    if [[ "${AUTO_CONFIRM}" == "true" ]]; then
        rm -rf "${HOME}/.kube"
        log_info "Đã xóa thư mục cấu hình ~/.kube (chế độ -y)."
    else
        read -r -p "Bạn có muốn xóa thư mục cấu hình Kubernetes (~/.kube)? [y/N]: " confirm
        if [[ "${confirm:-}" =~ ^[Yy]$ ]]; then
            rm -rf "${HOME}/.kube"
            log_info "Đã xóa thư mục cấu hình ~/.kube."
        else
            log_info "Giữ lại thư mục ~/.kube."
        fi
    fi
fi

log_success "Hoàn tất quy trình gỡ bỏ kubectl!"
