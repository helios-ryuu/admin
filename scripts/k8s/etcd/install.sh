#!/usr/bin/env bash
# =============================================================================
# install-etcd.sh
# install.sh (etcd)
# Tải và cài đặt etcd / etcdctl / etcdutl từ GitHub release chính thức.
#
# Usage: ./install-etcd.sh [version]
# Ví dụ: ./install-etcd.sh          # Mặc định v3.5.16
#        ./install-etcd.sh v3.5.15
# Usage: ./install.sh [version]
# Ví dụ: ./install.sh          # Mặc định v3.5.16
#        ./install.sh v3.5.15
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

# 1. Nhận tham số version (mặc định v3.5.16 là bản ổn định phổ biến)
ETCD_VER="${1:-v3.5.16}"
[[ "${ETCD_VER}" =~ ^v ]] || ETCD_VER="v${ETCD_VER}"

# 2. Xác định kiến trúc CPU tự động (amd64, arm64)
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        log_error "Kiến trúc CPU '${ARCH}' chưa được hỗ trợ."
        exit 1
        ;;
esac

TMP_DIR=$(mktemp -d /tmp/etcd-install-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

DOWNLOAD_URL="https://github.com/etcd-io/etcd/releases/download"
TAR_FILE="${TMP_DIR}/etcd-${ETCD_VER}-linux-${ARCH}.tar.gz"

log_info "Tiến hành cài đặt etcd version: ${ETCD_VER} (${ARCH})..."
log_info "Đang tải: ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-${ARCH}.tar.gz"

curl -fsSL "${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-${ARCH}.tar.gz" -o "${TAR_FILE}"

log_info "Giải nén và chuyển binary vào /usr/local/bin..."
tar -xzvf "${TAR_FILE}" -C "${TMP_DIR}" --strip-components=1

chmod +x "${TMP_DIR}"/etcd*

BINARIES=(etcd etcdctl etcdutl)
for bin in "${BINARIES[@]}"; do
    if [[ -f "${TMP_DIR}/${bin}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            mv "${TMP_DIR}/${bin}" /usr/local/bin/
        else
            sudo mv "${TMP_DIR}/${bin}" /usr/local/bin/
        fi
    fi
done

log_success "Cài đặt hoàn tất! Kiểm tra phiên bản:"
etcdctl version
