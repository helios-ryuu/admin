#!/usr/bin/env bash
# =============================================================================
# install-kubectl.sh
# install.sh (kubectl)
# Tự động tải và cài đặt bản kubectl chính thức từ Kubernetes release.
# Hỗ trợ tự động nhận diện CPU (amd64 / arm64 / arm), xác thực mã băm SHA256,
# kiểm tra quyền trước khi ghi đè, và cấu hình bash autocompletion.
#
# Usage: 
#   ./install-kubectl.sh              # Cài bản stable mới nhất
#   ./install-kubectl.sh v1.31.0      # Cài phiên bản chỉ định
#   ./install-kubectl.sh -y           # Tự động ghi đè nếu phiên bản đã tồn tại
#   ./install-kubectl.sh -h | --help  # Hiển thị hướng dẫn sử dụng
#   ./install.sh              # Cài bản stable mới nhất
#   ./install.sh v1.31.0      # Cài phiên bản chỉ định
#   ./install.sh -y           # Tự động ghi đè nếu phiên bản đã tồn tại
#   ./install.sh -h | --help  # Hiển thị hướng dẫn sử dụng
# =============================================================================

set -euo pipefail

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
Usage: $0 [OPTIONS] [VERSION]

Tự động tải và cài đặt kubectl chính thức từ dl.k8s.io.

Arguments:
  VERSION            Phiên bản kubectl cần cài (ví dụ: v1.31.0 hoặc 1.30.2).
                     Mặc định sẽ tự động lấy bản stable mới nhất.

Options:
  -y, --yes          Tự động đồng ý ghi đè nếu phiên bản chỉ định đã cài đặt.
  -h, --help         Hiển thị hướng dẫn này.

Ví dụ:
  $0                 # Cài bản stable mới nhất
  $0 v1.31.0         # Cài phiên bản v1.31.0
  $0 -y v1.31.0      # Ghi đè tự động không cần prompt
EOF
}

TARGET_VER=""
AUTO_CONFIRM=false

# Phân tích tham số dòng lệnh
for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            ;;
        *)
            if [[ "${arg}" =~ ^- ]]; then
                log_error "Tùy chọn không hợp lệ: ${arg}"
                show_help
                exit 1
            else
                TARGET_VER="${arg}"
            fi
            ;;
    esac
done

# 1. Nhận diện kiến trúc CPU
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7*|armhf) ARCH="arm" ;;
    *)
        log_error "Kiến trúc CPU '${ARCH}' chưa được hỗ trợ bởi script này."
        exit 1
        ;;
esac

