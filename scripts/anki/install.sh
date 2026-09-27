#!/usr/bin/env bash
# =============================================================================
# install.sh (anki)
# Tải về và cài đặt phiên bản Anki mới nhất (hoặc chỉ định) trên Linux.
# Hỗ trợ tự động nhận diện kiến trúc (x86_64, aarch64), giải nén .tar.zst,
# cài đặt binary, cấu hình desktop launcher, MIME associations và icons.
#
# Pattern: scripts/anki/install.sh
#
# Usage:
#   ./install.sh                # Tự động tải và cài đặt phiên bản mới nhất
#   ./install.sh -v 26.08.1     # Cài đặt phiên bản chỉ định
#   ./install.sh --force        # Cài đè lại kể cả khi đã ở bản mới nhất
#   sudo ./install.sh           # Chạy trực tiếp dưới quyền sudo
# =============================================================================

set -Eeuo pipefail

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
    cat << EOF
Usage: $0 [OPTIONS]

Tải về và cài đặt phiên bản Anki mới nhất từ GitHub Releases trên Linux.

Options:
  -v, --version VERSION   Chỉ định phiên bản Anki cần cài đặt (Mặc định: Tự động lấy bản mới nhất)
  --prefix DIR            Thư mục cài đặt gốc (Mặc định: /usr/local)
  -f, --force             Cài đè lại ngay cả khi phiên bản hiện tại đã trùng khớp
  -y, --yes               Tự động xác nhận cài đặt (bỏ qua bước xác nhận)
  -h, --help              Hiển thị hướng dẫn này

Ví dụ:
  $0                      # Cài bản mới nhất vào /usr/local
  $0 -v 26.08.1           # Cài bản 26.08.1
  $0 -f -y                # Ép buộc cài lại bản mới nhất không cần hỏi
EOF
}

TARGET_VERSION=""
PREFIX="/usr/local"
FORCE_INSTALL=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --version=*)
            TARGET_VERSION="${1#*=}"
            shift
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        -f|--force)
            FORCE_INSTALL=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        *)
            log_error "Tùy chọn không hợp lệ: $1"
            show_help
            exit 1
            ;;
    esac
done

# ── 1. Xác định thông tin người dùng & Quyền Sudo ──────────────────────────────
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    REAL_USER="${SUDO_USER}"
    REAL_UID="${SUDO_UID:-$(id -u "${REAL_USER}")}"
    REAL_GID="${SUDO_GID:-$(id -g "${REAL_USER}")}"
else
    REAL_USER="$(id -un)"
    REAL_UID="$(id -u)"
    REAL_GID="$(id -g)"
fi

REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-${HOME}}"

PREFIX="$(realpath -m "${PREFIX}")"

# Kiểm tra quyền ghi vào thư mục đích (cần sudo nếu cài vào /usr hoặc /usr/local)
SUDO_CMD=""
if [[ ! -w "${PREFIX}" && ${EUID} -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        log_error "Không có quyền ghi vào '${PREFIX}' và lệnh 'sudo' không tồn tại."
        exit 1
    fi
    echo -e "${YELLOW}[*] Cần quyền sudo để cài đặt Anki vào '${PREFIX}'.${NC}"
    if ! sudo -v; then
        log_error "Xác thực sudo thất bại. Hủy tiến trình."
        exit 1
    fi
    SUDO_CMD="sudo"
fi

# Giữ sudo keepalive nếu cần
SUDO_KEEPALIVE_PID=""
cleanup() {
    local exit_code=$?
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

if [[ -n "${SUDO_CMD}" ]]; then
    ( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
fi

# ── 2. Xác định Kiến trúc hệ thống ───────────────────────────────────────────
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64)
        ANKI_ARCH="x86_64"
        ;;
    aarch64|arm64)
        ANKI_ARCH="aarch64"
        ;;
    *)
        log_error "Kiến trúc '${ARCH}' hiện không được gói đóng gói chính thức của Anki hỗ trợ."
        echo "  Anki chỉ cung cấp gói nhị phân cho x86_64 và aarch64."
        exit 1
        ;;
esac

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}  CÀI ĐẶT ANKI FLASHCARDS CHO LINUX                                   ${NC}"
echo -e "${CYAN}  Kiến trúc: ${BOLD}${ANKI_ARCH}${NC} | Thư mục đích: ${BOLD}${PREFIX}${NC}"
echo -e "${CYAN}======================================================================${NC}\n"

# ── 3. Kiểm tra các công cụ giải nén bắt buộc (zstd & tar) ───────────────────
log_info "Bước 1/6: Kiểm tra các công cụ hệ thống cần thiết..."

