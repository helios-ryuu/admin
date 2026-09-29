#!/usr/bin/env bash

set -eo pipefail

# ==========================================
# 0. KIỂM TRA QUYỀN ROOT
# ==========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "[CRITICAL FAIL] Vui lòng chạy script với quyền sudo/root."
    exit 1
fi

echo -e "\033[1;33m[LƯU Ý] Chạy script shell là tùy chọn phụ trợ (KHÔNG KHUYẾN KHÍCH).\033[0m"
echo -e "\033[1;33mKhuyến nghị thực hiện theo RUNBOOK.md với file cấu hình chuẩn (/etc/rancher/k3s/config.yaml).\033[0m\n"

# ==========================================
# 1. PARSE THAM SỐ ĐẦU VÀO
# ==========================================
NODE_NAME=""
AUTO_APPROVE=false

for arg in "$@"; do
    case $arg in
        --nodename=*)
            NODE_NAME="${arg#*=}"
            ;;
        -y)
            AUTO_APPROVE=true
            ;;
        *)
            # Nếu chưa có NODE_NAME và tham số không bắt đầu bằng dấu '-'
            if [ -z "$NODE_NAME" ] && [[ "$arg" != -* ]]; then
                NODE_NAME="$arg"
            fi
            ;;
    esac
done

# Kiểm tra xem tên Node đã được truyền vào chưa
if [ -z "$NODE_NAME" ]; then
    echo "[CRITICAL FAIL] Thiếu tên Node! Vui lòng truyền tên Node theo cú pháp:"
    echo "  Cách 1: $0 <tên-node> [-y]"
    echo "  Cách 2: $0 --nodename=<tên-node> [-y]"
    exit 1
fi

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)

# ==========================================
# 2. HAM KIỂM TRA PRE-FLIGHT CHECKS
# ==========================================
run_preflight_checks() {
    echo "=== BẮT ĐẦU KIỂM TRA ĐIỀU KIỆN TIỀN TIÊU (STRICT PRE-FLIGHT CHECKS) ==="

    # 2.1. Kiểm tra Tailscale IP
    if [ -z "$TAILSCALE_IP" ]; then
        echo "[CRITICAL FAIL] Không tìm thấy IP Tailscale. Hãy đảm bảo Tailscale đang chạy!"
        exit 1
    fi
    echo "[OK] Tailscale IP: ${TAILSCALE_IP}"

    # 2.2. Kiểm tra Swap Off
    SWAP_ACTIVE=$(swapon --show --noheadings 2>/dev/null || true)
    if [ -n "$SWAP_ACTIVE" ]; then
        echo "[CRITICAL FAIL] Swap vẫn đang bật! Hãy tắt Swap (sudo swapoff -a) và xoá entry swap trong /etc/fstab trước khi cài."
        exit 1
    fi
    echo "[OK] Swap đã tắt hoàn toàn."

    # 2.3. Kiểm tra UFW Status (Bắt buộc phải ACTIVE)
    UFW_STATUS=$(ufw status 2>/dev/null || true)

    if ! echo "$UFW_STATUS" | grep -qF "Status: active"; then
        echo "[CRITICAL FAIL] UFW chưa được kích hoạt (Status: inactive)! Yêu cầu UFW phải active trước khi cài đặt."
        exit 1
    fi
    echo "[OK] UFW đang hoạt động (Status: active)."

    # 2.4. Kiểm tra UFW Rules bắt buộc cho Pod CIDR (10.42.0.0/16) và Service CIDR (10.43.0.0/16)
    if ! echo "$UFW_STATUS" | grep -qF "10.42.0.0/16"; then
        echo "[CRITICAL FAIL] Thiếu rule UFW cho dải Pod CIDR (10.42.0.0/16)! Hãy chạy: ufw allow from 10.42.0.0/16"
        exit 1
    fi

    if ! echo "$UFW_STATUS" | grep -qF "10.43.0.0/16"; then
        echo "[CRITICAL FAIL] Thiếu rule UFW cho dải Service CIDR (10.43.0.0/16)! Hãy chạy: ufw allow from 10.43.0.0/16"
        exit 1
    fi
    echo "[OK] Đã xác nhận đầy đủ UFW Rules cho 10.42.0.0/16 và 10.43.0.0/16."

    # 2.5. Kiểm tra UFW Rule cho Tailscale UDP port 41641
    if ! echo "$UFW_STATUS" | grep -qF "41641/udp"; then
        echo "[CRITICAL FAIL] Thiếu rule UFW cho Tailscale (41641/udp)! Hãy chạy: ufw allow 41641/udp"
        exit 1
    fi
    echo "[OK] Đã xác nhận UFW Rule cho Tailscale (41641/udp)."

    # 2.6. Kiểm tra UFW Rule tin cậy toàn bộ interface tailscale0
    if ! echo "$UFW_STATUS" | grep -qF "on tailscale0"; then
        echo "[CRITICAL FAIL] Thiếu rule UFW cho phép toàn bộ traffic trên tailscale0! Hãy chạy: ufw allow in on tailscale0"
        exit 1
    fi
    echo "[OK] Đã xác nhận UFW Rule cho phép traffic trên tailscale0."
    echo "=== TẤT CẢ CHECKS ĐÃ THÀNH CÔNG 100% ==="
}

