#!/usr/bin/env bash
# =============================================================================
# uninstall-fcitx5.sh
# uninstall.sh (fcitx5)
# Gỡ bỏ hoàn toàn bộ gõ Fcitx 5 và hoàn nguyên (revert) mọi cấu hình trên Fedora KDE
# (Hoàn nguyên DNF packages, environment.d, kwinrc Wayland, Flatpak overrides & cache)
#
# Usage:
#   ./uninstall-fcitx5.sh          # Gỡ bỏ và dọn dẹp (tạo backup config)
#   ./uninstall-fcitx5.sh --purge  # Gỡ bỏ sạch sẽ hoàn toàn không giữ lại gì
#   sudo ./uninstall-fcitx5.sh     # Chạy trực tiếp với sudo
#   ./uninstall.sh          # Gỡ bỏ và dọn dẹp (tạo backup config)
#   ./uninstall.sh --purge  # Gỡ bỏ sạch sẽ hoàn toàn không giữ lại gì
#   sudo ./uninstall.sh     # Chạy trực tiếp với sudo
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

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge|-p)
            PURGE=1
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Gỡ bỏ hoàn toàn Fcitx 5 và hoàn nguyên cấu hình trên Fedora KDE Plasma.

Options:
  -p, --purge    Xóa sạch toàn bộ thư mục cấu hình ~/.config/fcitx5 (không tạo backup)
  -h, --help     Hiển thị trợ giúp này
EOF
            exit 0
            ;;
    esac
done

# ── 0. Xác định quyền & Target User ──────────────────────────────────────────
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
    echo -e "${YELLOW}[*] Cần quyền sudo để gỡ bỏ các gói hệ thống qua DNF.${NC}"
    if ! sudo -v; then
        log_error "Không thể xác thực quyền sudo. Dừng tiến trình."
        exit 1
    fi
fi

# Giữ sudo session sống
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

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}  GỠ BỎ & HOÀN NGUYÊN BỘ GÕ FCITX 5 TRÊN FEDORA KDE PLASMA       ${NC}"
echo -e "${CYAN}  Target User: ${BOLD}${REAL_USER}${NC} (${REAL_HOME})"
echo -e "${CYAN}=================================================================${NC}\n"

# ── Bước 1: Dừng tiến trình Fcitx 5 đang chạy ────────────────────────────────
log_info "Bước 1/6: Dừng các tiến trình Fcitx 5 đang hoạt động..."

if pgrep -x fcitx5 &>/dev/null; then
    run_user pkill -x fcitx5 2>/dev/null || true
    sleep 1
    if pgrep -x fcitx5 &>/dev/null; then
        run_root pkill -9 -x fcitx5 2>/dev/null || true
    fi
    log_success "Đã dừng thành công daemon Fcitx 5."
else
    log_info "Không có tiến trình Fcitx 5 nào đang chạy."
fi

# ── Bước 2: Xóa biến môi trường environment.d ────────────────────────────────
log_info "Bước 2/6: Xóa bỏ cấu hình biến môi trường systemd user..."

ENV_CONF="${REAL_HOME}/.config/environment.d/fcitx5.conf"
if [[ -f "${ENV_CONF}" ]]; then
    rm -f "${ENV_CONF}"
    log_success "Đã xóa file: ${ENV_CONF}"
else
    log_info "File ${ENV_CONF} không tồn tại (bỏ qua)."
fi

# ── Bước 3: Hoàn nguyên cấu hình KDE Plasma 6 Wayland (kwinrc) ───────────────
log_info "Bước 3/6: Hoàn nguyên thiết lập Input Method trong kwinrc..."

KWIN_RC="${REAL_HOME}/.config/kwinrc"
DEFAULT_KDE_IM="/usr/share/applications/org.kde.plasma.keyboard.desktop"

if [[ -f "${KWIN_RC}" ]]; then
    if command -v kwriteconfig6 &>/dev/null; then
        if [[ -f "${DEFAULT_KDE_IM}" ]]; then
            QT_QPA_PLATFORM=offscreen run_user kwriteconfig6 \
                --file "${KWIN_RC}" \
                --group "Wayland" \
                --key "InputMethod" "${DEFAULT_KDE_IM}" || true
            log_success "Đã khôi phục Input Method mặc định của KDE Plasma (${DEFAULT_KDE_IM})."
        else
            QT_QPA_PLATFORM=offscreen run_user kwriteconfig6 \
                --file "${KWIN_RC}" \
                --group "Wayland" \
                --key "InputMethod" --delete || true
            log_success "Đã xóa khóa InputMethod trong kwinrc."
        fi
    else
        sed -i '/^InputMethod=.*fcitx/d' "${KWIN_RC}" 2>/dev/null || true
        log_success "Đã xóa dòng cấu hình InputMethod Fcitx 5 trong kwinrc."
    fi
