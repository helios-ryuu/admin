#!/usr/bin/env bash
# =============================================================================
# audit.sh — Universal Complete Machine Audit for Linux
# Fully compatible with Debian, Ubuntu, Fedora, RHEL/CentOS/Rocky/Alma, and Arch.
#
# Non-destructive: Read-only inspection & reporting.
#
# Usage:
#   ./audit.sh [OPTIONS]
#
# Options:
#   -q, --quick           Fast triage snapshot (< 5s), skips deep disk & log scans
#   -o, --output FILE     Write report to FILE (ANSI colors stripped) and mirror to terminal
#   -e, --export-dir DIR  Export structured inventory files (packages, git, secrets, etc.)
#   --cleanup-only        Run only junk, cache, leftover & reclaimable space audit
#   --security-only       Run only security posture, accounts, SSH, firewall, MAC & secrets
#   --no-color            Disable ANSI color output
#   -V, --version         Show script version
#   -h, --help            Show this help message
# =============================================================================

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"
readonly AUDIT_START_EPOCH="$(date +%s)"
readonly AUDIT_START_ISO="$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

# CLI Options
QUICK_MODE=0
CLEANUP_ONLY=0
SECURITY_ONLY=0
NO_COLOR=0
OUTPUT_FILE=""
EXPORT_DIR=""

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Universal Complete Machine Audit for Linux (Debian, Ubuntu, Fedora, RHEL, Arch).

Options:
  -q, --quick           Fast triage mode (< 5s), skips slow disk scans & deep queries
  -o, --output FILE     Write full report to FILE (clean text) while printing to terminal
  -e, --export-dir DIR  Export structured inventory files (packages, git, secrets, etc.)
      --cleanup-only    Run only junk, cache, leftover and reclaimable space analysis
      --security-only   Run only security posture, accounts, SSH, firewall, MAC and secrets
      --no-color        Disable ANSI terminal colors
  -V, --version         Show script version
  -h, --help            Show this help message

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME -q
  ./$SCRIPT_NAME -o /tmp/system-audit.log
  ./$SCRIPT_NAME -e /tmp/audit-exports
  sudo ./$SCRIPT_NAME --security-only
EOF
}

# Parse Command Line Arguments
while (($# > 0)); do
    case "$1" in
        -q|--quick)
            QUICK_MODE=1
            shift
            ;;
        -o|--output)
            if (($# < 2)); then
                echo "Error: --output requires a file path." >&2
                exit 2
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -e|--export-dir)
            if (($# < 2)); then
                echo "Error: --export-dir requires a directory path." >&2
                exit 2
            fi
            EXPORT_DIR="$2"
            shift 2
            ;;
        --cleanup-only)
            CLEANUP_ONLY=1
            shift
            ;;
        --security-only)
            SECURITY_ONLY=1
            shift
            ;;
        --no-color)
            NO_COLOR=1
            shift
            ;;
        -V|--version)
            echo "$SCRIPT_NAME $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Auto-detect TTY & Color Support
if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" && "$NO_COLOR" == "1" ]]; then
    NO_COLOR=1
fi

if ((NO_COLOR == 0)); then
    C_TITLE=$'\033[1;44;37m'
    C_HEADER=$'\033[1;36m'
    C_SEC=$'\033[1;33m'
    C_SUB=$'\033[1;35m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;31m'
    C_INFO=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_TITLE=""
    C_HEADER=""
    C_SEC=""
    C_SUB=""
    C_OK=""
    C_WARN=""
    C_INFO=""
    C_BOLD=""
    C_RESET=""
fi

# Utility Functions
has() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# PRIVILEGE RESOLUTION & TARGET USER DETECTION
# Resolves the true desktop user and home directory so running under sudo does
# not distort user-level audit results (cache, trash, git repos, configs, keys).
# =============================================================================
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
    TARGET_UID="${SUDO_UID:-$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)}"
    TARGET_GID="${SUDO_GID:-$(id -g "$TARGET_USER" 2>/dev/null || echo 1000)}"
else
    detected_user="$(logname 2>/dev/null || who -m 2>/dev/null | awk '{print $1}')"
    if [[ -n "$detected_user" && "$detected_user" != "root" ]] && id "$detected_user" &>/dev/null; then
        TARGET_USER="$detected_user"
    else
        primary_user="$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ {print $1; exit}' /etc/passwd 2>/dev/null || true)"
        TARGET_USER="${primary_user:-$(id -un)}"
    fi
    TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || id -u)"
    TARGET_GID="$(id -g "$TARGET_USER" 2>/dev/null || id -g)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-${HOME}}"

# =============================================================================
# REQUIRE ROOT / SUDO FROM THE START
# Prompts for sudo upfront before output redirection so credentials are ready
# and prompts do not contaminate the log file.
# =============================================================================
HAS_SUDO=0
SUDO_KEEPALIVE_PID=""

cleanup_audit() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    # If running with root permissions, ensure generated reports/exports remain owned by the user
    if ((EUID == 0)) && [[ -n "${TARGET_USER:-}" && "$TARGET_USER" != "root" ]]; then
        [[ -n "${OUTPUT_FILE:-}" && -f "$OUTPUT_FILE" ]] && chown "$TARGET_USER:$TARGET_GID" "$OUTPUT_FILE" 2>/dev/null || true
        [[ -n "${EXPORT_DIR:-}" && -d "$EXPORT_DIR" ]] && chown -R "$TARGET_USER:$TARGET_GID" "$EXPORT_DIR" 2>/dev/null || true
    fi
}
trap cleanup_audit EXIT INT TERM

if ((EUID == 0)); then
    HAS_SUDO=1
elif has sudo; then
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=1
    elif [[ -t 0 ]]; then
        printf '%s\n' "=========================================================================="
        printf '%s\n' "[*] Machine Audit requires sudo privileges for full hardware (SMART/DMI),"
        printf '%s\n' "    storage discrepancy, systemd logs, and firewall inspection."
        printf '%s\n' "=========================================================================="
        if sudo -v; then
            HAS_SUDO=1
        else
            printf '%s\n' "[!] Sudo authorization was not granted. Proceeding with standard user checks..." >&2
        fi
    fi

    if ((HAS_SUDO == 1)); then
        # Maintain sudo credentials alive in the background during audit
        ( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
        SUDO_KEEPALIVE_PID=$!
    fi
fi

# Set up Output File Mirroring if requested (AFTER sudo prompt)
if [[ -n "$OUTPUT_FILE" ]]; then
    output_parent="$(dirname -- "$OUTPUT_FILE")"
    mkdir -p -- "$output_parent" 2>/dev/null || {
        echo "Error: Cannot create output directory: $output_parent" >&2
        exit 1
    }
    # Mirror stdout and stderr to terminal and strip ANSI codes for file
    exec > >(tee >(sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g' > "$OUTPUT_FILE")) 2>&1
fi

# Set up Export Directory if requested
if [[ -n "$EXPORT_DIR" ]]; then
    mkdir -p -- "$EXPORT_DIR" 2>/dev/null || {
        echo "Error: Cannot create export directory: $EXPORT_DIR" >&2
        exit 1
    }
fi

log_title() {
    printf '\n%b=== %s ===%b\n' "$C_TITLE" "$1" "$C_RESET"
}

log_section() {
    printf '\n%b[%s] %s%b\n' "$C_HEADER" "$1" "$2" "$C_RESET"
}

log_sub() {
    printf '\n%b--- %s ---%b\n' "$C_SEC" "$1" "$C_RESET"
}

log_ok() {
    printf '%b[✓]%b %s\n' "$C_OK" "$C_RESET" "$*"
}

log_info() {
    printf '%b[*]%b %s\n' "$C_INFO" "$C_RESET" "$*"
}

log_warn() {
    printf '%b[!]%b %s\n' "$C_WARN" "$C_RESET" "$*"
}

log_rule() {
    printf '%s\n' "--------------------------------------------------------------------------"
}

safe_cat() {
    local file="$1"
    if [[ -r "$file" ]]; then
        cat -- "$file"
    else
        echo "Cannot read: $file"
    fi
}

run_as_root() {
    if ((EUID == 0)); then
        "$@"
    elif ((HAS_SUDO == 1)); then
        sudo "$@"
    else
        "$@"
    fi
}

run_with_timeout() {
    local seconds="$1"
    shift
    if has timeout; then
        timeout "${seconds}s" "$@"
    else
        "$@"
    fi
}

format_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" '
        function human(x) {
            split("B KiB MiB GiB TiB PiB", u, " ")
            i = 1
            while (x >= 1024 && i < 6) {
                x /= 1024
                i++
            }
            return sprintf("%.2f %s", x, u[i])
        }
        BEGIN { print human(b + 0) }
    '
}

# Distro Detection
DISTRO_ID="unknown"
DISTRO_LIKE=""
DISTRO_NAME="Linux"
DISTRO_VERSION=""
DISTRO_FAMILY="unknown"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-$NAME}"
    DISTRO_VERSION="${VERSION_ID:-}"
fi

case "$DISTRO_ID" in
    debian|ubuntu|linuxmint|pop|elementary|kali|raspbian)
        DISTRO_FAMILY="debian"
        ;;
    fedora|rhel|centos|rocky|almalinux|ol|amzn)
        DISTRO_FAMILY="redhat"
        ;;
    arch|manjaro|endeavouros|garuda)
        DISTRO_FAMILY="arch"
        ;;
    opensuse*|sles)
        DISTRO_FAMILY="suse"
        ;;
    *)
        if [[ "$DISTRO_LIKE" =~ debian|ubuntu ]]; then
            DISTRO_FAMILY="debian"
        elif [[ "$DISTRO_LIKE" =~ rhel|fedora|centos ]]; then
            DISTRO_FAMILY="redhat"
        elif [[ "$DISTRO_LIKE" =~ arch ]]; then
            DISTRO_FAMILY="arch"
        elif [[ "$DISTRO_LIKE" =~ suse ]]; then
            DISTRO_FAMILY="suse"
        else
            DISTRO_FAMILY="generic"
        fi
        ;;