MISSING_DEPS=()
command -v curl &>/dev/null || MISSING_DEPS+=("curl")
command -v tar  &>/dev/null || MISSING_DEPS+=("tar")

if ! command -v zstd &>/dev/null && ! command -v unzstd &>/dev/null; then
    MISSING_DEPS+=("zstd")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log_warn "Phát hiện thiếu công cụ bắt buộc: ${MISSING_DEPS[*]}"
    log_info "Đang tiến hành tự động cài đặt công cụ cần thiết..."
    
    if command -v dnf &>/dev/null; then
        ${SUDO_CMD} dnf install -y "${MISSING_DEPS[@]}"
    elif command -v apt-get &>/dev/null; then
        ${SUDO_CMD} apt-get update -qq && ${SUDO_CMD} apt-get install -y "${MISSING_DEPS[@]}"
    elif command -v pacman &>/dev/null; then
        ${SUDO_CMD} pacman -Sy --noconfirm "${MISSING_DEPS[@]}"
    elif command -v zypper &>/dev/null; then
        ${SUDO_CMD} zypper install -y "${MISSING_DEPS[@]}"
    else
        log_error "Không thể tự động cài đặt: ${MISSING_DEPS[*]}. Vui lòng cài đặt thủ công."
        exit 1
    fi
fi
log_success "Các công cụ bắt buộc (curl, tar, zstd) đã sẵn sàng!"

# ── 4. Xác định phiên bản Anki cần cài đặt ─────────────────────────────────────
log_info "Bước 2/6: Xác định phiên bản Anki..."

