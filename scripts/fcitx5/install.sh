#!/usr/bin/env bash
# =============================================================================
# install-fcitx5.sh
# install.sh (fcitx5)
# Cài đặt và chuẩn hóa bộ gõ Fcitx 5 Tiếng Việt (Unikey) trên Fedora KDE Plasma
# (Hỗ trợ Wayland native, Qt5/Qt6, GTK2/3/4, XWayland và Flatpak apps)
#
# Usage:
#   ./install-fcitx5.sh       # Tự động xin sudo khi cần
#   sudo ./install-fcitx5.sh  # Chạy trực tiếp với sudo
#   ./install.sh       # Tự động xin sudo khi cần
#   sudo ./install.sh  # Chạy trực tiếp với sudo
# =============================================================================

set -Eeuo pipefail

# ANSI color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} ${BOLD}$1${NC}"; }

# ── 0. Xác định quyền & Target User ──────────────────────────────────────────
# Đảm bảo các file cấu hình người dùng (~/.config/...) luôn thuộc sở hữu của user,
# ngay cả khi script được thực thi dưới quyền sudo.
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

# Yêu cầu / kiểm tra quyền Root/Sudo từ đầu
if [[ ${EUID} -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        log_error "Lệnh 'sudo' không tồn tại. Vui lòng chạy dưới quyền root."
        exit 1
    fi
    echo -e "${YELLOW}[*] Cần quyền sudo để cài đặt các gói hệ thống qua DNF.${NC}"
    if ! sudo -v; then
        log_error "Không thể xác thực quyền sudo. Dừng tiến trình."
        exit 1
    fi
fi

# Giữ sudo session sống trong suốt quá trình chạy
SUDO_KEEPALIVE_PID=""
cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [[ ${EUID} -ne 0 ]]; then
    ( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
fi

run_root() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_user() {
    if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "${REAL_USER}" "$@"
    else
        "$@"
    fi
}

# ── Kiểm tra hệ điều hành Fedora ─────────────────────────────────────────────
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "fedora" && "${ID_LIKE:-}" != *"fedora"* ]]; then
        log_warn "Hệ điều hành hiện tại không phải là Fedora Linux (${NAME:-Unknown})."
        log_warn "Script này được thiết kế tối ưu cho Fedora DNF và KDE Plasma."
    fi
fi

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}  CÀI ĐẶT & CHUẨN HÓA BỘ GÕ FCITX 5 (UNIKEY) TRÊN FEDORA KDE     ${NC}"
echo -e "${CYAN}  Target User: ${BOLD}${REAL_USER}${NC} (${REAL_HOME})"
echo -e "${CYAN}=================================================================${NC}\n"

# ── Bước 1: Cài đặt toàn bộ gói DNF cốt lõi (Idempotent) ────────────────────
log_info "Bước 1/5: Kiểm tra và cài đặt các gói Fcitx 5 qua DNF..."

