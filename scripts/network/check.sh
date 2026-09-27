#!/usr/bin/env bash
# =============================================================================
# check-network.sh
# check.sh (chẩn đoán mạng)
# Hệ thống chẩn đoán & đánh giá mạng DevSecOps chuyên sâu (L3 - L7)
# (ISP info, MTU check, Latency/Loss, TLS Handshake, Routing MTR, Tailscale DERP)
#
# Usage: ./check-network.sh
# Usage: ./check.sh
# =============================================================================

set -uo pipefail

# Bảng màu ANSI
readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly CYAN='\033[1;36m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[1;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

has() { command -v "$1" &>/dev/null; }

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN} 🌐 HỆ THỐNG CHẨN ĐOÁN & ĐÁNH GIÁ MẠNG DEVSECOPS CHUYÊN SÂU (L3 - L7) ${NC}"
echo -e "${GREEN}======================================================================${NC}\n"

# -------------------------------------------------------------
# [1/6] THÔNG TIN HẠ TẦNG ISP, PUBLIC IP & ASN PEERING
# -------------------------------------------------------------
echo -e "${CYAN}[1/6] 🕵️ PHÂN TÍCH HẠ TẦNG ISP, PUBLIC IP & ASN METADATA...${NC}"
IP_INFO=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
PUBLIC_IP=$(echo "$IP_INFO" | grep -oP '"ip": "\K[^"]+' || true)
ISP_ORG=$(echo "$IP_INFO" | grep -oP '"org": "\K[^"]+' || true)
CITY=$(echo "$IP_INFO" | grep -oP '"city": "\K[^"]+' || true)
REGION=$(echo "$IP_INFO" | grep -oP '"region": "\K[^"]+' || true)
COUNTRY=$(echo "$IP_INFO" | grep -oP '"country": "\K[^"]+' || true)

echo -e "  - ${YELLOW}Public IPv4   :${NC} ${BOLD}${PUBLIC_IP:-"Không lấy được IP"}${NC}"
echo -e "  - ${YELLOW}ISP & ASN Info:${NC} ${BOLD}${ISP_ORG:-"Unknown"}${NC}"
echo -e "  - ${YELLOW}Vị trí địa lý :${NC} ${CITY:-"N/A"}, ${REGION:-"N/A"}, ${COUNTRY:-"N/A"}"

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n 1)
GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
LOCAL_IP=""
if [[ -n "${IFACE}" ]]; then
    LOCAL_IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || true)
fi

echo -e "  - ${YELLOW}Giao diện mạng:${NC} ${IFACE:-"N/A"} (IP Nội bộ: ${LOCAL_IP:-"N/A"})"
echo -e "  - ${YELLOW}Default Gateway:${NC} ${GATEWAY_IP:-"N/A"}"

if [[ -n "${PUBLIC_IP}" ]] && has traceroute; then
    echo -e "\n  ${MAGENTA}>> Phát hiện CGNAT (Traceroute 3 hop đầu):${NC}"
    traceroute -n -m 3 -q 1 "$PUBLIC_IP" 2>/dev/null || true
fi

if [[ -n "${IFACE}" ]] && has tc; then
    echo -e "\n  ${MAGENTA}>> Thuật toán hàng đợi kernel (Queueing Discipline):${NC}"
    tc qdisc show dev "$IFACE" 2>/dev/null || true
fi

# -------------------------------------------------------------
# [2/6] KIỂM TRA MTU & PHÂN MẢNH GÓI TIN (PACKET FRAGMENTATION)
# -------------------------------------------------------------
echo -e "\n${CYAN}[2/6] 📦 KIỂM TRA PATH MTU & NGUY CƠ PHÂN MẢNH GÓI TIN...${NC}"
echo -e "  ${YELLOW}Đang test gói ICMP DF (Don't Fragment) tới Cloudflare (1.1.1.1):${NC}"
for size in 1472 1464 1452 1420 1200; do
    if ping -M do -s $size -c 2 -W 1 1.1.1.1 >/dev/null 2>&1; then
        echo -e "  - Payload ${BOLD}${size} bytes${NC} (MTU $((size + 28))): ${GREEN}PASSED (Không bị phân mảnh)${NC}"
    else
        echo -e "  - Payload ${BOLD}${size} bytes${NC} (MTU $((size + 28))): ${RED}FAILED / FRAGMENTED${NC}"
    fi