esac

# Desktop Environment & Session Detection (Fedora, Debian, Ubuntu, etc.)
DESKTOP_ENV="Headless / Server (No GUI)"
SESSION_TYPE="none"
DISPLAY_MGR="none"

if [[ -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
    DESKTOP_ENV="$XDG_CURRENT_DESKTOP"
elif [[ -n "${DESKTOP_SESSION:-}" ]]; then
    DESKTOP_ENV="$DESKTOP_SESSION"
elif pgrep -x "gnome-shell" &>/dev/null; then
    DESKTOP_ENV="GNOME"
elif pgrep -x "plasmashell" &>/dev/null; then
    DESKTOP_ENV="KDE Plasma"
elif pgrep -x "xfce4-session" &>/dev/null; then
    DESKTOP_ENV="XFCE"
elif pgrep -x "cinnamon-session" &>/dev/null; then
    DESKTOP_ENV="Cinnamon"
elif pgrep -x "mate-session" &>/dev/null; then
    DESKTOP_ENV="MATE"
fi

if [[ -n "${XDG_SESSION_TYPE:-}" ]]; then
    SESSION_TYPE="$XDG_SESSION_TYPE"
elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    SESSION_TYPE="wayland"
elif [[ -n "${DISPLAY:-}" ]]; then
    SESSION_TYPE="x11"
fi

for mgr in gdm gdm3 sddm lightdm lxdm slim; do
    if pgrep -x "$mgr" &>/dev/null || systemctl is-active --quiet "$mgr" 2>/dev/null; then
        DISPLAY_MGR="$mgr"
        break
    fi
done

# Root & Sudo Detection
# Track Estimated Reclaimable Space
TOTAL_RECLAIMABLE_KB=0
add_reclaim() {
    local kb="${1:-0}"
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
        TOTAL_RECLAIMABLE_KB=$((TOTAL_RECLAIMABLE_KB + kb))
    fi
}

# Header Display
log_title "UNIVERSAL LINUX MACHINE AUDIT: $(hostname 2>/dev/null | tr '[:lower:]' '[:upper:]')"
printf 'Version        : %s\n' "$SCRIPT_VERSION"
printf 'Timestamp      : %s\n' "$AUDIT_START_ISO"
printf 'Audited User   : %s (UID %s) [Home: %s]\n' "$TARGET_USER" "$TARGET_UID" "$TARGET_HOME"
printf 'Distribution   : %s (%s family)\n' "$DISTRO_NAME" "$DISTRO_FAMILY"
printf 'Desktop Session: %s [%s] (DM: %s)\n' "$DESKTOP_ENV" "$SESSION_TYPE" "$DISPLAY_MGR"
printf 'Privilege Mode : %s\n' "$([[ $HAS_SUDO -eq 1 ]] && echo "Elevated (Root/Sudo active)" || echo "Standard User (Non-elevated)")"
printf 'Mode           : %s\n' "$([[ $QUICK_MODE -eq 1 ]] && echo "Quick Triage" || ([[ $CLEANUP_ONLY -eq 1 ]] && echo "Cleanup & Junk Only" || ([[ $SECURITY_ONLY -eq 1 ]] && echo "Security Only" || echo "Complete Machine Audit")))"
[[ -n "$OUTPUT_FILE" ]] && printf 'Output Log     : %s\n' "$OUTPUT_FILE"
[[ -n "$EXPORT_DIR" ]] && printf 'Export Dir     : %s\n' "$EXPORT_DIR"
log_rule

# =============================================================================
# MODULE 1: SYSTEM IDENTITY, OS, KERNEL & HARDWARE TOPOLOGY
# =============================================================================
audit_system_hardware() {
    log_section "1" "SYSTEM IDENTITY, KERNEL, HARDWARE & SENSORS"

    log_sub "Identity & Kernel"
    printf 'Hostname       : %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'FQDN           : %s\n' "$(hostname -f 2>/dev/null || echo unavailable)"
    printf 'Kernel         : %s\n' "$(uname -srmo 2>/dev/null || uname -a)"
    printf 'Architecture   : %s\n' "$(uname -m 2>/dev/null || echo unknown)"
    printf 'Machine ID     : %s\n' "$(cat /etc/machine-id 2>/dev/null || echo unavailable)"
    printf 'Boot Time      : %s\n' "$(uptime -s 2>/dev/null || who -b 2>/dev/null | sed 's/^[[:space:]]*//')"
    printf 'Uptime         : %s\n' "$(uptime -p 2>/dev/null || uptime)"
    printf 'Current Time   : %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'Timezone       : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
    printf 'Init System    : %s\n' "$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
    printf 'Virtualization : %s\n' "$(systemd-detect-virt 2>/dev/null || echo none)"
    printf 'Desktop Session: %s [%s] (DM: %s)\n' "$DESKTOP_ENV" "$SESSION_TYPE" "$DISPLAY_MGR"

    if [[ -f /proc/sys/kernel/tainted ]]; then
        local tainted_val
        tainted_val=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)
        printf 'Kernel Tainted : %s %s\n' "$tainted_val" "$([[ "$tainted_val" != "0" ]] && echo "(Tainted kernel, e.g. proprietary driver)" || echo "(Clean)")"
    fi

    if has hostnamectl; then
        log_sub "Hostnamectl Snapshot"
        hostnamectl 2>/dev/null | grep -E \
            'Static hostname|Pretty hostname|Operating System|Kernel|Architecture|Hardware Vendor|Hardware Model|Firmware Version|Virtualization' \
            || true
    fi

    log_sub "CPU Topology & Utilization"
    if has lscpu; then
        lscpu | grep -E \
            '^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|CPU max MHz|CPU min MHz|Virtualization|Hypervisor vendor|L3 cache):' \
            || lscpu | head -n 20
    fi
    printf 'Load Average   : %s\n' "$(cat /proc/loadavg 2>/dev/null || uptime)"
    printf 'Online Cores   : %s\n' "$(nproc 2>/dev/null || echo unknown)"
    
    ps -eo pcpu= 2>/dev/null | awk '
        { total += $1 }
        END { printf "Cumulative CPU Usage: %.1f%%\n", total }
    '

    log_sub "Memory & Swap"
    free -h 2>/dev/null || safe_cat /proc/meminfo
    grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|HugePages_Total|Hugepagesize):' /proc/meminfo 2>/dev/null || true

    if has swapon; then
        log_sub "Active Swap Devices"
        swapon --show 2>/dev/null || echo "No active swap devices."
    fi

    log_sub "Motherboard & Physical DIMMs (DMI)"
    if has dmidecode && ((HAS_SUDO == 1)); then
        run_as_root dmidecode -t system -t baseboard 2>/dev/null | awk '
            /^(System Information|Base Board Information)$/ { print; next }
            /^[[:space:]]+(Manufacturer|Product Name|Version|Serial Number):/ {
                if ($0 !~ /Not Specified|To Be Filled|Default string/) print
            }
        ' | head -n 30 || true
    else
        echo "DMI details require dmidecode and root/sudo permissions."
    fi

    log_sub "PCI & GPU Accelerators"
    if has nvidia-smi; then
        nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu \
            --format=csv,noheader 2>/dev/null || nvidia-smi
    elif has lspci; then
        lspci -nnk 2>/dev/null | grep -iEA3 'vga|3d|display' || true
    else
        echo "lspci / nvidia-smi not found."
    fi

    log_sub "Battery & Power Supply"
    local bat_found=0
    for bat in /sys/class/power_supply/BAT*; do
        [[ -d "$bat" ]] || continue
        bat_found=1
        printf 'Battery [%s]:\n' "$(basename "$bat")"
        for field in status capacity capacity_level cycle_count manufacturer model_name; do
            [[ -r "$bat/$field" ]] && printf '  %-14s %s\n' "$field:" "$(cat "$bat/$field")"
        done
    done
    ((bat_found == 0)) && echo "No battery detected (Desktop, VM, or Server)."

    log_sub "Temperatures & Thermal Sensors"
    if has sensors; then
        sensors 2>/dev/null || true
    else
        local tz_found=0
        for zone in /sys/class/thermal/thermal_zone*; do
            [[ -d "$zone" && -r "$zone/temp" ]] || continue
            tz_found=1
            local z_type z_temp
            z_type="$(cat "$zone/type" 2>/dev/null || basename "$zone")"
            z_temp="$(cat "$zone/temp" 2>/dev/null || echo 0)"
            awk -v t="$z_type" -v v="$z_temp" 'BEGIN { printf "%-24s %.1f°C\n", t ":", v / 1000 }'
        done
        ((tz_found == 0)) && echo "No thermal zones detected."
    fi
}