if [[ -z "${TARGET_VERSION}" ]]; then
    log_info "Đang truy vấn phiên bản Anki mới nhất từ GitHub Releases..."
    
    # 1. Thử lấy từ GitHub API
    LATEST_TAG=$(curl -sSL -m 8 "https://api.github.com/repos/ankitects/anki/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1 || true)
    
    # 2. Fallback qua HTTP redirect nếu API bị rate limit
    if [[ -z "${LATEST_TAG}" ]]; then
        LATEST_TAG=$(curl -sIL -m 8 -o /dev/null -w '%{url_effective}' "https://github.com/ankitects/anki/releases/latest" 2>/dev/null \
            | awk -F'/' '{print $NF}' || true)
    fi

    TARGET_VERSION="${LATEST_TAG#v}"
    TARGET_VERSION="$(echo "${TARGET_VERSION}" | tr -d '\r\n ')"
fi

if [[ -z "${TARGET_VERSION}" ]]; then
    log_error "Không thể tự động xác định phiên bản mới nhất từ GitHub."
    log_warn "Vui lòng chỉ định phiên bản cụ thể qua cờ: $0 --version <version> (vd: $0 -v 26.08.1)"
    exit 1
fi

log_success "Phiên bản mục tiêu: ${BOLD}${TARGET_VERSION}${NC}"

# Kiểm tra phiên bản hiện tại trên hệ thống
CURRENT_VERSION=""
if [[ -x "${PREFIX}/bin/anki" ]]; then
    # Thử lấy version từ file README hoặc binary
    if [[ -f "${PREFIX}/share/anki/README.md" ]]; then
        CURRENT_VERSION=$(grep -oP 'Anki \K[0-9.]+' "${PREFIX}/share/anki/README.md" 2>/dev/null | head -n1 || true)
    fi
    if [[ -z "${CURRENT_VERSION}" ]]; then
        CURRENT_VERSION=$("${PREFIX}/bin/anki" --version 2>/dev/null | awk '{print $NF}' || true)
    fi
fi

if [[ -n "${CURRENT_VERSION}" ]]; then
    log_info "Phiên bản Anki hiện tại trên máy: ${BOLD}${CURRENT_VERSION}${NC}"
    if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" && "${FORCE_INSTALL}" = false ]]; then
        echo ""
        log_success "Anki đã ở phiên bản mới nhất (${CURRENT_VERSION})!"
        echo -e "${CYAN}[GỢI Ý]${NC} Nếu bạn muốn cài đè lại, hãy thêm cờ: ${BOLD}-f${NC} hoặc ${BOLD}--force${NC}"
        exit 0
    fi
else
    log_info "Chưa phát hiện Anki trong '${PREFIX}'."
fi

# Xác nhận cài đặt nếu không có cờ -y
if [[ "${AUTO_YES}" = false ]]; then
    echo ""
    echo -e "${YELLOW}=================================================================${NC}"
    echo -e "${YELLOW} Kế hoạch cài đặt Anki:                                          ${NC}"
    echo -e "${YELLOW}=================================================================${NC}"
    echo -e "  - Phiên bản tải về   : ${GREEN}${BOLD}${TARGET_VERSION}${NC}"
    echo -e "  - Kiến trúc          : ${BOLD}${ANKI_ARCH}${NC}"
    echo -e "  - Thư mục cài đặt    : ${BOLD}${PREFIX}${NC}"
    echo -e "  - Binary symlink     : ${BOLD}${PREFIX}/bin/anki${NC}"
    echo -e "  - Desktop launcher   : ${BOLD}${PREFIX}/share/applications/anki.desktop${NC}"
    echo "================================================================="
    read -r -p "Bạn có muốn tiếp tục tải và cài đặt không? [y/N]: " CONFIRM
    if [[ ! "${CONFIRM}" =~ ^[yY]([eE][sS])?$ ]]; then
        log_warn "Người dùng đã hủy tiến trình."
        exit 0
    fi
fi

# ── 5. Tải về gói lưu trữ Anki (.tar.zst) ──────────────────────────────────────
log_info "Bước 3/6: Tải về bộ cài Anki..."

TARBALL_NAME="anki-${TARGET_VERSION}-linux-${ANKI_ARCH}.tar.zst"
DOWNLOAD_URL="https://github.com/ankitects/anki/releases/download/${TARGET_VERSION}/${TARBALL_NAME}"

TMP_DIR="$(mktemp -d /tmp/anki_install_XXXXXX)"
TMP_TARBALL="${TMP_DIR}/${TARBALL_NAME}"

log_info "Đang tải từ: ${DOWNLOAD_URL}"
if ! curl -fL --retry 5 --retry-delay 3 --retry-all-errors --progress-bar "${DOWNLOAD_URL}" -o "${TMP_TARBALL}"; then
    log_error "Tải gói cài đặt thất bại từ: ${DOWNLOAD_URL}"
    log_warn "Hãy kiểm tra lại kết nối mạng hoặc số hiệu phiên bản '${TARGET_VERSION}'."
    exit 1
fi
log_success "Đã tải xong file lưu trữ ($(du -h "${TMP_TARBALL}" | cut -f1))!"

# ── 6. Giải nén gói cài đặt ───────────────────────────────────────────────────
log_info "Bước 4/6: Đang giải nén bộ cài Anki..."
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"

if command -v zstd &>/dev/null; then
    tar --zstd -xf "${TMP_TARBALL}" -C "${EXTRACT_DIR}"
elif command -v unzstd &>/dev/null; then
    unzstd -c "${TMP_TARBALL}" | tar -xf - -C "${EXTRACT_DIR}"
else
    tar xaf "${TMP_TARBALL}" -C "${EXTRACT_DIR}"
fi

# Tìm thư mục chứa install.sh bên trong thư mục giải nén
SRC_DIR="$(find "${EXTRACT_DIR}" -maxdepth 2 -name "install.sh" -exec dirname {} \; | head -n1 || true)"
if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
    # Fallback nếu giải nén trực tiếp vào root
    SRC_DIR="${EXTRACT_DIR}"
fi

if [[ ! -f "${SRC_DIR}/anki" && ! -f "${SRC_DIR}/install.sh" ]]; then
    log_error "Không tìm thấy cấu trúc hợp lệ của Anki trong thư mục giải nén."
    exit 1
fi
log_success "Giải nén thành công!"

# ── 7. Cài đặt các thư viện phụ thuộc của Qt/Desktop (nếu thiếu) ───────────────
log_info "Bước 5/6: Kiểm tra các thư viện đồ họa hệ thống (GUI / Qt dependencies)..."
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"

    case "${DISTRO_ID}" in
        debian|ubuntu|linuxmint|pop)
            DEBIAN_DEPS=(libdbus-1-3 libfontconfig1 libfreetype6 libgl1 libnss3 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libxcb-xkb1 libxcomposite1 libxcursor1 libxi6 libxkbcommon0 libxkbcommon-x11-0 libxrandr2 libxrender1 libxtst6)
            GLIB_PKG="libglib2.0-0"
            apt-cache show libglib2.0-0t64 &>/dev/null && GLIB_PKG="libglib2.0-0t64"
            ${SUDO_CMD} apt-get install -y "${DEBIAN_DEPS[@]}" "${GLIB_PKG}" 2>/dev/null || true
            ;;
        fedora|rhel|centos|rocky|almalinux)
            FEDORA_DEPS=(nss libxcb xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm fontconfig freetype libglvnd-glx libxkbcommon libxkbcommon-x11)
            ${SUDO_CMD} dnf install -y "${FEDORA_DEPS[@]}" 2>/dev/null || true
            ;;
        arch|manjaro)
            ARCH_DEPS=(nss libxinerama xcb-util-cursor libxkbcommon-x11 fontconfig freetype2)
            ${SUDO_CMD} pacman -S --noconfirm --needed "${ARCH_DEPS[@]}" 2>/dev/null || true
            ;;
    esac
