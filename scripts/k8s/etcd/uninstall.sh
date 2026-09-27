#!/usr/bin/env bash
# =============================================================================
# uninstall-etcd.sh
# uninstall.sh (etcd)
# Dừng tiến trình etcd và gỡ bỏ toàn bộ binary etcd / etcdctl / etcdutl
#
# Usage: ./uninstall-etcd.sh
# Usage: ./uninstall.sh
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

# 1. Dừng tiến trình etcd nếu đang chạy
if pgrep -x "etcd" > /dev/null 2>&1; then
    log_info "Đang dừng tiến trình etcd..."
    sudo pkill -15 -x etcd 2>/dev/null || true
    sleep 1
    if pgrep -x "etcd" > /dev/null 2>&1; then
        sudo pkill -9 -x etcd 2>/dev/null || true
    fi
fi

# 2. Xóa các file binary trong /usr/local/bin
log_info "Xóa các binary etcd trong /usr/local/bin..."
for bin in etcd etcdctl etcdutl; do
    if [[ -f "/usr/local/bin/${bin}" ]]; then
        sudo rm -f "/usr/local/bin/${bin}"
        log_info "-> Đã xóa /usr/local/bin/${bin}"
    fi
done

# 3. Dọn dẹp thư mục dữ liệu mặc định của etcd (nếu có)
if [[ -d "default.etcd" ]]; then
    log_info "Xóa thư mục dữ liệu mặc định default.etcd..."
    rm -rf default.etcd
fi

log_success "Hoàn tất gỡ bỏ etcd!"