fi

# ── Bước 4: Hoàn nguyên Flatpak Overrides ─────────────────────────────────────
log_info "Bước 4/6: Hoàn nguyên quyền Flatpak overrides..."

if command -v flatpak &>/dev/null; then
    run_user flatpak override --user --no-talk-name=org.fcitx.Fcitx5 2>/dev/null || true
    run_user flatpak override --user --no-talk-name=org.freedesktop.portal.Fcitx 2>/dev/null || true
    run_user flatpak override --user --nofilesystem=xdg-run/fcitx5 2>/dev/null || true
    run_user flatpak override --user --unset-env=GTK_IM_MODULE 2>/dev/null || true
    run_user flatpak override --user --unset-env=QT_IM_MODULE 2>/dev/null || true
    log_success "Đã xóa toàn bộ quyền override liên quan Fcitx 5 trong Flatpak."
else
    log_info "Flatpak không được cài đặt (bỏ qua)."
fi

# ── Bước 5: Dọn dẹp thư mục cấu hình người dùng (~/.config/fcitx5) ────────────
log_info "Bước 5/6: Xử lý thư mục cấu hình và cache Fcitx 5..."

FCITX5_CONFIG_DIR="${REAL_HOME}/.config/fcitx5"
FCITX5_AUTOSTART="${REAL_HOME}/.config/autostart/org.fcitx.Fcitx5.desktop"

if [[ -f "${FCITX5_AUTOSTART}" ]]; then
    rm -f "${FCITX5_AUTOSTART}"
    log_success "Đã xóa user autostart entry: ${FCITX5_AUTOSTART}"
fi

if [[ -d "${FCITX5_CONFIG_DIR}" ]]; then
    if [[ ${PURGE} -eq 1 ]]; then
        rm -rf "${FCITX5_CONFIG_DIR}"
        log_success "Đã xóa sạch thư mục cấu hình: ${FCITX5_CONFIG_DIR}"
    else
        BACKUP_DIR="${FCITX5_CONFIG_DIR}.bak_$(date +%Y%m%d_%H%M%S)"
        mv "${FCITX5_CONFIG_DIR}" "${BACKUP_DIR}"
        log_success "Đã sao lưu cấu hình cũ sang: ${BACKUP_DIR}"
        log_info "Mẹo: Để xóa hẳn mà không backup, dùng cờ: $0 --purge"
    fi
fi

# Xóa cache liên quan nếu có
rm -rf "${REAL_HOME}/.cache/fcitx5" 2>/dev/null || true

# ── Bước 6: Gỡ bỏ toàn bộ gói DNF Fcitx 5 ────────────────────────────────────
log_info "Bước 6/6: Gỡ bỏ các gói Fcitx 5 qua DNF..."

FCITX5_PKGS=(
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

INSTALLED_PKGS=()
for pkg in "${FCITX5_PKGS[@]}"; do
    if rpm -q "${pkg}" &>/dev/null; then
        INSTALLED_PKGS+=("${pkg}")
    fi
done

if [[ ${#INSTALLED_PKGS[@]} -gt 0 ]]; then
    log_info "Đang gỡ bỏ các gói: ${INSTALLED_PKGS[*]}..."
    run_root dnf remove -y "${INSTALLED_PKGS[@]}"
    log_success "Đã gỡ bỏ thành công toàn bộ gói RPM Fcitx 5."
else
    log_info "Không có gói RPM Fcitx 5 nào đang cài trên hệ thống."
fi

# ── Hoàn tất ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=================================================================${NC}"
echo -e "${GREEN}${BOLD}✓ QUÁ TRÌNH GỠ BỎ & HOÀN NGUYÊN FCITX 5 ĐÃ HOÀN TẤT!${NC}"
echo -e "${CYAN}=================================================================${NC}\n"

echo -e "${BOLD}Các tác vụ đã thực hiện:${NC}"
echo -e "  1. Đã dừng toàn bộ tiến trình daemon Fcitx 5."
echo -e "  2. Đã xóa file biến môi trường ${ENV_CONF}."
echo -e "  3. Đã khôi phục InputMethod trong kwinrc về mặc định."
echo -e "  4. Đã gỡ bỏ các quyền Flatpak overrides liên quan Fcitx 5."
echo -e "  5. Đã dọn dẹp thư mục cấu hình và cache người dùng."
echo -e "  6. Đã gỡ bỏ toàn bộ gói RPM Fcitx 5 qua DNF."

echo -e "\n${BOLD}Khuyến nghị:${NC}"
echo -e "  Đăng xuất (Log out) và đăng nhập lại để hệ thống áp dụng hoàn toàn trạng thái sạch ban đầu."
echo ""