fi

# ── 8. Cài đặt các file vào hệ thống & Desktop Integration ─────────────────────
log_info "Bước 6/6: Cài đặt tệp nhị phân và tích hợp Desktop launcher..."

# Gỡ bỏ phiên bản cũ nếu có uninstall script
if [[ -f "${PREFIX}/share/anki/uninstall.sh" ]]; then
    log_info "Dọn dẹp phiên bản cũ qua uninstall.sh..."
    ${SUDO_CMD} bash "${PREFIX}/share/anki/uninstall.sh" >/dev/null 2>&1 || true
fi

# Dọn dẹp thư mục share/anki và symlink bin/anki cũ
${SUDO_CMD} rm -rf "${PREFIX}/share/anki" "${PREFIX}/bin/anki"
${SUDO_CMD} mkdir -p "${PREFIX}/share/anki" "${PREFIX}/bin" "${PREFIX}/share/pixmaps" "${PREFIX}/share/applications" "${PREFIX}/share/man/man1"

# Sao chép các tệp vào $PREFIX/share/anki
cd "${SRC_DIR}"
${SUDO_CMD} cp -av --no-preserve=owner,context app app_packages python anki anki.1 anki.desktop anki.png anki.xml anki.xpm uninstall.sh README.md "${PREFIX}/share/anki/"

# Tạo symlink vào $PREFIX/bin/anki
${SUDO_CMD} ln -sf "${PREFIX}/share/anki/anki" "${PREFIX}/bin/anki"

# Cài đặt icons, desktop entry, man page
${SUDO_CMD} cp -f "${PREFIX}/share/anki/anki.xpm" "${PREFIX}/share/pixmaps/" 2>/dev/null || true
${SUDO_CMD} cp -f "${PREFIX}/share/anki/anki.png" "${PREFIX}/share/pixmaps/" 2>/dev/null || true
${SUDO_CMD} cp -f "${PREFIX}/share/anki/anki.desktop" "${PREFIX}/share/applications/" 2>/dev/null || true
${SUDO_CMD} cp -f "${PREFIX}/share/anki/anki.1" "${PREFIX}/share/man/man1/" 2>/dev/null || true

# Cập nhật quyền thực thi
${SUDO_CMD} chmod 755 "${PREFIX}/share/anki/anki" "${PREFIX}/bin/anki" "${PREFIX}/share/anki/uninstall.sh"

# Đăng ký MIME types và file associations
if command -v xdg-mime &>/dev/null; then
    ${SUDO_CMD} xdg-mime install "${PREFIX}/share/anki/anki.xml" --novendor 2>/dev/null || true
    ${SUDO_CMD} xdg-mime default anki.desktop application/x-colpkg 2>/dev/null || true
    ${SUDO_CMD} xdg-mime default anki.desktop application/x-apkg 2>/dev/null || true
    ${SUDO_CMD} xdg-mime default anki.desktop application/x-ankiaddon 2>/dev/null || true
fi

if command -v update-desktop-database &>/dev/null; then
    ${SUDO_CMD} update-desktop-database "${PREFIX}/share/applications" 2>/dev/null || true
fi

if command -v update-mime-database &>/dev/null; then
    ${SUDO_CMD} update-mime-database "${PREFIX}/share/mime" 2>/dev/null || true
fi

# ── 9. Xác minh kết quả cài đặt ───────────────────────────────────────────────
if [[ -x "${PREFIX}/bin/anki" ]]; then
    echo ""
    echo -e "${CYAN}=================================================================${NC}"
    log_success "CÀI ĐẶT ANKI ${TARGET_VERSION} THÀNH CÔNG!"
    echo -e "${CYAN}=================================================================${NC}"
    echo -e "  - Binary Location   : ${BOLD}${PREFIX}/bin/anki${NC}"
    echo -e "  - Application Dir   : ${BOLD}${PREFIX}/share/anki${NC}"
    echo -e "  - Desktop Launcher  : ${BOLD}${PREFIX}/share/applications/anki.desktop${NC}"
    echo -e "  - Uninstall Script  : ${BOLD}scripts/anki/uninstall.sh${NC} hoặc ${BOLD}${PREFIX}/share/anki/uninstall.sh${NC}"
    echo "================================================================="
    echo -e "${GREEN}[*]${NC} Bạn có thể khởi động Anki ngay bằng lệnh: ${BOLD}anki${NC}"
    echo -e "${GREEN}[*]${NC} Hoặc tìm kiếm ứng dụng 'Anki' trong Application Launcher của Desktop."
else
    log_error "Cài đặt thất bại: Không tìm thấy binary '${PREFIX}/bin/anki'!"
    exit 1
fi

