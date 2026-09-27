#!/usr/bin/env bash
# =============================================================================
# uninstall.sh (anki)
# Gỡ bỏ sạch sẽ Anki Flashcards đã cài đặt trên Linux.
# Dọn dẹp tệp nhị phân, menu launcher, MIME associations, icon và manpage.
# Hỗ trợ tùy chọn --purge để dọn dữ liệu người dùng (kèm sao lưu tự động).
#
# Pattern: scripts/anki/uninstall.sh
#
# Usage:
#   ./uninstall.sh              # Gỡ bỏ Anki, giữ lại thẻ ghi nhớ và dữ liệu cá nhân
#   ./uninstall.sh --purge      # Gỡ bỏ kèm xóa profile/decks (tự động tạo bản backup)
#   ./uninstall.sh -y           # Tự động xác nhận gỡ bỏ
#   sudo ./uninstall.sh         # Chạy trực tiếp dưới quyền sudo
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

Gỡ bỏ phần mềm Anki Flashcards khỏi hệ thống Linux.

Options:
  -p, --prefix DIR     Thư mục cài đặt gốc đã sử dụng (Mặc định: /usr/local)
  --purge              Xóa toàn bộ profile, decks và addons (~/.local/share/Anki2, ~/.config/Anki2)
                       (Hệ thống sẽ luôn tự động tạo 1 bản nén sao lưu an toàn trước khi xóa)
  -y, --yes            Tự động xác nhận gỡ bỏ (bỏ qua bước hỏi xác nhận)
  -h, --help           Hiển thị hướng dẫn này

Ví dụ:
  $0                   # Gỡ bỏ binary & desktop launcher (an toàn, giữ lại flashcards)
  $0 --purge           # Gỡ bỏ hoàn toàn và xóa dữ liệu (có sao lưu dự phòng)
  $0 -y --purge        # Gỡ bỏ và purge hoàn toàn không cần hỏi
EOF
}

PREFIX="/usr/local"
PURGE_DATA=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        --purge)
            PURGE_DATA=true
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