# ==========================================
# 3. LUỒNG XỬ LÝ CHÍNH (MAIN EXECUTION)
# ==========================================

# Thực hiện check lần 1
run_preflight_checks

if [ "$AUTO_APPROVE" = false ]; then
    echo ""
    echo "================================================================="
    echo "[DRY-RUN MODE] Kiểm tra thành công! Lệnh cài đặt K3s dự kiến sẽ chạy:"
    echo "================================================================="
    echo "curl -sfL https://get.k3s.io | sh -s - \\"
    echo "    --node-name \"${NODE_NAME}\" \\"
    echo "    --write-kubeconfig-mode 644 \\"
    echo "    --bind-address \"${TAILSCALE_IP}\" \\"
    echo "    --advertise-address \"${TAILSCALE_IP}\" \\"
    echo "    --tls-san \"${TAILSCALE_IP}\" \\"
    echo "    --tls-san=127.0.0.1 \\"
    echo "    --tls-san=localhost \\"
    echo "    --node-ip \"${TAILSCALE_IP}\" \\"
    echo "    --node-external-ip \"${TAILSCALE_IP}\" \\"
    echo "    --flannel-iface=tailscale0 \\"
    echo "    --flannel-backend=vxlan \\"
    echo "    --disable traefik \\"
    echo "    --secrets-encryption=true \\"
    echo "    --debug"
    echo "================================================================="
    echo "[GỢI Ý] Để thực thi cài đặt thực sự, vui lòng thêm cờ -y vào lệnh:"
    echo "  Cách 1: sudo $0 ${NODE_NAME} -y"
    echo "  Cách 2: sudo $0 --nodename=${NODE_NAME} -y"
    exit 0
fi

# Chế độ EXECUTION MODE (khi có cờ -y)
echo ""
echo "[EXECUTION MODE] Phát hiện cờ -y. Tiến hành kiểm tra lại lần 2 trước khi thực thi..."
run_preflight_checks

echo ""
echo "=== THỰC THI LỆNH CÀI ĐẶT K3S MASTER ==="
curl -sfL https://get.k3s.io | sh -s - \
    --node-name "${NODE_NAME}" \
    --write-kubeconfig-mode 644 \
    --bind-address "${TAILSCALE_IP}" \
    --advertise-address "${TAILSCALE_IP}" \
    --tls-san "${TAILSCALE_IP}" \
    --tls-san=127.0.0.1 \
    --tls-san=localhost \
    --node-ip "${TAILSCALE_IP}" \
    --node-external-ip "${TAILSCALE_IP}" \
    --flannel-iface=tailscale0 \
    --flannel-backend=vxlan \
    --disable traefik \
    --secrets-encryption=true \
    --debug


echo ""
echo "=== ĐANG CHỜ K3S MASTER KHỞI ĐỘNG VÀ TẠO TOKEN ==="
TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
TIMEOUT=60
ELAPSED=0

while [ ! -s "$TOKEN_FILE" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "[CRITICAL FAIL] Quá thời gian chờ ($TIMEOUT s). Không tìm thấy file node-token!"
        exit 1
    fi
    echo -n "."
done
echo ""

echo "================================================================="
echo "[+] CÀI ĐẶT K3S MASTER THÀNH CÔNG!"
echo "[+] Node Token để kết nối Worker:"
cat "$TOKEN_FILE"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SECRETS_DIR="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)/secrets"
TARGET_SECRETS_DIR="${SECRETS_DIR:-${REPO_SECRETS_DIR}}"

if [ -d "$TARGET_SECRETS_DIR" ]; then
    cp "$TOKEN_FILE" "${TARGET_SECRETS_DIR}/k3s-node-token" 2>/dev/null || true
    chmod 600 "${TARGET_SECRETS_DIR}/k3s-node-token" 2>/dev/null || true
    echo "[+] Đã tự động sao lưu token vào: ${TARGET_SECRETS_DIR}/k3s-node-token"
fi
echo "================================================================="