done

# -------------------------------------------------------------
# [3/6] LAYER 3: MA TRẬN ĐỘ TRỄ & PACKET LOSS
# -------------------------------------------------------------
echo -e "\n${CYAN}[3/6] 📡 MA TRẬN ĐỘ TRỄ VÀ PACKET LOSS (ICMP Layer 3)...${NC}"

run_latency_test() {
    local target="$1"
    if has fping; then
        sudo fping -c 5 -q "$target" 2>&1 || true
    else
        ping -c 3 -W 1 "$target" 2>/dev/null | tail -n 2 || echo "  [!] Không thể ping $target"
    fi
}

echo -e "\n${MAGENTA}☁️ [GLOBAL CLOUD & CDN PROVIDERS]${NC}"
for target in cloudflare.com aws.amazon.com google.com github.com microsoft.com; do
    echo -n "  Testing $target: "
    run_latency_test "$target"
done

echo -e "\n${MAGENTA}🌐 [POPULAR SERVICES & DEVELOPER APIS]${NC}"
for target in wikipedia.org api.github.com docker.com debian.org fedoraproject.org; do
    echo -n "  Testing $target: "
    run_latency_test "$target"
done

echo -e "\n${MAGENTA}🛡️ [ANYCAST ROOT DNS]${NC}"
for target in 1.1.1.1 8.8.8.8 9.9.9.9; do
    echo -n "  Testing $target: "
    run_latency_test "$target"
done

# -------------------------------------------------------------
# [4/6] LAYER 7: HIỆU NĂNG TẢI TRANG, DNS & BẮT TAY TLS (CURL)
# -------------------------------------------------------------
echo -e "\n${CYAN}[4/6] ⏱️ ĐO TỐC ĐỘ BẮT TAY ỨNG DỤNG CHI TIẾT (TLS Layer 7)...${NC}"
TARGET_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com"
    "https://github.com"
    "https://aws.amazon.com"
    "https://www.wikipedia.org"
)

for url in "${TARGET_URLS[@]}"; do
    echo -e "\n${YELLOW}🎯 Target: $url${NC}"
    curl -w "  - DNS Lookup   : %{time_namelookup} s\n  - TCP Connect  : %{time_connect} s\n  - TLS Handshake: %{time_appconnect} s\n  - TTFB         : %{time_starttransfer} s\n  - Total Time   : %{time_total} s\n  - HTTP Code    : %{http_code}\n" \
         -o /dev/null -s --max-time 10 "$url" || echo "  [!] Timeout hoặc lỗi kết nối."
done

# -------------------------------------------------------------
# [5/6] LAYER 4: TRUY VẾT ĐỊNH TUYẾN QUỐC TẾ (TCP MTR PORT 443)
# -------------------------------------------------------------
echo -e "\n${CYAN}[5/6] 🗺️ TRUY VẾT BGP ROUTING QUỐC TẾ (Port 443)...${NC}"

trace_route_target() {
    local target="$1"
    local desc="$2"
    echo -e "\n${YELLOW}>> ${desc} (${target}):${NC}"
    if has mtr; then
        sudo mtr -T -P 443 -r -w -c 5 "$target" 2>/dev/null || true
    elif has traceroute; then
        traceroute -p 443 -T "$target" 2>/dev/null || true
    else
        echo "  [!] Cần cài đặt mtr hoặc traceroute (sudo dnf install mtr traceroute)."
    fi
}

trace_route_target "1.1.1.1" "Cloudflare Anycast DNS"
trace_route_target "8.8.8.8" "Google Public DNS"
trace_route_target "github.com" "GitHub Web / Microsoft CDN"

# -------------------------------------------------------------
# [6/6] TAILSCALE DERP RELAYS & NAT TRAVERSAL
# -------------------------------------------------------------
echo -e "\n${CYAN}[6/6] 🖧 KIỂM TRA NAT TRAVERSAL, DERP RELAYS (TAILSCALE)...${NC}"
if has tailscale; then
    tailscale netcheck || true
else
    echo -e "${YELLOW}Tailscale không được cài đặt hoặc chưa khởi chạy.${NC}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN} ✅ HOÀN TẤT CHẨN ĐOÁN MẠNG!${NC}"
echo -e "${GREEN}======================================================================${NC}\n"
