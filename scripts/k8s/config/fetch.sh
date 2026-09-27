#!/usr/bin/env bash
# =============================================================================
# fetch-kubeconfig.sh (fetch-config.sh)
# fetch.sh (fetch-config.sh / fetch-kubeconfig.sh)
# Tự động kết nối SSH tới máy chủ từ xa để lấy file cấu hình (Kubeconfig / K3s
# hoặc file cấu hình bất kỳ) về máy cục bộ.
#
# Tính năng nổi bật:
#   - Tự động nhận diện đường dẫn Kubeconfig trên máy chủ (K3s, Kubeadm, MicroK8s).
#   - Hỗ trợ lấy file yêu cầu quyền root qua SSH (remote sudo escalation).
#   - Tự động thay thế endpoint '127.0.0.1 / localhost' bằng IP/Hostname máy chủ.
#   - Hỗ trợ lấy file cấu hình tùy ý bất kỳ (-f /remote/path -o /local/path).
#   - Tự động sao lưu file cấu hình cũ trước khi ghi đè, phân quyền an toàn 0600.
#   - Kiểm tra ngay trạng thái cluster ('kubectl get nodes') sau khi tải.
#
# Usage:
#   ./fetch-kubeconfig.sh <user@host> [options]
#   ./fetch-kubeconfig.sh user@192.168.1.100
#   ./fetch-kubeconfig.sh user@master-node -s 100.64.0.1
#   ./fetch-kubeconfig.sh user@server -f /etc/nginx/nginx.conf -o ./nginx.conf
#   ./fetch.sh <user@host> [options]
#   ./fetch.sh user@192.168.1.100
#   ./fetch.sh user@master-node -s 100.64.0.1
#   ./fetch.sh user@server -f /etc/nginx/nginx.conf -o ./nginx.conf
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
Usage: $0 <[user@]host> [OPTIONS]

Lấy file cấu hình Kubeconfig (hoặc file cấu hình bất kỳ) từ máy chủ từ xa qua SSH.

Arguments:
  [user@]host            Địa chỉ máy chủ từ xa

Options:
  -f, --file PATH        Đường dẫn file trên máy từ xa.
                         (Mặc định: Tự động dò tìm /etc/rancher/k3s/k3s.yaml,
                          /etc/kubernetes/admin.conf, hoặc ~/.kube/config)
  -o, --output PATH      Đường dẫn lưu file trên máy cục bộ.
                         (Mặc định Kubeconfig: ~/.kube/config)
  -p, --port PORT        Cổng SSH của máy chủ (Mặc định: 22)
  -i, --identity KEY     Đường dẫn SSH private key để xác thực
  -s, --server HOST/IP   Địa chỉ IP/Hostname máy chủ dùng để thay thế 127.0.0.1 trong Kubeconfig.
                         (Mặc định: Tự động dùng Host/IP lấy từ SSH target)
  -c, --context NAME     Đổi tên Context trong Kubeconfig (ví dụ: my-k3s-cluster)
  -m, --merge            Gộp cấu hình vào ~/.kube/config hiện tại thay vì ghi đè
  -y, --yes              Tự động đồng ý ghi đè/sao lưu không cần hỏi xác nhận
  -h, --help             Hiển thị hướng dẫn này

Ví dụ thực tế:
  # 1. Lấy Kubeconfig từ K3s Master Node về ~/.kube/config:
  $0 user@100.64.0.0

  # 2. Lấy Kubeconfig và lưu ra file riêng:
  $0 user@master-node -o ~/.kube/config-k3s

  # 3. Lấy Kubeconfig qua cổng SSH tùy chỉnh và chỉ định SSH key:
  $0 user@192.168.1.10 -p 22 -i ~/.ssh/id_ed25519

  # 4. Lấy một file cấu hình bất kỳ trên máy từ xa (có hỗ trợ quyền root):
  $0 user@192.168.1.50 -f /etc/rancher/k3s/config.yaml -o ./config.yaml
EOF
}

# Khởi tạo biến
SSH_TARGET=""
REMOTE_FILE=""
LOCAL_OUTPUT=""
SSH_PORT="22"
SSH_KEY=""
SERVER_OVERRIDE=""
CONTEXT_NAME=""
MERGE_MODE=false
AUTO_CONFIRM=false

# Phân tích tham số dòng lệnh
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--file)
            REMOTE_FILE="$2"
            shift 2
            ;;
        -o|--output)
            LOCAL_OUTPUT="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        -s|--server)
            SERVER_OVERRIDE="$2"
            shift 2
            ;;
        -c|--context)
            CONTEXT_NAME="$2"
            shift 2
            ;;
        -m|--merge)
            MERGE_MODE=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -*)
            log_error "Tùy chọn không hợp lệ: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ -z "${SSH_TARGET}" ]]; then
                SSH_TARGET="$1"
                shift
            else
                log_error "Tham số không xác định: $1"
                show_help
                exit 1
            fi
            ;;
    esac
