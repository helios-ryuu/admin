#!/usr/bin/env bash
set -e

echo -e "\033[1;33m[LƯU Ý] Chạy script shell là tùy chọn phụ trợ (KHÔNG KHUYẾN KHÍCH).\033[0m"
echo -e "\033[1;33mKhuyến nghị thực hiện theo RUNBOOK.md phần 'Gỡ bỏ & Dọn dẹp Sạch sẽ'.\033[0m\n"

echo "[+] 1. Chạy script gỡ bỏ mặc định của K3s Server..."
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh
fi

echo "[+] 2. Xóa sạch dữ liệu, cấu hình và chứng chỉ còn sót lại..."
rm -rf /etc/rancher/k3s
rm -rf /var/lib/rancher/k3s
rm -rf /var/lib/kubelet
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni/
rm -rf /run/k3s
rm -rf /run/flannel

echo "[+] 3. Dọn dẹp card mạng ảo CNI..."
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

echo "[+] 4. Flush sạch bảng iptables..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

echo "[✓] Đã dọn dẹp sạch Master Node!"