# =============================================================================
# MODULE 2: STORAGE, FILESYSTEMS, SMART & DUAL-BOOT INTEGRITY
# =============================================================================
audit_storage() {
    log_section "2" "STORAGE, FILESYSTEMS, SMART & DUAL-BOOT CHECKS"

    log_sub "Block Devices Structure"
    if has lsblk; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,FSUSE%,MOUNTPOINTS 2>/dev/null || lsblk
    else
        safe_cat /proc/partitions
    fi

    log_sub "Mounted Filesystems & Disk Usage"
    df -hT -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null || df -h

    log_sub "Inode Usage"
    df -hi -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null || true

    log_sub "Filesystem Capacity Warnings (>=80% or >=90%)"
    df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null | awk '
        NR > 1 {
            use = $5
            gsub("%", "", use)
            if (use >= 90)
                printf "[CRITICAL] %s is at %s%% capacity on %s\n", $1, use, $6
            else if (use >= 80)
                printf "[WARN] %s is at %s%% capacity on %s\n", $1, use, $6
        }
    '

    log_sub "Dual-Boot & EFI Protection Check"
    if has lsblk; then
        local ntfs_count
        ntfs_count=$(lsblk -no FSTYPE 2>/dev/null | grep -c "ntfs" || true)
        if [[ "$ntfs_count" -gt 0 ]]; then
            log_warn "Detected DUAL-BOOT system with Windows ($ntfs_count NTFS partitions found)!"
            lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | grep -E 'ntfs|vfat|/boot' || true
            echo "  -> Note: EFI partition (/boot/efi) and NTFS drives must never be formatted during OS changes."
        else
            log_ok "No Windows NTFS partitions detected on local block devices."
        fi
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "SMART Health Summary"
        if has smartctl; then
            local disk_count=0
            while read -r dev type; do
                [[ "$type" == "disk" && "$dev" != *zram* ]] || continue
                disk_count=$((disk_count + 1))
                printf '\nDevice: %s\n' "$dev"
                run_with_timeout 12 run_as_root smartctl -H "$dev" 2>/dev/null \
                    | grep -E 'SMART overall-health|SMART Health Status|SMART overall-health self-assessment|SMART support is|Percentage Used|Critical Warning' \
                    || echo "SMART status query requires root/sudo access or custom device flag."
            done < <(lsblk -dpno NAME,TYPE 2>/dev/null)
            ((disk_count == 0)) && echo "No physical drives detected."
        else
            echo "smartctl not installed (install smartmontools to inspect SMART health)."
        fi

        log_sub "Storage Discrepancy (du vs df) & Deleted-but-open Files"
        set +o pipefail
        local df_kb du_kb
        df_kb=$(df --output=used -B1K / 2>/dev/null | tail -1 | tr -d ' ' || true)
        du_kb=$(run_as_root du -sx -B1K / 2>/dev/null | awk '{print $1}' || true)
        set -o pipefail

        if [[ "$df_kb" =~ ^[0-9]+$ ]] && [[ "$du_kb" =~ ^[0-9]+$ ]]; then
            local diff_kb=$((df_kb - du_kb))
            local diff_mb=$((diff_kb / 1024))
            local diff_abs=${diff_mb#-}
            printf 'Root (/) via df : %s MB\n' "$((df_kb / 1024))"
            printf 'Root (/) via du : %s MB\n' "$((du_kb / 1024))"
            printf 'Discrepancy     : %s MB\n' "$diff_mb"
            if ((diff_abs > 500)); then
                log_warn "Discrepancy > 500MB between df and du."
                echo "  Common causes: unlinked files held open by processes, btrfs subvolumes/snapshots, or overlayfs mounts."
            fi
        fi

        if has lsof && ((HAS_SUDO == 1)); then
            set +o pipefail
            local deleted_open
            deleted_open=$(run_as_root lsof +L1 2>/dev/null | grep -v "^COMMAND" || true)
            set -o pipefail
            if [[ -n "$deleted_open" ]]; then
                log_warn "Unlinked files held open by running processes (hidden disk consumption):"
                echo "$deleted_open" | head -n 10
            else
                log_ok "No significant deleted-but-open files detected."
            fi
        fi
    fi
}

# =============================================================================
# MODULE 3: NETWORK, DNS, ROUTING, PORTS & FIREWALL
# =============================================================================
audit_network() {
    log_section "3" "NETWORK INTERFACES, ROUTES, DNS, PORTS & FIREWALL"

    log_sub "Network Interfaces & Link State"
    if has ip; then
        ip -br link
    elif has ifconfig; then
        ifconfig -s
    fi

    log_sub "IP Addresses (IPv4 / IPv6)"
    has ip && ip -br addr || true

    log_sub "Routing Table & Default Gateway"
    if has ip; then
        ip route show default 2>/dev/null || true
        local gw
        gw="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
        [[ -n "$gw" ]] && printf 'Default Gateway: %s\n' "$gw"
    fi

    log_sub "DNS Nameservers & Resolver Configuration"
    if has resolvectl; then
        resolvectl status 2>/dev/null | grep -E '^(Global|Link [0-9]+)|Current DNS Server|DNS Servers|DNS Domain' || resolvectl status 2>/dev/null | head -n 25
    elif has systemd-resolve; then
        systemd-resolve --status 2>/dev/null | head -n 25 || true
    else
        safe_cat /etc/resolv.conf
    fi

    log_sub "Listening TCP & UDP Ports"
    if has ss; then
        run_as_root ss -tulpn 2>/dev/null | grep LISTEN | awk '{printf "%-6s %-25s %s\n", $1, $5, $7}' | column -t || ss -tuln
    elif has netstat; then
        run_as_root netstat -tulpn 2>/dev/null | grep LISTEN || netstat -tuln
    fi

    log_sub "Firewall Status"
    # Adaptive Firewall check across Debian/Ubuntu (UFW), Fedora/RHEL (firewalld), or nftables/iptables
    local fw_active=0
    if has ufw; then
        local ufw_stat
        ufw_stat=$(run_as_root ufw status 2>/dev/null || true)
        if echo "$ufw_stat" | grep -qi "Status: active"; then
            log_info "UFW active (Standard on Debian/Ubuntu):"
            run_as_root ufw status verbose 2>/dev/null || true
            fw_active=1
        else
            echo "UFW installed (Status: inactive)."
        fi
    fi

    if has firewall-cmd; then
        local fwd_stat
        fwd_stat=$(run_as_root firewall-cmd --state 2>/dev/null || true)
        if [[ "$fwd_stat" == "running" ]]; then
            log_info "Firewalld active (Standard on Fedora/RHEL):"
            run_as_root firewall-cmd --list-all 2>/dev/null || true
            fw_active=1
        else
            echo "Firewalld installed (Status: $fwd_stat)."
        fi
    fi

    if ((fw_active == 0)); then
        if has nft; then
            local nft_rules
            nft_rules=$(run_as_root nft list ruleset 2>/dev/null || true)
            if [[ -n "$nft_rules" ]]; then
                log_info "nftables active ruleset detected:"
                echo "$nft_rules" | head -n 25
                fw_active=1
            fi
        fi
    fi

    if ((fw_active == 0)); then
        if has iptables; then
            local ipt_rules
            ipt_rules=$(run_as_root iptables -S 2>/dev/null || true)
            if echo "$ipt_rules" | grep -qvE '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$'; then
                log_info "iptables active filter rules detected:"
                echo "$ipt_rules" | head -n 25
                fw_active=1
            fi
        fi
    fi

    if ((fw_active == 0)); then
        log_warn "No active packet filtering firewall (UFW, firewalld, nftables, iptables) is enforcing rules."
    fi

    log_sub "Saved Network Connections (NetworkManager / Netplan / Interfaces / Systemd-Networkd)"
    local net_cfg_found=0
    local net_export=""
    [[ -n "$EXPORT_DIR" ]] && net_export="$EXPORT_DIR/network_connections.txt"

    if has nmcli; then
        nmcli -f NAME,UUID,TYPE,DEVICE,STATE connection show 2>/dev/null | head -n 20 || nmcli connection show | head -n 20
        if [[ -n "$net_export" ]]; then
            nmcli connection show > "$net_export" 2>/dev/null || true
        fi
        net_cfg_found=1
    fi

    # Ubuntu Netplan detection (/etc/netplan/*.yaml)
    if [[ -d /etc/netplan ]] && (compgen -G "/etc/netplan/*.yaml" >/dev/null || compgen -G "/etc/netplan/*.yml" >/dev/null); then
        log_info "Ubuntu Netplan configurations detected (/etc/netplan):"
        for f in /etc/netplan/*.y*ml; do
            [[ -r "$f" ]] || continue
            printf '  [%s]:\n' "$(basename "$f")"
            cat "$f" 2>/dev/null | head -n 20 | sed 's/^/    /' || true
            if [[ -n "$net_export" && ! -s "$net_export" ]]; then
                cat "$f" >> "$net_export" 2>/dev/null || true
            fi
        done
        net_cfg_found=1
    fi

    # Debian /etc/network/interfaces detection
    if [[ -f /etc/network/interfaces ]]; then
        log_info "Debian network interfaces file detected (/etc/network/interfaces):"
        grep -v -E '^[[:space:]]*#' /etc/network/interfaces 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 20 | sed 's/^/  /' || true
        if [[ -n "$net_export" && ! -s "$net_export" ]]; then
            cat /etc/network/interfaces >> "$net_export" 2>/dev/null || true
        fi
        net_cfg_found=1
    fi

    # systemd-networkd links detection
    if has networkctl; then
        local netctl_out
        netctl_out=$(networkctl list --no-legend 2>/dev/null || true)
        if [[ -n "$netctl_out" ]]; then
            log_info "systemd-networkd active links:"
            echo "$netctl_out" | head -n 10 | sed 's/^/  /'
            net_cfg_found=1
        fi
    fi

    if ((net_cfg_found == 0)); then
        echo "Default interface status via ip addr:"
        ip -br addr | sed 's/^/  /'
        if [[ -n "$net_export" ]]; then
            ip -br addr > "$net_export" 2>/dev/null || true
        fi
    fi

    if [[ -n "$net_export" && -s "$net_export" ]]; then
        log_ok "Exported network connections/configurations to $net_export"
    fi

    log_sub "Tailscale / VPN"
    if has tailscale; then
        tailscale status 2>/dev/null || true
    else
        echo "Tailscale not installed."
    fi
}

# =============================================================================
# MODULE 4: SECURITY POSTURE, ACCOUNTS, SSH, MAC & SECRETS SCAN
# =============================================================================
audit_security() {
    log_section "4" "SECURITY POSTURE, ACCOUNTS, SSH, MAC & SECRETS"

    log_sub "Mandatory Access Control (SELinux / AppArmor)"
    if has getenforce; then
        printf 'SELinux Status  : %b%s%b\n' "$C_INFO" "$(getenforce 2>/dev/null)" "$C_RESET"
    else
        echo "SELinux tools not installed."
    fi

    if has aa-status; then
        echo "AppArmor Status:"
        run_as_root aa-status 2>/dev/null | head -n 20 || true
    else
        echo "AppArmor tools not installed."
    fi

    log_sub "SSH Effective Security Configuration"
    if has sshd; then
        run_as_root sshd -T 2>/dev/null | grep -E \
            '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|x11forwarding|allowusers|allowgroups|maxauthtries|clientaliveinterval|clientalivecountmax) ' \
            || echo "Unable to inspect effective sshd configuration (requires sudo or running sshd)."
    else
        echo "sshd daemon not found in system PATH."
    fi

    log_sub "User Accounts with Interactive Shells"
    awk -F: '
        $7 !~ /(nologin|false|sync|shutdown|halt)$/ {
            printf "%-20s UID=%-6s GID=%-6s HOME=%-25s SHELL=%s\n", $1, $3, $4, $6, $7
        }
    ' /etc/passwd 2>/dev/null || true

    log_sub "Currently Logged In & Recent Logins"
    who 2>/dev/null || true
    echo ""
    printf 'Recent Logins (last 5):\n'
    last -n 5 2>/dev/null || true

    log_sub "Administrative Groups (sudo / wheel)"
    grep -E '^(sudo|wheel|admin):' /etc/group 2>/dev/null || true

    log_sub "SSH & GPG Keys Hygiene (Target User: $TARGET_USER)"
    if [[ -d "$TARGET_HOME/.ssh" ]]; then
        local ssh_perm
        ssh_perm=$(stat -c "%a" "$TARGET_HOME/.ssh" 2>/dev/null || echo "")
        printf '%s/.ssh directory exists. Permissions: %s %s\n' "$TARGET_HOME" "$ssh_perm" "$([[ "$ssh_perm" == "700" ]] && echo "[OK]" || echo "[WARN: Should be 700]")"
        ls -la "$TARGET_HOME/.ssh" 2>/dev/null | grep -v '\.$' || true
    else
        echo "No $TARGET_HOME/.ssh directory found."
    fi

    if [[ -d "$TARGET_HOME/.gnupg" ]]; then
        printf '%s/.gnupg directory exists.\n' "$TARGET_HOME"
    fi

    log_sub "Keyrings & Password Stores"
    if [[ -d "$TARGET_HOME/.local/share/keyrings" ]]; then
        log_info "GNOME Keyring detected ($TARGET_HOME/.local/share/keyrings):"
        ls -la "$TARGET_HOME/.local/share/keyrings" 2>/dev/null || true
    fi
    if [[ -d "$TARGET_HOME/.local/share/kwalletd" ]]; then
        log_info "KDE KWallet detected ($TARGET_HOME/.local/share/kwalletd):"
        ls -la "$TARGET_HOME/.local/share/kwalletd" 2>/dev/null || true
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "World-Writable Directories without Sticky Bit"
        set +o pipefail
        find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null | grep -v -E '^/(proc|sys|run|tmp|var/tmp)' | head -n 15 || true
        set -o pipefail

        log_sub "SUID & SGID Binaries in /usr and /opt"
        set +o pipefail
        find /usr /opt -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -n 30 || true
        set -o pipefail

        log_sub "Sensitive Files & Secrets Scan ($TARGET_USER Profile)"
        local secrets_file=""
        [[ -n "$EXPORT_DIR" ]] && secrets_file="$EXPORT_DIR/secrets_found.txt"
        local found_secrets
        found_secrets=$(find "$TARGET_HOME/main" "$TARGET_HOME/.config" "$TARGET_HOME/.ssh" -maxdepth 4 -type f \( \
            -name "*.env*" -o \
            -name "*.pem" -o \
            -name "*.key" -o \
            -name "*token*" -o \
            -name "*.tfvars" -o \
            -name "*.tfstate*" -o \
            -name "*secret*.yaml" -o \
            -name "*secret*.yml" \
        \) 2>/dev/null | grep -Ev '/node_modules/|/\.git/|/\.venv/|/cache/|/known_hosts' || true)

        local secret_count=0
        if [[ -n "$found_secrets" ]]; then
            secret_count=$(echo "$found_secrets" | wc -l)
            log_warn "Detected $secret_count sensitive files (private keys, tokens, .env):"
            echo "$found_secrets" | head -n 15 | sed 's/^/  - /'
            if ((secret_count > 15)); then
                printf '  ... and %d more files.\n' "$((secret_count - 15))"
            fi
            if [[ -n "$secrets_file" ]]; then
                echo "$found_secrets" > "$secrets_file"
                log_ok "Saved secrets list to $secrets_file"
            fi
        else
            log_ok "No sensitive secrets or unencrypted private keys found in scanned paths."
        fi
    fi
}

# =============================================================================
# MODULE 5: PROCESSES, SERVICES, SYSTEMD & SYSTEM ERRORS
# =============================================================================
audit_processes_services() {
    log_section "5" "PROCESSES, SYSTEMD SERVICES & ERROR LOGS"

    log_sub "Process & Thread Counts"
    printf 'Running Processes : %s\n' "$(ps -e --no-headers 2>/dev/null | wc -l)"
    printf 'Active Threads    : %s\n' "$(ps -eLf --no-headers 2>/dev/null | wc -l)"
    printf 'Zombie Processes  : %s\n' "$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ {count++} END {print count + 0}')"

    log_sub "Top 10 Processes by Memory Usage (RSS)"
    printf "%-8s %-12s %6s %8s %-25s\n" "PID" "USER" "%MEM" "RSS(MB)" "COMMAND"
    set +o pipefail
    ps -eo pid,user,%mem,rss,comm --sort=-%mem 2>/dev/null | \
        awk 'NR>1 {printf "%-8s %-12s %6s %8.1f %-25s\n", $1, $2, $3, $4/1024, $5}' | \
        head -n 10
    set -o pipefail

    log_sub "Top 10 Processes by CPU Usage"
    printf "%-8s %-12s %6s %6s %-25s\n" "PID" "USER" "%CPU" "%MEM" "COMMAND"
    set +o pipefail
    ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | \
        awk 'NR>1 {printf "%-8s %-12s %6s %6s %-25s\n", $1, $2, $3, $4, $5}' | \
        head -n 10
    set -o pipefail

    log_sub "Aggregate Memory (RSS) by User"
    ps -eo user,rss --no-headers 2>/dev/null | \
        awk '{mem[$1]+=$2} END {for (u in mem) printf "%-18s %8.1f MB\n", u, mem[u]/1024}' | \
        sort -k2 -nr | head -n 8

    log_sub "Systemd Failed Units"
    if has systemctl; then
        local failed_count
        failed_count=$(systemctl --failed --no-legend 2>/dev/null | wc -l || true)
        if ((failed_count > 0)); then
            log_warn "Detected $failed_count failed systemd unit(s):"
            systemctl --failed --no-pager --plain 2>/dev/null || true
        else
            log_ok "Zero systemd units failed."
        fi

        log_sub "Enabled but Inactive System Services"
        set +o pipefail
        comm -23 <(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | sort) \
                 <(systemctl list-units --state=active --no-legend --type=service 2>/dev/null | awk '{print $1}' | sort) 2>/dev/null | head -n 15 || true
        set -o pipefail
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "Recent Critical Boot Logs (Priority 0..3)"
        if has journalctl; then
            run_as_root journalctl -p 0..3 -b --no-pager -n 30 2>/dev/null || true
        elif has dmesg; then
            run_as_root dmesg --level=emerg,alert,crit,err 2>/dev/null | tail -n 30 || true
        fi

        log_sub "Kernel Warnings & Errors"
        if has journalctl; then
            run_as_root journalctl -k -b -p warning --no-pager -n 25 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# MODULE 6: PACKAGES & SOFTWARE INVENTORY (DEBIAN / UBUNTU / FEDORA / UNIVERSAL)
# =============================================================================
audit_packages() {
    log_section "6" "PACKAGE MANAGERS & SOFTWARE INVENTORY"

    log_sub "Native Package Manager ($DISTRO_FAMILY Family)"

    local universal_export=""
    local universal_all_export=""
    local repo_export=""
    if [[ -n "$EXPORT_DIR" ]]; then
        universal_export="$EXPORT_DIR/packages_userinstalled.txt"
        universal_all_export="$EXPORT_DIR/packages_all.txt"
        repo_export="$EXPORT_DIR/repositories.txt"
    fi

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        # Debian / Ubuntu (dpkg & apt)
        if has dpkg-query; then
            local dpkg_count
            dpkg_count=$(dpkg-query -f '${binary:Package}\n' -W 2>/dev/null | wc -l)
            printf 'Installed DEB packages   : %s\n' "$dpkg_count"
            if [[ -n "$universal_all_export" ]]; then
                dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' 2>/dev/null | sort > "$universal_all_export" || true
            fi
        fi

        if has apt-mark; then
            local manual_count
            manual_count=$(apt-mark showmanual 2>/dev/null | wc -l)
            printf 'User-installed (manual)  : %s\n' "$manual_count"

            local held_count
            held_count=$(apt-mark showhold 2>/dev/null | wc -l)
            [[ "$held_count" -gt 0 ]] && printf 'Held / Pinned packages   : %s\n' "$held_count"

            if [[ -n "$universal_export" ]]; then
                apt-mark showmanual 2>/dev/null | sort > "$universal_export" || true
                # Compatibility link/copy for Debian/Ubuntu legacy scripts
                cp -f "$universal_export" "$EXPORT_DIR/apt_manual_installed.txt" 2>/dev/null || true
                log_ok "Exported manual package list to $universal_export (and apt_manual_installed.txt)"
            fi
        fi

        # Software Repositories & PPAs Inspection (Debian / Ubuntu)
        log_sub "APT Repositories & Third-Party Sources (Debian/Ubuntu)"
        local repo_list=""
        if [[ -f /etc/apt/sources.list ]]; then
            repo_list+=$(grep -E '^[[:space:]]*deb ' /etc/apt/sources.list 2>/dev/null || true)$'\n'
        fi
        if [[ -d /etc/apt/sources.list.d ]]; then
            repo_list+=$(grep -E -h '^[[:space:]]*deb ' /etc/apt/sources.list.d/*.list 2>/dev/null || true)$'\n'
            # deb822 format (standard in Ubuntu 24.04+ / Debian 12+)
            repo_list+=$(grep -E -h '^URIs: ' /etc/apt/sources.list.d/*.sources 2>/dev/null | awk '{for(i=2;i<=NF;i++) print "deb822 " $i}' || true)$'\n'
        fi

        if [[ -n "$repo_list" ]]; then
            local clean_repos
            clean_repos=$(echo "$repo_list" | sed 's/^[[:space:]]*//' | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u || true)
            local apt_sources_count apt_ppa_count
            apt_sources_count=$(echo "$clean_repos" | grep -c . || echo 0)
            apt_ppa_count=$(echo "$clean_repos" | grep -c 'ppa.launchpad.net' || echo 0)
            printf 'Active APT Repositories  : %s\n' "$apt_sources_count"
            printf 'Third-party PPAs         : %s\n' "$apt_ppa_count"
            if [[ -n "$repo_export" ]]; then
                echo "$clean_repos" > "$repo_export"
                log_ok "Exported APT repositories to $repo_export"
            fi
            if ((apt_sources_count > 0)); then
                echo "Active Repositories (Sample):"
                echo "$clean_repos" | head -n 8 | sed 's/^/  - /'
            fi
        fi

        if ((QUICK_MODE == 0)); then
            log_sub "APT Upgrades & Security Status"
            local up_count=0 sec_count=0
            if has apt-get; then
                local sim_upgrade
                sim_upgrade=$(run_as_root apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null || true)
                up_count=$(echo "$sim_upgrade" | grep -c '^Inst ' || true)
                sec_count=$(echo "$sim_upgrade" | grep -E '^Inst ' | grep -iE 'security|debian-security|ubuntu.*-security' | wc -l || true)
            elif has apt; then
                up_count=$(apt list --upgradable 2>/dev/null | grep -v 'Listing\.\.\.' | wc -l || true)
            fi
            printf 'Upgradable packages      : %s\n' "${up_count:-0}"
            if (( sec_count > 0 )); then
                log_warn "Pending Security Updates : $sec_count package(s)!"
            fi
            if (( up_count > 0 )) && has apt; then
                apt list --upgradable 2>/dev/null | grep -v 'Listing\.\.\.' | head -n 15 | sed 's/^/  - /' || true
            fi
        fi

        if [[ -f /var/run/reboot-required ]]; then
            log_warn "System reboot is REQUIRED (/var/run/reboot-required flag set)!"
            [[ -r /var/run/reboot-required.pkgs ]] && cat /var/run/reboot-required.pkgs | head -n 10 | sed 's/^/  - /'
        else
            log_ok "No reboot-required flag detected."
        fi

    elif [[ "$DISTRO_FAMILY" == "redhat" ]]; then
        # Fedora / RHEL (rpm & dnf / dnf5)
        if has rpm; then
            local rpm_count
            rpm_count=$(rpm -qa 2>/dev/null | wc -l)
            printf 'Installed RPM packages   : %s\n' "$rpm_count"
            if [[ -n "$universal_all_export" ]]; then
                rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' 2>/dev/null | sort > "$universal_all_export" || true
            fi
        fi

        local dnf_cmd="dnf"
        has dnf5 && dnf_cmd="dnf5"

        local user_pkgs=""
        if has "$dnf_cmd"; then
            user_pkgs=$("$dnf_cmd" repoquery --userinstalled 2>/dev/null | wc -l || true)
        fi
        if [[ -z "$user_pkgs" || "$user_pkgs" == "0" ]] && has dnf; then
            user_pkgs=$(dnf repoquery --userinstalled 2>/dev/null | wc -l || true)
        fi
        if [[ -z "$user_pkgs" || "$user_pkgs" == "0" ]] && has rpm; then
            user_pkgs=$(rpm -qa 2>/dev/null | wc -l || echo 0)
        fi
        printf 'User-installed (manual)  : %s\n' "${user_pkgs:-0}"

        if [[ -n "$universal_export" ]]; then
            if has "$dnf_cmd"; then
                "$dnf_cmd" repoquery --userinstalled > "$universal_export" 2>/dev/null || true
            fi
            if [[ ! -s "$universal_export" ]] && has rpm; then
                rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort > "$universal_export" || true
            fi
            # Compatibility link/copy for Fedora legacy scripts
            cp -f "$universal_export" "$EXPORT_DIR/dnf_userinstalled.txt" 2>/dev/null || true
            log_ok "Exported manual package list to $universal_export (and dnf_userinstalled.txt)"
        fi

        # DNF Repositories Inspection (Fedora / RHEL)
        log_sub "DNF Repositories & Channels (Fedora/RHEL)"
        local dnf_repos=""
        if has "$dnf_cmd"; then
            dnf_repos=$("$dnf_cmd" repolist --enabled 2>/dev/null || true)
        fi
        if [[ -n "$dnf_repos" ]]; then
            local repo_count
            repo_count=$(echo "$dnf_repos" | tail -n +2 | grep -c . || echo 0)
            printf 'Active DNF Repositories  : %s\n' "${repo_count:-0}"
            echo "$dnf_repos" | head -n 12 | sed 's/^/  /'
            if [[ -n "$repo_export" ]]; then
                echo "$dnf_repos" > "$repo_export"
                log_ok "Exported DNF repositories to $repo_export"
            fi
        fi

        if ((QUICK_MODE == 0)); then
            log_sub "DNF Upgradable Packages & Reboot Status"
            run_with_timeout 30 run_as_root "$dnf_cmd" check-update --quiet 2>/dev/null | head -n 25 || true
            if has needs-restarting; then
                run_as_root needs-restarting -r 2>/dev/null || true
            fi
        fi

    elif [[ "$DISTRO_FAMILY" == "arch" ]]; then
        if has pacman; then
            printf 'Installed Pacman packages: %s\n' "$(pacman -Q 2>/dev/null | wc -l)"
            printf 'Explicitly installed     : %s\n' "$(pacman -Qe 2>/dev/null | wc -l)"
            if [[ -n "$universal_export" ]]; then
                pacman -Qqe 2>/dev/null | sort > "$universal_export" || true
                log_ok "Exported explicitly installed packages to $universal_export"
            fi
            if [[ -n "$universal_all_export" ]]; then
                pacman -Q 2>/dev/null | sort > "$universal_all_export" || true
            fi
            if ((QUICK_MODE == 0)) && has checkupdates; then
                printf 'Upgradable packages      : %s\n' "$(checkupdates 2>/dev/null | wc -l)"
            fi
        fi
    fi

    [[ -n "$universal_all_export" && -s "$universal_all_export" ]] && log_ok "Exported complete package inventory to $universal_all_export"

    log_sub "Universal & Sandbox App Packages (Flatpak / Snap / AppImage)"
    if has flatpak; then
        local fp_apps fp_runtimes
        fp_apps=$(flatpak list --app 2>/dev/null | wc -l)
        fp_runtimes=$(flatpak list --runtime 2>/dev/null | wc -l)
        printf 'Flatpak Applications     : %s\n' "$fp_apps"
        printf 'Flatpak Runtimes         : %s\n' "$fp_runtimes"
        if ((fp_apps > 0)); then
            flatpak list --app --columns=name,application,version,origin 2>/dev/null | head -n 15
        fi
        if [[ -n "$EXPORT_DIR" ]]; then
            flatpak list --app --columns=name,application,version,origin > "$EXPORT_DIR/flatpak_apps.txt" 2>/dev/null || true
        fi
    else
        echo "Flatpak not installed."
    fi

    if has snap; then
        local snap_count
        snap_count=$(snap list 2>/dev/null | tail -n +2 | wc -l || true)
        printf 'Snap Packages            : %s\n' "$snap_count"
        if ((snap_count > 0)); then
            snap list 2>/dev/null | head -n 15
        fi
        if [[ -n "$EXPORT_DIR" ]]; then
            snap list 2>/dev/null > "$EXPORT_DIR/snap_apps.txt" || true
            log_ok "Exported snap packages to $EXPORT_DIR/snap_apps.txt"
        fi
    else
        echo "Snap not installed."
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "AppImages Detected"
        local appimage_dirs=("$TARGET_HOME" "$TARGET_HOME/Applications" "$TARGET_HOME/.local/bin" "/opt" "/usr/local/bin")
        for d in "${appimage_dirs[@]}"; do
            [[ -d "$d" ]] || continue
            find "$d" -maxdepth 3 -type f \( -iname "*.AppImage" -o -iname "*.appimage" \) 2>/dev/null | sed 's/^/  - /' || true
        done

        log_sub "Custom & Manual Binaries ($TARGET_USER PATH)"
        printf 'Executables in %s/.local/bin:\n' "$TARGET_HOME"
        find "$TARGET_HOME/.local/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -n 15 | sed 's/^/  - /' || echo "  (None)"
        printf 'Executables in /usr/local/bin:\n'
        find /usr/local/bin -maxdepth 1 -type f -executable 2>/dev/null | head -n 15 | sed 's/^/  - /' || echo "  (None)"

        log_sub "Broken Desktop Launchers (.desktop pointing to missing binaries)"
        for dir in /usr/share/applications "$TARGET_HOME/.local/share/applications"; do
            [[ -d "$dir" ]] || continue
            for f in "$dir"/*.desktop; do
                [[ -f "$f" ]] || continue
                local exec_line bin
                exec_line=$(grep -m1 '^Exec=' "$f" 2>/dev/null | sed 's/^Exec=//' | awk '{print $1}')
                [[ -z "$exec_line" ]] && continue
                bin=$(basename "$exec_line")
                if ! has "$bin" && [[ ! -x "$exec_line" ]]; then
                    printf '  [BROKEN] %s -> Exec=%s\n' "$f" "$exec_line"
                fi
            done
        done
    fi
}

# =============================================================================
# MODULE 7: VIRTUALIZATION, CONTAINERS & ORCHESTRATION
# =============================================================================
audit_containers_virt() {
    log_section "7" "CONTAINERS, KUBERNETES & VIRTUALIZATION"

    log_sub "Container & Virtualization Daemons"
    if has systemctl; then
        local services=(docker containerd podman crio k3s kubelet tailscaled libvirtd virtqemud)
        printf "%-20s %-12s %-12s\n" "Service" "Active" "Enabled"
        log_rule
        for svc in "${services[@]}"; do
            if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
                local s_act s_ena
                s_act="$(systemctl is-active "$svc" 2>/dev/null || true)"
                s_act="${s_act:-inactive}"
                s_ena="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
                s_ena="${s_ena:-disabled}"
                printf "%-20s %-12s %-12s\n" "$svc" "$s_act" "$s_ena"
            fi
        done
    fi

    log_sub "Docker Subsystem"
    if has docker; then
        local d_running d_stopped d_dangling
        d_running=$( (set +o pipefail; run_as_root docker ps -q 2>/dev/null | wc -l | tr -d ' ') )
        d_stopped=$( (set +o pipefail; run_as_root docker ps -aq --filter "status=exited" 2>/dev/null | wc -l | tr -d ' ') )
        d_dangling=$( (set +o pipefail; run_as_root docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ') )
        printf 'Running Containers       : %s\n' "${d_running:-0}"
        printf 'Stopped Containers       : %s\n' "${d_stopped:-0}"
        printf 'Dangling Images          : %s\n' "${d_dangling:-0}"
        if (( ${d_running:-0} > 0 )); then
            run_as_root docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
        fi
        if has docker && ((HAS_SUDO == 1)); then
            run_as_root docker system df 2>/dev/null || true
        fi
    else
        echo "Docker CLI not installed."
    fi

    log_sub "Podman Subsystem"
    if has podman; then
        local p_running p_total
        p_running=$( (set +o pipefail; podman ps -q 2>/dev/null | wc -l | tr -d ' ') )
        p_total=$( (set +o pipefail; podman ps -aq 2>/dev/null | wc -l | tr -d ' ') )
        printf 'Running Containers       : %s\n' "${p_running:-0}"
        printf 'Total Containers         : %s\n' "${p_total:-0}"
        if (( ${p_running:-0} > 0 )); then
            podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
        fi
    else
        echo "Podman not installed."
    fi

    log_sub "Kubernetes & Kind Clusters"
    if has kubectl; then
        printf 'Current Kube Context     : %s\n' "$(kubectl config current-context 2>/dev/null || echo "None")"
        kubectl get nodes -o wide 2>/dev/null || echo "Unable to connect to Kubernetes API server."
    elif has k3s; then
        run_as_root k3s kubectl get nodes -o wide 2>/dev/null || true
    else
        echo "Kubectl CLI not installed."
    fi

    if has kind; then
        local kind_clusters
        kind_clusters=$(kind get clusters 2>/dev/null || true)
        if [[ -n "$kind_clusters" ]]; then
            log_warn "Active kind clusters detected:"
            echo "$kind_clusters" | sed 's/^/  - /'
        else
            log_ok "No kind clusters found."
        fi
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "Orphan Network Namespaces & Overlay Mounts"
        if has ip; then
            local netns_list
            netns_list=$(run_as_root ip netns list 2>/dev/null || true)
            if [[ -n "$netns_list" ]]; then
                log_warn "Orphan network namespaces found via ip netns:"
                echo "$netns_list" | sed 's/^/  - /'
            else
                log_ok "Zero orphan network namespaces via ip netns."
            fi
        fi

        if has findmnt; then
            local overlay_mounts
            overlay_mounts=$(findmnt -rno TARGET,FSTYPE 2>/dev/null | awk '$2 ~ /^(overlay|nsfs)$/' || true)
            if [[ -n "$overlay_mounts" ]]; then
                log_info "Active overlay/nsfs mounts detected:"
                echo "$overlay_mounts" | head -n 10 | sed 's/^/  - /'
            fi
        fi

        log_sub "Hypervisor & Libvirt VMs"
        if has virsh; then
            virsh --connect qemu:///session list --all 2>/dev/null || true
            if ((HAS_SUDO == 1)); then
                run_as_root virsh --connect qemu:///system list --all 2>/dev/null || true
            fi
        else
            echo "virsh CLI not installed."
        fi
    fi
}

# =============================================================================
# MODULE 8: JUNK, CACHE, LEFTOVER & RECLAIMABLE SPACE ANALYSIS
# =============================================================================
audit_junk_cleanup() {
    log_section "8" "CACHE, JUNK, LEFTOVERS & RECLAIMABLE SPACE"

    log_sub "Package Manager Caches"
    local dnf_cache_dirs=(/var/cache/dnf /var/cache/libdnf5)
    for d in "${dnf_cache_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            local sz_kb sz_h
            sz_kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
            sz_h=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
            printf 'DNF Cache [%s]: %s\n' "$d" "${sz_h:-0}"
            add_reclaim "${sz_kb:-0}"
        fi
    done

    local apt_cache_dir="/var/cache/apt/archives"
    if [[ -d "$apt_cache_dir" ]]; then
        local sz_kb sz_h
        sz_kb=$(du -sk "$apt_cache_dir" 2>/dev/null | awk '{print $1}')
        sz_h=$(du -sh "$apt_cache_dir" 2>/dev/null | awk '{print $1}')
        printf 'APT Cache [%s]: %s\n' "$apt_cache_dir" "${sz_h:-0}"
        add_reclaim "${sz_kb:-0}"
    fi

    local apt_lists_dir="/var/lib/apt/lists"
    if [[ -d "$apt_lists_dir" ]]; then
        local sz_kb sz_h
        sz_kb=$(du -sk "$apt_lists_dir" 2>/dev/null | awk '{print $1}')
        sz_h=$(du -sh "$apt_lists_dir" 2>/dev/null | awk '{print $1}')
        printf 'APT Package Lists [%s]: %s\n' "$apt_lists_dir" "${sz_h:-0}"
    fi

    # Snap disabled revisions inspection (Ubuntu)
    if [[ -d /var/lib/snapd/snaps ]] && has snap; then
        local disabled_snaps
        disabled_snaps=$(snap list --all 2>/dev/null | grep -i disabled || true)
        if [[ -n "$disabled_snaps" ]]; then
            local snap_dis_count
            snap_dis_count=$(echo "$disabled_snaps" | wc -l)
            log_info "Disabled old Snap revisions (/var/lib/snapd/snaps): $snap_dis_count revision(s) taking space."
        fi
    fi

    log_sub "Installed Kernels & Retention"
    local running_k
    running_k="$(uname -r 2>/dev/null)"
    printf 'Running Kernel           : %s\n' "$running_k"
    if [[ "$DISTRO_FAMILY" == "debian" ]] && has dpkg; then
        local k_pkgs k_count
        k_pkgs=$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | grep '^ii' | awk '{print $2}' || true)
        k_count=$(echo "$k_pkgs" | grep -c . || echo 0)
        printf 'Installed Linux Kernels  : %s\n' "$k_count"
        if ((k_count > 2)); then
            log_warn "Multiple old kernels detected ($k_count). Can be pruned via 'sudo apt autoremove --purge'."
        fi
    elif [[ "$DISTRO_FAMILY" == "redhat" ]] && has rpm; then
        local k_count
        k_count=$(rpm -q kernel-core 2>/dev/null | grep -c . || true)
        printf 'Installed Linux Kernels  : %s\n' "${k_count:-0}"
    fi

    log_sub "Systemd Journal Logs & Core Dumps"
    if has journalctl; then
        journalctl --disk-usage 2>/dev/null || true
    fi

    if [[ -d /var/lib/systemd/coredump ]]; then
        local sz_kb sz_h
        sz_kb=$(du -sk /var/lib/systemd/coredump 2>/dev/null | awk '{print $1}')
        sz_h=$(du -sh /var/lib/systemd/coredump 2>/dev/null | awk '{print $1}')
        printf 'Core Dumps [/var/lib/systemd/coredump]: %s\n' "${sz_h:-0}"
        add_reclaim "${sz_kb:-0}"
    fi

    log_sub "User Cache & Trash ($TARGET_USER Profile)"
    if [[ -d "$TARGET_HOME/.cache" ]]; then
        local sz_kb sz_h
        sz_kb=$(du -sk "$TARGET_HOME/.cache" 2>/dev/null | awk '{print $1}')
        sz_h=$(du -sh "$TARGET_HOME/.cache" 2>/dev/null | awk '{print $1}')
        printf '%s/.cache total size: %s\n' "$TARGET_HOME" "${sz_h:-0}"
        add_reclaim "${sz_kb:-0}"
        echo "Top 8 heaviest folders in ~/.cache:"
        du -sh "$TARGET_HOME"/.cache/*/ 2>/dev/null | sort -rh | head -n 8 | sed 's/^/  /' || true
    fi

    if [[ -d "$TARGET_HOME/.local/share/Trash" ]]; then
        local sz_kb sz_h
        sz_kb=$(du -sk "$TARGET_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
        sz_h=$(du -sh "$TARGET_HOME/.local/share/Trash" 2>/dev/null | awk '{print $1}')
        printf 'Trash size (%s/.local/share/Trash): %s\n' "$TARGET_HOME" "${sz_h:-0}"
        add_reclaim "${sz_kb:-0}"
    fi

    if ((QUICK_MODE == 0)); then
        log_sub "Broken Symlinks in System & User Bins"
        local symlink_dirs=(/usr/local/bin /usr/local/lib "$TARGET_HOME/.local/bin" /opt)
        for dir in "${symlink_dirs[@]}"; do
            [[ -d "$dir" ]] || continue
            find "$dir" -xtype l 2>/dev/null | head -n 15 | sed 's/^/  [BROKEN SYMLINK] /' || true
        done

        log_sub "Suspected Leftover Configuration Folders (>10MB)"
        # Scan ~/.config and ~/.local/share for large app folders
        for base in "$TARGET_HOME/.config" "$TARGET_HOME/.local/share"; do
            [[ -d "$base" ]] || continue
            for d in "$base"/*/; do
                local name
                name=$(basename "$d")
                case "$name" in
                    gnome*|dconf|systemd|pulse|pipewire|wireplumber|ibus|fcitx*|fontconfig|mime|Trash|flatpak|nautilus|BraveSoftware|google-chrome|firefox|ghostty)
                        continue ;;
                esac
                local sz_kb sz_h
                sz_kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
                if [[ -n "$sz_kb" && "$sz_kb" -gt 10240 ]]; then
                    sz_h=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
                    printf '  [LEFTOVER CANDIDATE] %s (~%s)\n' "$d" "$sz_h"
                fi
            done
        done

        log_sub "Large Stale Files in Home (>300MB, >120 days unaccessed)"
        find "$TARGET_HOME" -xdev -type f -size +300M -atime +120 \
            ! -path "*/.cache/*" ! -path "*/.local/share/Trash/*" ! -path "*/node_modules/*" 2>/dev/null \
            -printf '  %10s bytes  %AY-%Am-%Ad  %p\n' 2>/dev/null | sort -rn | head -n 10 || true

        log_sub "Downloads Folder (>90 days old)"
        if [[ -d "$TARGET_HOME/Downloads" ]]; then
            local old_dl_count
            old_dl_count=$(find "$TARGET_HOME/Downloads" -maxdepth 2 -type f -mtime +90 2>/dev/null | wc -l)
            printf 'Files older than 90 days in %s/Downloads: %s\n' "$TARGET_HOME" "$old_dl_count"
            printf 'Total Downloads disk usage             : %s\n' "$(du -sh "$TARGET_HOME/Downloads" 2>/dev/null | awk '{print $1}')"
        fi
    fi

    log_sub "Reclaimable Disk Space Summary"
    local rec_mb=$((TOTAL_RECLAIMABLE_KB / 1024))
    local rec_gb
    rec_gb=$(awk -v kb="$TOTAL_RECLAIMABLE_KB" 'BEGIN { printf "%.2f", kb / 1024 / 1024 }')
    printf '%bEstimated Safe Reclaimable Space (Cache + Trash): ~%s MB (~%s GB)%b\n' "$C_OK" "$rec_mb" "$rec_gb" "$C_RESET"
    echo ""
    echo "Recommended non-destructive cleanup commands:"
    if [[ "$DISTRO_FAMILY" == "redhat" ]]; then
        echo "  sudo dnf clean all && sudo dnf autoremove"
        echo "  # Remove old kernels: sudo dnf remove --oldinstallonly"
    elif [[ "$DISTRO_FAMILY" == "debian" ]]; then
        echo "  sudo apt clean && sudo apt autoremove --purge"
        has snap && echo "  # Clean disabled snaps: snap list --all | awk '/disabled/{print \$1, \$3}' | while read n r; do sudo snap remove \"\$n\" --revision=\"\$r\"; done"
    elif [[ "$DISTRO_FAMILY" == "arch" ]]; then
        echo "  sudo pacman -Sc && pacman -Qtdq | sudo pacman -Rns - (if any orphans)"
    fi
    echo "  sudo journalctl --vacuum-time=7d"
    has flatpak && echo "  flatpak uninstall --unused"
    has docker && echo "  docker system prune -f"
    has podman && echo "  podman system prune -f"
    echo "  rm -rf ~/.cache/*"
}

# =============================================================================
# MODULE 9: DEVELOPER ENVIRONMENT & GIT REPOSITORIES
# =============================================================================
audit_dev_git() {
    log_section "9" "DEVELOPER ENVIRONMENT & GIT REPOSITORIES"

    log_sub "Developer CLI Toolchain"
    local dev_tools=(git node npm pnpm yarn python3 pip3 rustc cargo go gcc g++ clang make cmake terraform aws az gh docker podman kubectl helm)
    printf "%-15s %-10s %s\n" "Tool" "Installed" "Version / Location"
    log_rule
    for tool in "${dev_tools[@]}"; do
        if has "$tool"; then
            local ver
            ver="$("$tool" --version 2>/dev/null | head -n 1 || which "$tool" 2>/dev/null)"
            printf "%-15s %-10s %s\n" "$tool" "[YES]" "$ver"
        fi
    done

    log_sub "PATH Environment Variable Inspection"
    echo "$PATH" | tr ':' '\n' | while read -r p; do
        if [[ ! -d "$p" ]]; then
            printf '  [STALE / DEAD PATH] %s\n' "$p"
        elif [[ -w "$p" ]]; then
            printf '  [WRITABLE]          %s\n' "$p"
        fi
    done

    log_sub "Git Repositories Status Scan ($TARGET_USER Profile)"
    local target_repo_dir="$TARGET_HOME/main"
    [[ ! -d "$target_repo_dir" ]] && target_repo_dir="$TARGET_HOME"

    local git_report=""
    [[ -n "$EXPORT_DIR" ]] && git_report="$EXPORT_DIR/git_status.txt"

    local total_repos=0 dirty_repos=0 unpushed_repos=0
    set +o pipefail
    while IFS= read -r gitdir; do
        [[ -d "$gitdir" ]] || continue
        local repo_dir
        repo_dir="$(dirname "$gitdir")"
        total_repos=$((total_repos + 1))

        local r_status cur_branch upstream unpushed=""
        r_status=$(git -C "$repo_dir" status --porcelain 2>/dev/null || true)
        cur_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || echo "HEAD detached")
        upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)

        if [[ -n "$upstream" ]]; then
            unpushed=$(git -C "$repo_dir" log "${upstream}..HEAD" --oneline 2>/dev/null || true)
        fi

        local has_issue=0
        if [[ -n "$r_status" ]]; then
            dirty_repos=$((dirty_repos + 1))
            has_issue=1
            log_warn "DIRTY (Uncommitted changes): $repo_dir [Branch: $cur_branch]"
            echo "$r_status" | head -n 4 | sed 's/^/    /'
        fi

        if [[ -n "$unpushed" ]]; then
            unpushed_repos=$((unpushed_repos + 1))
            has_issue=1
            log_warn "UNPUSHED COMMITS: $repo_dir [Branch: $cur_branch]"
            echo "$unpushed" | head -n 3 | sed 's/^/    /'
        fi

        if [[ -n "$git_report" ]]; then
            echo "Repo: $repo_dir [Branch: $cur_branch]" >> "$git_report"
            [[ -n "$r_status" ]] && echo "Status: DIRTY" >> "$git_report" && echo "$r_status" >> "$git_report"
            [[ -n "$unpushed" ]] && echo "Status: UNPUSHED" >> "$git_report" && echo "$unpushed" >> "$git_report"
            ((has_issue == 0)) && echo "Status: CLEAN & SYNCED" >> "$git_report"
            echo "--------------------------------------------------" >> "$git_report"
        fi
    done < <(find "$target_repo_dir" -maxdepth 4 -type d -name ".git" 2>/dev/null)
    set -o pipefail

    printf '\nGit Scan Summary (%s):\n' "$target_repo_dir"
    printf '  Total Repositories Scanned : %s\n' "$total_repos"
    printf '  Repositories with Uncommitted Changes : %s\n' "$dirty_repos"
    printf '  Repositories with Unpushed Commits    : %s\n' "$unpushed_repos"
    [[ -n "$git_report" ]] && log_ok "Saved detailed git status to $git_report"
}

# =============================================================================
# MODULE 10: AUDIT SUMMARY & EXECUTIVE SCORECARD
# =============================================================================
audit_summary() {
    log_section "10" "EXECUTIVE AUDIT SUMMARY SCORECARD"

    local total_mem_kib avail_mem_kib
    total_mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    avail_mem_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

    local failed_units="0"
    if has systemctl; then
        failed_units=$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)
        failed_units="${failed_units:-0}"
    fi

    local listening_tcp="0" listening_udp="0"
    if has ss; then
        listening_tcp=$(ss -ltnH 2>/dev/null | wc -l | tr -d ' ')
        listening_udp=$(ss -lunH 2>/dev/null | wc -l | tr -d ' ')
    fi

    printf '%-25s : %s\n' "Host" "$(hostname 2>/dev/null || echo unknown)"
    printf '%-25s : %s (%s)\n' "Operating System" "$DISTRO_NAME" "$DISTRO_FAMILY"
    printf '%-25s : %s [%s] (DM: %s)\n' "Desktop Session" "$DESKTOP_ENV" "$SESSION_TYPE" "$DISPLAY_MGR"
    printf '%-25s : %s\n' "Kernel" "$(uname -r 2>/dev/null || echo unknown)"
    printf '%-25s : %s\n' "Uptime" "$(uptime -p 2>/dev/null || uptime)"
    printf '%-25s : %s\n' "CPU Cores" "$(nproc 2>/dev/null || echo unknown)"
    printf '%-25s : %s total / %s available\n' "Memory" "$(format_bytes "$((total_mem_kib * 1024))")" "$(format_bytes "$((avail_mem_kib * 1024))")"
    printf '%-25s : %s\n' "Root Filesystem" "$(df -hP / 2>/dev/null | awk 'NR==2 {print $(NF-1) " used (" $(NF-2) " available)"}')"
    printf '%-25s : %s\n' "Failed Systemd Units" "$([[ "$failed_units" == "0" ]] && echo "$failed_units" || echo "$failed_units [CRITICAL]")"
    printf '%-25s : %s TCP / %s UDP\n' "Listening Sockets" "$listening_tcp" "$listening_udp"

    local audit_end_epoch audit_duration audit_end_iso
    audit_end_epoch="$(date +%s)"
    audit_duration=$((audit_end_epoch - AUDIT_START_EPOCH))
    audit_end_iso="$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

    log_rule
    printf 'Audit Finished : %s\n' "$audit_end_iso"
    printf 'Execution Time : %s seconds\n' "$audit_duration"
    [[ -n "$OUTPUT_FILE" ]] && printf 'Report Saved   : %s\n' "$OUTPUT_FILE"
    [[ -n "$EXPORT_DIR" ]] && printf 'Exports Saved  : %s/\n' "$EXPORT_DIR"

    log_title "AUDIT COMPLETE"
}

# =============================================================================
# MAIN DISPATCHER
# =============================================================================
if ((CLEANUP_ONLY == 1)); then
    audit_junk_cleanup
    audit_summary
elif ((SECURITY_ONLY == 1)); then
    audit_security
    audit_summary
elif ((QUICK_MODE == 1)); then
    audit_system_hardware
    audit_storage
    audit_network
    audit_processes_services
    audit_security
    audit_summary
else
    # Full Comprehensive Machine Audit
    audit_system_hardware
    audit_storage
    audit_network
    audit_security
    audit_processes_services
    audit_packages
    audit_containers_virt
    audit_junk_cleanup
    audit_dev_git
    audit_summary
fi