done

# Kiểm tra SSH_TARGET
if [[ -z "${SSH_TARGET}" ]]; then
    log_error "Thiếu địa chỉ máy chủ SSH! Vui lòng truyền [user@]host."
    echo ""
    show_help
    exit 1
fi

# Tách Host/IP từ SSH_TARGET (bỏ phần user@ nếu có)
REMOTE_HOST="${SSH_TARGET#*@}"
# Nếu có cổng trong hostname dạng host:port
if [[ "${REMOTE_HOST}" =~ : ]]; then
    SSH_PORT="${REMOTE_HOST#*:}"
    REMOTE_HOST="${REMOTE_HOST%:*}"
    SSH_TARGET="${SSH_TARGET%:*}"
fi

# Xây dựng mảng SSH options
SSH_OPTS=(-p "${SSH_PORT}" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY}" ]]; then
    if [[ ! -f "${SSH_KEY}" ]]; then
        log_error "Không tìm thấy file SSH key tại: ${SSH_KEY}"
        exit 1
    fi
    SSH_OPTS+=(-i "${SSH_KEY}")
fi

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}  FETCH CONFIG / KUBECONFIG OVER SSH                             ${NC}"
echo -e "${CYAN}  Target: ${BOLD}${SSH_TARGET}${NC} (Port: ${SSH_PORT})"
echo -e "${CYAN}=================================================================${NC}\n"

# ── 1. Kiểm tra kết nối SSH tới máy chủ ─────────────────────────────────────
log_info "Bước 1/5: Kiểm tra kết nối SSH tới ${SSH_TARGET}..."

if ! ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "true" 2>/dev/null; then
    log_error "Không thể kết nối SSH tới ${SSH_TARGET} qua cổng ${SSH_PORT}."
    log_warn "Gợi ý kiểm tra:"
    echo "  - Máy chủ đã bật dịch vụ sshd chưa?"
    echo "  - Cổng ${SSH_PORT} có bị firewall chặn không?"
    echo "  - Public key hoặc mật khẩu SSH có chính xác không?"
    exit 1
fi
log_success "Kết nối SSH thành công!"

# ── 2. Xác định file cấu hình cần lấy ─────────────────────────────────────────
IS_KUBECONFIG=false