# 2. Xác định phiên bản cài đặt
if [[ -z "${TARGET_VER}" ]]; then
    log_info "Đang truy vấn phiên bản kubectl stable mới nhất từ dl.k8s.io..."
    if ! TARGET_VER=$(curl -fsSL --connect-timeout 10 https://dl.k8s.io/release/stable.txt); then
        log_error "Không thể kết nối tới dl.k8s.io để lấy thông tin phiên bản stable."
        log_error "Vui lòng kiểm tra kết nối mạng hoặc chỉ định phiên bản cụ thể: $0 v1.31.0"
        exit 1
    fi
fi

# Chuẩn hóa tiền tố 'v'
[[ "${TARGET_VER}" =~ ^v ]] || TARGET_VER="v${TARGET_VER}"

log_info "Phiên bản mục tiêu: ${BOLD}${TARGET_VER}${NC} (Kiến trúc: ${ARCH})"

# 3. Kiểm tra cài đặt hiện tại
if command -v kubectl &>/dev/null; then
    CURRENT_BIN="$(command -v kubectl)"
    CURRENT_VER=$(kubectl version --client --output=json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' || true)
    if [[ "${CURRENT_VER}" == "${TARGET_VER}" ]]; then
        log_info "kubectl phiên bản ${TARGET_VER} đã được cài đặt tại ${CURRENT_BIN}."
        if [[ "${AUTO_CONFIRM}" != "true" ]]; then
            read -r -p "Bạn có muốn tải và cài đặt lại không? [y/N]: " confirm
            if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
                log_info "Giữ nguyên cài đặt hiện tại."
                exit 0
            fi
        else
            log_info "Cờ -y được kích hoạt: Tiến hành tải và cài đặt lại."
        fi
    fi
fi

# 4. Kiểm tra quyền ghi vào /usr/local/bin từ trước khi tải
DEST_DIR="/usr/local/bin"
DEST_BIN="${DEST_DIR}/kubectl"
NEED_SUDO=0

if [[ ! -w "${DEST_DIR}" && ${EUID} -ne 0 ]]; then
    NEED_SUDO=1
    if ! command -v sudo &>/dev/null; then
        log_error "Cần quyền ghi vào ${DEST_DIR}, nhưng lệnh 'sudo' không khả dụng."
        exit 1
    fi
    log_info "Yêu cầu quyền sudo để cài đặt binary vào ${DEST_BIN}..."
    if ! sudo -v; then
        log_error "Xác thực quyền sudo thất bại."
        exit 1
    fi
fi

# 5. Tải binary và mã băm SHA256 vào thư mục tạm
TMP_DIR=$(mktemp -d /tmp/kubectl-install-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

DOWNLOAD_URL="https://dl.k8s.io/release/${TARGET_VER}/bin/linux/${ARCH}/kubectl"
CHECKSUM_URL="https://dl.k8s.io/release/${TARGET_VER}/bin/linux/${ARCH}/kubectl.sha256"

log_info "Đang tải binary từ: ${DOWNLOAD_URL}"
if ! curl -fsSL --connect-timeout 15 "${DOWNLOAD_URL}" -o "${TMP_DIR}/kubectl"; then
    log_error "Tải binary thất bại. Vui lòng kiểm tra lại phiên bản '${TARGET_VER}' hoặc kết nối mạng."
    exit 1
fi

# 6. Xác thực mã băm SHA256 (Security Verification)
log_info "Đang xác thực tính toàn vẹn SHA256..."
if EXPECTED_SHA=$(curl -fsSL --connect-timeout 10 "${CHECKSUM_URL}" 2>/dev/null); then
    EXPECTED_SHA=$(echo "${EXPECTED_SHA}" | awk '{print $1}')
    ACTUAL_SHA=$(sha256sum "${TMP_DIR}/kubectl" | awk '{print $1}')

    if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
        log_error "CẢNH BÁO BẢO MẬT: Mã băm SHA256 không khớp!"
        log_error "  Kỳ vọng: ${EXPECTED_SHA}"
        log_error "  Thực tế: ${ACTUAL_SHA}"
        exit 1
    fi
    log_success "Mã băm SHA256 hợp lệ: ${ACTUAL_SHA:0:16}..."
else
    log_warn "Không thể truy xuất mã băm từ ${CHECKSUM_URL}. Bỏ qua bước kiểm tra SHA256."
fi

# 7. Kiểm tra tính thực thi của file binary tải về
chmod +x "${TMP_DIR}/kubectl"
if ! "${TMP_DIR}/kubectl" version --client &>/dev/null; then
    log_error "File binary tải về không thể thực thi được trên hệ thống này (lỗi kiến trúc hoặc hỏng file)."
    exit 1
fi

# 8. Cài đặt vào /usr/local/bin an toàn bằng lệnh 'install'
log_info "Đang cài đặt binary vào ${DEST_BIN}..."
if [[ ${NEED_SUDO} -eq 1 ]]; then
    sudo install -d -m 0755 "${DEST_DIR}"
    sudo install -o root -g root -m 0755 "${TMP_DIR}/kubectl" "${DEST_BIN}"
else
    install -d -m 0755 "${DEST_DIR}"
    install -m 0755 "${TMP_DIR}/kubectl" "${DEST_BIN}"
fi

# 9. Tự động thiết lập Bash completion nếu thư mục tồn tại
if [[ -d /etc/bash_completion.d ]]; then
    log_info "Cấu hình bash auto-completion tại /etc/bash_completion.d/kubectl..."
    if [[ ${NEED_SUDO} -eq 1 ]]; then
        sudo "${DEST_BIN}" completion bash 2>/dev/null | sudo tee /etc/bash_completion.d/kubectl >/dev/null || true
    else
        "${DEST_BIN}" completion bash 2>/dev/null > /etc/bash_completion.d/kubectl 2>/dev/null || true
    fi
fi

log_success "Cài đặt kubectl thành công!"
"${DEST_BIN}" version --client --output=yaml