REQUIRED_PKGS=(
    fcitx5
    fcitx5-unikey
    kcm-fcitx5
    fcitx5-qt5
    fcitx5-qt6
    fcitx5-gtk2
    fcitx5-gtk3
    fcitx5-gtk4
    fcitx5-autostart
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! rpm -q "${pkg}" &>/dev/null; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    log_info "Đang cài đặt các gói thiếu: ${MISSING_PKGS[*]}..."
    run_root dnf install -y "${MISSING_PKGS[@]}"
    log_success "Đã cài đặt thành công toàn bộ các gói Fcitx 5 cần thiết."
else
    log_success "Toàn bộ các gói Fcitx 5 cốt lõi đã được cài đặt trên hệ thống."
fi

# ── Bước 2: Thiết lập biến môi trường qua environment.d ──────────────────────
log_info "Bước 2/5: Cấu hình biến môi trường người dùng (systemd environment.d)..."

ENV_DIR="${REAL_HOME}/.config/environment.d"
ENV_CONF="${ENV_DIR}/fcitx5.conf"

run_user mkdir -p "${ENV_DIR}"

cat << 'EOF' | run_user tee "${ENV_CONF}" > /dev/null
# Fcitx 5 Input Method Configuration for KDE Plasma (Wayland / XWayland)
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF

run_root chown -R "${REAL_USER}:${REAL_GID}" "${ENV_DIR}"
log_success "Đã tạo cấu hình môi trường tại: ${ENV_CONF}"

# ── Bước 3: Cấu hình KDE Plasma 6 Wayland Input Method (kwinrc) ─────────────
log_info "Bước 3/5: Tích hợp Fcitx 5 vào KDE Plasma Virtual Keyboard / Input Method..."

KWIN_RC="${REAL_HOME}/.config/kwinrc"
IM_DESKTOP="/usr/share/applications/org.fcitx.Fcitx5.desktop"

if command -v kwriteconfig6 &>/dev/null; then
    # Dùng kwriteconfig6 với QT_QPA_PLATFORM=offscreen để không phụ thuộc display server
    QT_QPA_PLATFORM=offscreen run_user kwriteconfig6 \
        --file "${KWIN_RC}" \
        --group "Wayland" \
        --key "InputMethod" "${IM_DESKTOP}" || true
    log_success "Đã gán Fcitx 5 làm Input Method trong kwinrc qua kwriteconfig6."
else
    # Fallback ghi trực tiếp vào kwinrc nếu chưa có kwriteconfig6
    if [[ ! -f "${KWIN_RC}" ]]; then
        run_user touch "${KWIN_RC}"
    fi
    if grep -q '^\[Wayland\]' "${KWIN_RC}" 2>/dev/null; then
        if grep -q '^InputMethod=' "${KWIN_RC}"; then
            sed -i "s|^InputMethod=.*|InputMethod=${IM_DESKTOP}|" "${KWIN_RC}"
        else
            sed -i "/^\[Wayland\]/a InputMethod=${IM_DESKTOP}" "${KWIN_RC}"
        fi
    else
        cat << EOF >> "${KWIN_RC}"

[Wayland]
InputMethod=${IM_DESKTOP}
EOF
    fi
    run_root chown "${REAL_USER}:${REAL_GID}" "${KWIN_RC}"
    log_success "Đã cập nhật kwinrc (Wayland InputMethod = Fcitx 5)."
fi

# ── Bước 4: Khởi tạo Profile Fcitx 5 (Keyboard US + Unikey) ──────────────────
log_info "Bước 4/5: Khởi tạo cấu hình nhóm bàn phím Fcitx 5 (US + Unikey)..."

FCITX5_CONFIG_DIR="${REAL_HOME}/.config/fcitx5"
FCITX5_PROFILE="${FCITX5_CONFIG_DIR}/profile"
FCITX5_CONFIG="${FCITX5_CONFIG_DIR}/config"

run_user mkdir -p "${FCITX5_CONFIG_DIR}"

if [[ ! -f "${FCITX5_PROFILE}" ]]; then
    cat << 'EOF' | run_user tee "${FCITX5_PROFILE}" > /dev/null
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=unikey

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=unikey
Layout=

[GroupOrder]
0=Default
EOF
    log_success "Đã tạo profile mặc định: Keyboard (US) + Unikey (Tiếng Việt)."
else
    log_info "Profile Fcitx 5 đã tồn tại tại ${FCITX5_PROFILE} (giữ nguyên)."
fi

# Thiết lập phím tắt chuyển đổi bộ gõ (Mặc định: Ctrl + Space)
if [[ ! -f "${FCITX5_CONFIG}" ]]; then
    cat << 'EOF' | run_user tee "${FCITX5_CONFIG}" > /dev/null
[Hotkey]
# Enumerate when press trigger key repeatedly
EnumerateWithTriggerKeys=True
# Skip first input method while enumerating
EnumerateSkipFirst=False

[Hotkey/TriggerKeys]
0=Control+space
EOF
    log_success "Đã cấu hình phím tắt chuyển đổi bộ gõ: Ctrl + Space."
fi

run_root chown -R "${REAL_USER}:${REAL_GID}" "${FCITX5_CONFIG_DIR}"

# ── Bước 5: Cấu hình Flatpak Overrides cho Fcitx 5 ───────────────────────────
log_info "Bước 5/5: Cấu hình Flatpak permission overrides cho Fcitx 5..."

if command -v flatpak &>/dev/null; then
    run_user flatpak override --user --talk-name=org.fcitx.Fcitx5 2>/dev/null || true
    run_user flatpak override --user --talk-name=org.freedesktop.portal.Fcitx 2>/dev/null || true
    run_user flatpak override --user --filesystem=xdg-run/fcitx5:ro 2>/dev/null || true
    run_user flatpak override --user --env=GTK_IM_MODULE=fcitx 2>/dev/null || true
    run_user flatpak override --user --env=QT_IM_MODULE=fcitx 2>/dev/null || true
    log_success "Đã cấp quyền socket & biến môi trường Fcitx 5 cho toàn bộ ứng dụng Flatpak."
else
    log_info "Flatpak không được cài đặt trên máy, bỏ qua cấu hình Flatpak."
fi

# ── Hoàn tất & Hướng dẫn sử dụng ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}=================================================================${NC}"
echo -e "${GREEN}${BOLD}✓ QUÁ TRÌNH CÀI ĐẶT & THIẾT LẬP FCITX 5 ĐÃ HOÀN TẤT THÀNH CÔNG!${NC}"
echo -e "${CYAN}=================================================================${NC}\n"

echo -e "${BOLD}Các cấu hình đã được áp dụng:${NC}"
echo -e "  1. Các gói RPM cốt lõi  : fcitx5, fcitx5-unikey, kcm-fcitx5, fcitx5-qt5/6, fcitx5-gtk2/3/4"
echo -e "  2. Biến môi trường      : ${ENV_CONF}"
echo -e "  3. KDE Plasma 6 Wayland : InputMethod = org.fcitx.Fcitx5.desktop (kwinrc)"
echo -e "  4. Danh sách bộ gõ      : Keyboard (US) + Unikey (Phím tắt: ${BOLD}Ctrl + Space${NC})"
echo -e "  5. Ứng dụng Flatpak     : Đã bật socket chia sẻ Fcitx 5 cho Discord, Zen, Obsidian,..."

echo -e "\n${BOLD}Bước tiếp theo để bắt đầu sử dụng:${NC}"
echo -e "  - ${CYAN}Cách 1 (Khuyến nghị):${NC} Đăng xuất (Log out) và đăng nhập lại KDE Plasma session."
echo -e "  - ${CYAN}Cách 2 (Thử nghiệm ngay):${NC} Chạy lệnh sau trong terminal:"
echo -e "       ${BOLD}fcitx5 -d -r &${NC}"
echo -e "  - Để tùy chỉnh kiểu gõ (Telex/VNI/Simple Telex) hoặc giao diện:"
echo -e "       Mở ${BOLD}KDE System Settings${NC} -> ${BOLD}Input Devices${NC} -> ${BOLD}Virtual Keyboard / Input Method${NC}"
echo ""