if [[ -z "${REMOTE_FILE}" ]]; then
    log_info "Bước 2/5: Tự động dò tìm file Kubeconfig trên ${SSH_TARGET}..."
    
    # Kiểm tra lần lượt các đường dẫn Kubeconfig phổ biến trên máy từ xa
    PROBE_SCRIPT='
        for p in /etc/rancher/k3s/k3s.yaml /etc/kubernetes/admin.conf $HOME/.kube/config /var/snap/microk8s/current/credentials/client.config; do
            if [ -f "$p" ] || sudo test -f "$p" 2>/dev/null; then
                echo "$p"
                exit 0
            fi
        done
        exit 1
    '
    
    DETECTED_FILE=$(ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${PROBE_SCRIPT}" 2>/dev/null || true)
    
    if [[ -n "${DETECTED_FILE}" ]]; then
        REMOTE_FILE="${DETECTED_FILE}"
        IS_KUBECONFIG=true
        log_success "Đã phát hiện Kubeconfig tại: ${BOLD}${REMOTE_FILE}${NC}"
    else
        log_error "Không tự động tìm thấy file Kubeconfig trên máy chủ."
        log_warn "Vui lòng chỉ định đường dẫn file cụ thể bằng cờ: -f <đường_dẫn_file>"
        exit 1
    fi
else
    log_info "Bước 2/5: Sử dụng file được chỉ định: ${BOLD}${REMOTE_FILE}${NC}"
    # Nhận diện nếu file chỉ định là kubeconfig
    if [[ "${REMOTE_FILE}" =~ (k3s\.yaml|admin\.conf|kube.*config|\.kube/config) ]]; then
        IS_KUBECONFIG=true
    fi
fi

# Thiết lập đường dẫn lưu cục bộ nếu chưa chỉ định
if [[ -z "${LOCAL_OUTPUT}" ]]; then
    if [[ "${IS_KUBECONFIG}" == "true" ]]; then
        LOCAL_OUTPUT="${HOME}/.kube/config"
    else
        LOCAL_OUTPUT="./$(basename "${REMOTE_FILE}")"
    fi
fi

# Mở rộng dấu ~ thành $HOME nếu người dùng nhập ~/
LOCAL_OUTPUT="${LOCAL_OUTPUT/#\~/$HOME}"
LOCAL_DIR="$(dirname "${LOCAL_OUTPUT}")"
mkdir -p "${LOCAL_DIR}"

# ── 3. Tải nội dung file qua SSH (hỗ trợ Remote Sudo Escalation) ─────────────
log_info "Bước 3/5: Tải nội dung file từ máy từ xa..."

TMP_PULL=$(mktemp /tmp/fetched-config-XXXXXX)
cleanup() {
    rm -f "${TMP_PULL}"
}
trap cleanup EXIT INT TERM

# Kiểm tra xem file có đọc trực tiếp được không hay cần sudo
FETCH_CMD='
    FILE="'"${REMOTE_FILE}"'"
    if [ -r "$FILE" ]; then
        base64 "$FILE"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n base64 "$FILE" 2>/dev/null || sudo base64 "$FILE"
    else
        exit 1
    fi
'

if ! ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "${FETCH_CMD}" 2>/dev/null | tr -d '\r\n ' | base64 -d > "${TMP_PULL}"; then
    log_warn "Tải trực tiếp thất bại, đang thử xác thực sudo trên máy từ xa..."
    # Nếu sudo cần password, chạy có terminal (-t) để hỏi password
    if ! ssh -t "${SSH_OPTS[@]}" "${SSH_TARGET}" "sudo -v" 2>/dev/null; then
        log_error "Không thể đọc file '${REMOTE_FILE}' trên máy từ xa (thiếu quyền hoặc sudo thất bại)."
        exit 1
    fi
    # Sau khi sudo session đã được cache trên máy từ xa, tải lại
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "sudo base64 '${REMOTE_FILE}'" | tr -d '\r\n ' | base64 -d > "${TMP_PULL}"
fi

if [[ ! -s "${TMP_PULL}" ]]; then
    log_error "File tải về rỗng hoặc không hợp lệ. Vui lòng kiểm tra lại đường dẫn: ${REMOTE_FILE}"
    exit 1
fi

log_success "Đã tải thành công nội dung file ($(wc -c < "${TMP_PULL}" | tr -d ' ') bytes)."

# ── 4. Xử lý Kubeconfig (Chuẩn hóa Endpoint & Context) ───────────────────────
if [[ "${IS_KUBECONFIG}" == "true" ]]; then
    log_info "Bước 4/5: Chuẩn hóa Kubeconfig cho máy client cục bộ..."

    # Xác định Server Endpoint thay thế 127.0.0.1
    TARGET_SERVER_IP="${SERVER_OVERRIDE:-}"
    if [[ -z "${TARGET_SERVER_IP}" ]]; then
        # Nếu REMOTE_HOST là IP hợp lệ hoặc hostname, dùng luôn
        TARGET_SERVER_IP="${REMOTE_HOST}"
        # Thử kiểm tra xem remote server có Tailscale IP không nếu kết nối qua Tailscale
        TS_REMOTE_IP=$(ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "tailscale ip -4 2>/dev/null || true" | tr -d '\r\n ')
        if [[ -n "${TS_REMOTE_IP}" && "${REMOTE_HOST}" == "${TS_REMOTE_IP}" ]]; then
            log_info "Phát hiện máy chủ kết nối qua Tailscale IP: ${BOLD}${TS_REMOTE_IP}${NC}"
            TARGET_SERVER_IP="${TS_REMOTE_IP}"
        fi
    fi

    log_info "Cập nhật endpoint Kubernetes API server: https://${TARGET_SERVER_IP}:6443"

    # Thay thế server loopback (127.0.0.1 hoặc localhost)
    sed -i -E "s|server: https://(127\.0\.0\.1\|localhost):|server: https://${TARGET_SERVER_IP}:|g" "${TMP_PULL}"

    # Đổi tên context nếu người dùng yêu cầu
    if [[ -n "${CONTEXT_NAME}" ]]; then
        log_info "Đổi tên context thành: ${BOLD}${CONTEXT_NAME}${NC}"
        sed -i -E "s|name: default|name: ${CONTEXT_NAME}|g" "${TMP_PULL}"
        sed -i -E "s|cluster: default|cluster: ${CONTEXT_NAME}|g" "${TMP_PULL}"
        sed -i -E "s|user: default|user: ${CONTEXT_NAME}|g" "${TMP_PULL}"
        sed -i -E "s|current-context: default|current-context: ${CONTEXT_NAME}|g" "${TMP_PULL}"
    fi
else
    log_info "Bước 4/5: File cấu hình thông thường (không phải Kubeconfig), bỏ qua bước rewrite endpoint."
fi

# ── 5. Lưu file vào máy cục bộ & Phân quyền bảo mật ──────────────────────────
log_info "Bước 5/5: Lưu file cấu hình vào ${LOCAL_OUTPUT}..."

# Xử lý backup nếu file đã tồn tại
if [[ -f "${LOCAL_OUTPUT}" ]]; then
    if [[ "${MERGE_MODE}" == "true" && "${IS_KUBECONFIG}" == "true" ]]; then
        log_info "Chế độ --merge: Đang tiến hành gộp vào Kubeconfig hiện tại..."
        MERGED_TMP=$(mktemp /tmp/merged-kubeconfig-XXXXXX)
        KUBECONFIG="${LOCAL_OUTPUT}:${TMP_PULL}" kubectl config view --flatten > "${MERGED_TMP}" 2>/dev/null || {
            log_warn "Không thể tự động merge bằng kubectl. Sẽ ghi đè kèm backup."
            cp "${LOCAL_OUTPUT}" "${LOCAL_OUTPUT}.bak_$(date +%Y%m%d_%H%M%S)"
        }
        if [[ -s "${MERGED_TMP}" ]]; then
            mv "${MERGED_TMP}" "${LOCAL_OUTPUT}"
            chmod 600 "${LOCAL_OUTPUT}"
            log_success "Đã gộp cấu hình thành công vào ${LOCAL_OUTPUT}!"
        fi
    else
        BACKUP_FILE="${LOCAL_OUTPUT}.bak_$(date +%Y%m%d_%H%M%S)"
        if [[ "${AUTO_CONFIRM}" != "true" ]]; then
            echo -e "${YELLOW}[!] File ${LOCAL_OUTPUT} đã tồn tại trên máy.${NC}"
            read -r -p "Bạn có muốn ghi đè (tự động tạo backup) không? [Y/n]: " confirm
            if [[ "${confirm:-}" =~ ^[Nn]$ ]]; then
                NEW_DEST="${LOCAL_OUTPUT}.new_$(date +%Y%m%d_%H%M%S)"
                mv "${TMP_PULL}" "${NEW_DEST}"
                chmod 600 "${NEW_DEST}"
                log_info "Đã lưu nội dung mới vào: ${NEW_DEST}"
                exit 0
            fi
        fi
        cp "${LOCAL_OUTPUT}" "${BACKUP_FILE}"
        log_info "Đã tạo bản sao lưu: ${BACKUP_FILE}"
        mv "${TMP_PULL}" "${LOCAL_OUTPUT}"
        chmod 600 "${LOCAL_OUTPUT}"
    fi
else
    mv "${TMP_PULL}" "${LOCAL_OUTPUT}"
    chmod 600 "${LOCAL_OUTPUT}"
fi

log_success "Đã lưu file cấu hình thành công tại: ${BOLD}${LOCAL_OUTPUT}${NC}"
log_info "Đã thiết lập phân quyền an toàn: chmod 600 ${LOCAL_OUTPUT}"

# ── Kiểm tra ngay với kubectl nếu là Kubeconfig ───────────────────────────────
if [[ "${IS_KUBECONFIG}" == "true" ]]; then
    echo ""
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    echo -e "${CYAN}  KIỂM TRA KẾT NỐI CỤM KUBERNETES TỪ MÁY CỤC BỘ                  ${NC}"
    echo -e "${CYAN}-----------------------------------------------------------------${NC}"
    
    if command -v kubectl &>/dev/null; then
        log_info "Đang thực thi: kubectl --kubeconfig=\"${LOCAL_OUTPUT}\" get nodes..."
        if kubectl --kubeconfig="${LOCAL_OUTPUT}" get nodes --request-timeout=8s; then
            echo ""
            log_success "XÁC NHẬN: Máy cục bộ đã kết nối và điều khiển cụm Kubernetes thành công!"
        else
            echo ""
            log_warn "Chưa thể kết nối tới Kubernetes API server qua ${TARGET_SERVER_IP}:6443."
            log_info "Gợi ý khắc phục:"
            echo "  1. Kiểm tra port 6443 trên máy chủ có được mở trong firewall (ufw/firewalld) không."
            echo "  2. Nếu dùng Tailscale hoặc IP riêng, hãy chắc chắn VPN đang kết nối."
            echo "  3. Kiểm tra TLS SAN: máy chủ cần được cấu hình --tls-san với IP ${TARGET_SERVER_IP}."
        fi
    else
        log_warn "Lệnh 'kubectl' chưa được cài đặt trên máy cục bộ."
        log_info "Bạn có thể cài đặt nhanh bằng script: ./scripts/k8s/install-kubectl.sh"
        log_info "Bạn có thể cài đặt nhanh bằng script: ./scripts/k8s/kubectl/install.sh"
    fi
fi

echo ""
log_success "Hoàn tất quy trình lấy file cấu hình!"