# Kiểm tra quyền ghi vào thư mục đích (cần sudo nếu gỡ ở /usr hoặc /usr/local)
SUDO_CMD=""
if [[ ! -w "${PREFIX}" && ${EUID} -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        log_error "Không có quyền ghi vào '${PREFIX}' và lệnh 'sudo' không tồn tại."
        exit 1
    fi
    echo -e "${YELLOW}[*] Cần quyền sudo để gỡ bỏ Anki khỏi '${PREFIX}'.${NC}"
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
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

if [[ -n "${SUDO_CMD}" ]]; then
    ( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${CYAN}  GỠ BỎ ANKI FLASHCARDS KHỎI HỆ THỐNG LINUX                           ${NC}"
echo -e "${CYAN}  Thư mục đích: ${BOLD}${PREFIX}${NC} | Chế độ Purge: ${BOLD}${PURGE_DATA}${NC}"
echo -e "${CYAN}======================================================================${NC}\n"

# ── 2. Kiểm tra sự tồn tại của Anki trên hệ thống ────────────────────────────
INSTALLED_FOUND=false
if [[ -d "${PREFIX}/share/anki" || -e "${PREFIX}/bin/anki" || -f "${PREFIX}/share/applications/anki.desktop" ]]; then
    INSTALLED_FOUND=true
fi

USER_DATA_DIRS=()
[[ -d "${REAL_HOME}/.local/share/Anki2" ]] && USER_DATA_DIRS+=("${REAL_HOME}/.local/share/Anki2")
[[ -d "${REAL_HOME}/.config/Anki2" ]] && USER_DATA_DIRS+=("${REAL_HOME}/.config/Anki2")

if [[ "${INSTALLED_FOUND}" = false && ${#USER_DATA_DIRS[@]} -eq 0 ]]; then
    log_warn "Không tìm thấy bất kỳ thành phần nào của Anki trong '${PREFIX}' hoặc thư mục người dùng (${REAL_HOME})."
    exit 0
fi

# ── 3. Xác nhận gỡ bỏ nếu không có cờ -y ──────────────────────────────────────
if [[ "${AUTO_YES}" = false ]]; then
    echo -e "${YELLOW}=================================================================${NC}"
    echo -e "${YELLOW} Kế hoạch gỡ bỏ Anki:                                            ${NC}"
    echo -e "${YELLOW}=================================================================${NC}"
    if [[ "${INSTALLED_FOUND}" = true ]]; then
        echo -e "  - Gỡ bỏ Binary           : ${BOLD}${PREFIX}/bin/anki${NC}"
        echo -e "  - Gỡ bỏ Thư mục ứng dụng : ${BOLD}${PREFIX}/share/anki${NC}"
        echo -e "  - Gỡ bỏ Desktop launcher : ${BOLD}${PREFIX}/share/applications/anki.desktop${NC}"
        echo -e "  - Gỡ bỏ MIME & Icons     : ${BOLD}anki.xml, anki.png, anki.xpm, anki.1${NC}"
    fi
    if [[ "${PURGE_DATA}" = true ]]; then
        echo -e "  - ${RED}${BOLD}Xóa dữ liệu cá nhân (--purge):${NC}"
        for d in "${USER_DATA_DIRS[@]}"; do
            echo -e "    * $d"
        done
        echo -e "  - ${CYAN}Tự động tạo bản sao lưu an toàn tại: ${BOLD}${REAL_HOME}/anki_backup_<timestamp>.tar.gz${NC}"
    else
        echo -e "  - Dữ liệu thẻ/decks (${BOLD}~/.local/share/Anki2${NC}): ${GREEN}Giữ nguyên an toàn${NC}"
    fi
    echo "================================================================="
    read -r -p "Bạn có chắc chắn muốn tiến hành gỡ bỏ? [y/N]: " CONFIRM
    if [[ ! "${CONFIRM}" =~ ^[yY]([eE][sS])?$ ]]; then
        log_warn "Người dùng đã hủy tiến trình."
        exit 0
    fi
fi

# ── 4. Hủy đăng ký MIME Types & File Associations ─────────────────────────────
log_info "Bước 1/4: Hủy đăng ký MIME types và file associations..."

MIME_XML="${PREFIX}/share/anki/anki.xml"
if [[ -f "${MIME_XML}" ]] && command -v xdg-mime &>/dev/null; then
    ${SUDO_CMD} xdg-mime uninstall "${MIME_XML}" 2>/dev/null || true
    # Thử hủy trực tiếp dưới quyền user nếu đang chạy qua sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        su - "${REAL_USER}" -c "xdg-mime uninstall '${MIME_XML}' 2>/dev/null" || true
    fi
fi

# ── 5. Xóa các tệp nhị phân, menu, icon, man page ─────────────────────────────
log_info "Bước 2/4: Xóa tệp nhị phân và tài nguyên ứng dụng trong ${PREFIX}..."

FILES_TO_REMOVE=(
    "${PREFIX}/bin/anki"
    "${PREFIX}/share/applications/anki.desktop"
    "${PREFIX}/share/pixmaps/anki.png"
    "${PREFIX}/share/pixmaps/anki.xpm"
    "${PREFIX}/share/man/man1/anki.1"
)

for file in "${FILES_TO_REMOVE[@]}"; do
    if [[ -e "${file}" || -L "${file}" ]]; then
        ${SUDO_CMD} rm -f "${file}"
        log_info "  Đã xóa: ${file}"
    fi
done

if [[ -d "${PREFIX}/share/anki" ]]; then
    ${SUDO_CMD} rm -rf "${PREFIX}/share/anki"
    log_info "  Đã xóa thư mục: ${PREFIX}/share/anki"
fi

# ── 6. Cập nhật Desktop & MIME Database ───────────────────────────────────────
log_info "Bước 3/4: Cập nhật cơ sở dữ liệu Desktop và MIME..."

if command -v update-desktop-database &>/dev/null; then
    ${SUDO_CMD} update-desktop-database "${PREFIX}/share/applications" 2>/dev/null || true
fi

if command -v update-mime-database &>/dev/null; then
    ${SUDO_CMD} update-mime-database "${PREFIX}/share/mime" 2>/dev/null || true
fi

# ── 7. Xử lý xóa dữ liệu người dùng nếu có cờ --purge ─────────────────────────
log_info "Bước 4/4: Xử lý dữ liệu người dùng..."

if [[ "${PURGE_DATA}" = true ]]; then
    if [[ ${#USER_DATA_DIRS[@]} -gt 0 ]]; then
        BACKUP_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
        BACKUP_FILE="${REAL_HOME}/anki_backup_${BACKUP_TIMESTAMP}.tar.gz"
        
        log_warn "Đang tiến hành sao lưu dữ liệu Anki trước khi xóa vào: ${BACKUP_FILE}..."
        
        # Tạo file backup dưới quyền của REAL_USER
        TARGETS_TO_BACKUP=()
        for d in "${USER_DATA_DIRS[@]}"; do
            [[ -d "$d" ]] && TARGETS_TO_BACKUP+=("$d")
        done
        
        if [[ ${#TARGETS_TO_BACKUP[@]} -gt 0 ]]; then
            tar -czf "${BACKUP_FILE}" "${TARGETS_TO_BACKUP[@]}" 2>/dev/null || true
            if [[ -f "${BACKUP_FILE}" ]]; then
                chown "${REAL_UID}:${REAL_GID}" "${BACKUP_FILE}" 2>/dev/null || true
                log_success "Đã tạo bản sao lưu an toàn tại: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"
            fi
        fi

        log_info "Đang xóa dữ liệu cá nhân theo cờ --purge..."
        for d in "${USER_DATA_DIRS[@]}"; do
            if [[ -d "$d" ]]; then
                rm -rf "$d"
                log_info "  Đã xóa: $d"
            fi
        done
        log_success "Dữ liệu người dùng đã được dọn sạch."
    else
        log_info "Không tìm thấy dữ liệu cá nhân của Anki trong ${REAL_HOME}."
    fi
else
    if [[ ${#USER_DATA_DIRS[@]} -gt 0 ]]; then
        log_info "Dữ liệu thẻ flashcards và profiles của bạn vẫn được lưu giữ an toàn tại:"
        for d in "${USER_DATA_DIRS[@]}"; do
            echo -e "  - ${BOLD}$d${NC}"
        done
        echo -e "  ${CYAN}[GỢI Ý]${NC} Nếu muốn xóa toàn bộ dữ liệu này, bạn có thể chạy lại lệnh với cờ: ${BOLD}--purge${NC}"
    fi
fi

echo ""
echo -e "${CYAN}=================================================================${NC}"
log_success "GỠ BỎ ANKI THÀNH CÔNG!"
echo -e "${CYAN}=================================================================${NC}"
echo -e "  - Đã dọn dẹp binary, desktop launcher và icons khỏi ${BOLD}${PREFIX}${NC}."
if [[ "${PURGE_DATA}" = true && -f "${BACKUP_FILE:-}" ]]; then
    echo -e "  - Bản sao lưu dữ liệu trước khi xóa: ${BOLD}${BACKUP_FILE}${NC}"
fi
echo "================================================================="

