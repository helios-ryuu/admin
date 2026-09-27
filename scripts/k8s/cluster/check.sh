#!/usr/bin/env bash
# Kubernetes cluster inspection utility.
# Works with any cluster reachable through the current kubectl context.

set -o pipefail

# ======================== COLORS ========================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[38;5;208m'
BRIGHT_BLUE='\033[1;94m'
BOLD='\033[1m'
NC='\033[0m'

readonly SECTION_ORDER=(health object workload storage system image helm secret)
declare -A SECTION_TITLES=(
    [health]='Cluster Health'
    [object]='Cluster Objects'
    [workload]='Workloads and Services'
    [storage]='Persistent Storage'
    [system]='Host System'
    [image]='Container Images'
    [helm]='Helm'
    [secret]='Secrets'
)

# ======================== CLI ========================
usage() {
    cat <<'EOF'
Usage:
  ./check-cluster.sh get --all
  ./check-cluster.sh get -A
  ./check-cluster.sh get <section[,section...]>
  ./check-cluster.sh explain <section[,section...]>
  ./check.sh get --all
  ./check.sh get -A
  ./check.sh get <section[,section...]>
  ./check.sh explain <section[,section...]>

Sections:
  health, object, workload, storage, system, image, helm, secret

Examples:
  ./check-cluster.sh get --all
  ./check-cluster.sh get health,object
  ./check-cluster.sh explain workload,storage
  ./check.sh get --all
  ./check.sh get health,object
  ./check.sh explain workload,storage
EOF
}

die() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
    done
}

is_kubernetes_section() {
    case "$1" in
        health|object|workload|storage|image|secret) return 0 ;;
        *) return 1 ;;
    esac
}

validate_sections() {
    local requested="$1"
    local item
    local -A seen=()

    [[ -n "$requested" ]] || die "A section list is required."
    IFS=',' read -r -a SELECTED_SECTIONS <<< "$requested"
    ((${#SELECTED_SECTIONS[@]} > 0)) || die "A section list is required."

    for item in "${SELECTED_SECTIONS[@]}"; do
        [[ -n "$item" ]] || die "Section lists cannot contain empty names."
        [[ -n "${SECTION_TITLES[$item]:-}" ]] || die "Unknown section: $item"
        [[ -z "${seen[$item]:-}" ]] || die "Duplicate section: $item"
        seen[$item]=1
    done
}

select_all_sections() {
    SELECTED_SECTIONS=("${SECTION_ORDER[@]}")
}

# ======================== PRESENTATION ========================
section_header() {
    echo -e "\n${BRIGHT_BLUE}${BOLD}=== $1 ===${NC}"
}

subsection_header() {
    echo -e "\n  ${YELLOW}>> $1${NC}"
}

empty_state() {
    echo -e "     ${CYAN}($1)${NC}"
}

color_for_usage_pct() {
    local pct="${1%.*}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    if ((pct < 60)); then printf '%b' "$GREEN"
    elif ((pct < 80)); then printf '%b' "$YELLOW"
    elif ((pct < 90)); then printf '%b' "$ORANGE"
    else printf '%b' "$RED"; fi
}

color_for_health_pct() {
    local pct="${1%.*}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    if ((pct >= 90)); then printf '%b' "$GREEN"
    elif ((pct >= 75)); then printf '%b' "$YELLOW"
    elif ((pct >= 60)); then printf '%b' "$ORANGE"
    else printf '%b' "$RED"; fi
}

bar_pct() {
    local pct="${1%.*}" width="${2:-22}" mode="${3:-usage}" fill empty color i
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    fill=$((pct * width / 100))
    empty=$((width - fill))
    if [[ "$mode" == health ]]; then color=$(color_for_health_pct "$pct"); else color=$(color_for_usage_pct "$pct"); fi
    printf '%b[' "$color"
    for ((i=0; i<fill; i++)); do printf '█'; done
    for ((i=0; i<empty; i++)); do printf '░'; done
    printf ']%b %3d%%' "$NC" "$pct"
}

metric_ratio() {
    local label="$1" good="$2" total="$3" suffix="$4" pct=0
    ((total > 0)) && pct=$((good * 100 / total))
    printf "  ${CYAN}%-18s${NC} %b  %s/%s %s\n" "$label" "$(bar_pct "$pct" 22 health)" "$good" "$total" "$suffix"
}

print_namespace_table() {
    local data="$1" header="$2" group_indent="${3:-     }" row_indent="${4:-        }"
    local rows namespaces ns
    rows=$(printf '%b' "$data" | awk 'NF {print}')
    [[ -n "$rows" ]] || return
    namespaces=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $1 != "" {print $1}' | sort -u)
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        echo -e "${group_indent}${ORANGE}>> $ns${NC}"
        (
            echo -e "${YELLOW}${header}${NC}"
            printf '%s\n' "$rows" | awk -F'\t' -v selected_ns="$ns" 'BEGIN { OFS="\t" } $1 == selected_ns {$1=""; sub(/^\t/, ""); print}'
        ) | column -t -s $'\t' | sed "s/^/${row_indent}/"
    done <<< "$namespaces"
}

print_simple_table() {
    local data="$1" header="$2" indent="${3:-     }"
    [[ -n "$(printf '%b' "$data" | awk 'NF {print; exit}')" ]] || return 1
    (
        echo -e "${YELLOW}${header}${NC}"
        printf '%b' "$data"
    ) | column -t -s $'\t' | sed "s/^/${indent}/"
}

# ======================== KUBERNETES CACHE ========================
KUBE_CONNECTION_CHECKED=false
declare -A CACHE_LOADED=()
declare -A CACHE_JSON=()

check_kubernetes_connection() {
    "$KUBE_CONNECTION_CHECKED" && return
    require_commands kubectl jq awk column
    if ! kubectl cluster-info >/dev/null 2>&1; then
        die "Cannot connect to the Kubernetes API. Check your kubeconfig, current context, and cluster availability."
    fi
    KUBE_CONNECTION_CHECKED=true
}

load_resource() {
    local key="$1" resource="$2"
    [[ -n "${CACHE_LOADED[$key]:-}" ]] && return
    check_kubernetes_connection
    CACHE_JSON[$key]=$(kubectl get "$resource" -A -o json 2>/dev/null) || die "Unable to read Kubernetes resource: $resource"
    echo "${CACHE_JSON[$key]}" | jq -e '.items | type == "array"' >/dev/null 2>&1 || die "Kubernetes returned invalid data for: $resource"
    CACHE_LOADED[$key]=1
}

nodes_json() { load_resource nodes nodes; printf '%s' "${CACHE_JSON[nodes]}"; }
pods_json() { load_resource pods pods; printf '%s' "${CACHE_JSON[pods]}"; }
pvc_json() { load_resource pvc pvc; printf '%s' "${CACHE_JSON[pvc]}"; }
workloads_json() { load_resource workloads 'deploy,sts,ds'; printf '%s' "${CACHE_JSON[workloads]}"; }
services_json() { load_resource services svc; printf '%s' "${CACHE_JSON[services]}"; }
hpa_json() { load_resource hpa hpa; printf '%s' "${CACHE_JSON[hpa]}"; }
secrets_json() { load_resource secrets secrets; printf '%s' "${CACHE_JSON[secrets]}"; }

sorted_nodes() {
    nodes_json | jq -r '
        .items[] |
        (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "1_control-plane" else "2_worker" end) as $role |
        [$role, .metadata.name] | @tsv
    ' | sort -k1,1 -k2,2 | cut -f2
}

all_pods() {
    pods_json | jq -r '
        .items[] |
        (.spec.nodeName // "<unscheduled>") as $node |
        .metadata.namespace as $namespace |
        .metadata.name as $name |
        (((.status.containerStatuses // []) | map(select(.ready == true)) | length | tostring) + "/" + ((.spec.containers // []) | length | tostring)) as $ready |
        (if .metadata.deletionTimestamp != null then "Terminating"
         elif ((.status.containerStatuses // []) | map(.state.waiting.reason // empty) | first // null) != null then ((.status.containerStatuses // []) | map(.state.waiting.reason // empty) | first)
         else (.status.phase // "Unknown") end) as $status |
        (((.status.containerStatuses // []) | map(.restartCount // 0) | add // 0) | tostring) as $restarts |
        (now - (.metadata.creationTimestamp | fromdateiso8601)) as $age_seconds |
        (if $age_seconds < 60 then "\($age_seconds | floor)s"
         elif $age_seconds < 3600 then "\($age_seconds / 60 | floor)m"
         elif $age_seconds < 86400 then "\($age_seconds / 3600 | floor)h"
         else "\($age_seconds / 86400 | floor)d" end) as $age |
        [$node, $namespace, $name, $ready, $status, $restarts, $age] | @tsv
    ' | sort -k1,1 -k2,2 -k3,3
}

# ======================== SECTIONS ========================
section_health() {
    section_header "HEALTH — ${SECTION_TITLES[health]}"
    local nodes pods pvcs workloads pods_data
    load_resource nodes nodes
    load_resource pods pods
    load_resource pvc pvc
    load_resource workloads 'deploy,sts,ds'
    nodes="${CACHE_JSON[nodes]}"
    pods="${CACHE_JSON[pods]}"
    pvcs="${CACHE_JSON[pvc]}"
    workloads="${CACHE_JSON[workloads]}"
    pods_data=$(all_pods)

    local nodes_total nodes_ready pods_total pods_healthy pods_problem restarts pvc_total pvc_bound workloads_total workloads_ready
    nodes_total=$(echo "$nodes" | jq '.items | length')
    nodes_ready=$(echo "$nodes" | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    pods_total=$(echo "$pods" | jq '.items | length')
    pods_healthy=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Running" or .status.phase == "Succeeded")] | length')
    pods_problem=$(echo "$pods" | jq '[.items[] | select(.metadata.deletionTimestamp != null or (.status.phase != "Running" and .status.phase != "Succeeded") or (((.status.containerStatuses // []) | map(.state.waiting.reason // empty) | length) > 0))] | length')
    restarts=$(echo "$pods" | jq '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0')
    pvc_total=$(echo "$pvcs" | jq '.items | length')
    pvc_bound=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Bound")] | length')
    workloads_total=$(echo "$workloads" | jq '[.items[] | select(.metadata.namespace != "kube-system")] | length')
    workloads_ready=$(echo "$workloads" | jq '[.items[] | select(.metadata.namespace != "kube-system") | select((.kind == "Deployment" and ((.spec.replicas // 0) == 0 or (.status.readyReplicas // 0) >= (.spec.replicas // 0))) or (.kind == "StatefulSet" and ((.spec.replicas // 0) == 0 or (.status.readyReplicas // 0) >= (.spec.replicas // 0))) or (.kind == "DaemonSet" and ((.status.desiredNumberScheduled // 0) == 0 or (.status.numberReady // 0) >= (.status.desiredNumberScheduled // 0))))] | length')

    subsection_header 'HEALTH SUMMARY'
    metric_ratio 'Nodes Ready' "$nodes_ready" "$nodes_total" 'Ready'
    metric_ratio 'Healthy Pods' "$pods_healthy" "$pods_total" 'Running/Succeeded'
    metric_ratio 'PVCs Bound' "$pvc_bound" "$pvc_total" 'Bound'
    metric_ratio 'Ready Workloads' "$workloads_ready" "$workloads_total" 'Available'
    printf "  ${CYAN}%-18s${NC} %b%d%b\n" 'Problem Pods' "$([[ "$pods_problem" -gt 0 ]] && printf '%b' "$RED" || printf '%b' "$GREEN")" "$pods_problem" "$NC"
    printf "  ${CYAN}%-18s${NC} %b%d%b\n" 'Container Restarts' "$([[ "$restarts" -gt 0 ]] && printf '%b' "$ORANGE" || printf '%b' "$GREEN")" "$restarts" "$NC"

    subsection_header 'POD DENSITY BY NODE'
    local node max_pods count
    max_pods=$(echo "$pods_data" | awk -F'\t' '$1 != "<unscheduled>" {count[$1]++} END {max=0; for (node in count) if (count[node] > max) max=count[node]; print max+0}')
    while IFS= read -r node; do
        count=$(echo "$pods_data" | awk -F'\t' -v node="$node" '$1 == node {count++} END {print count+0}')
        printf "  ${CYAN}%-18s${NC} %b  %d pods\n" "$node" "$(bar_pct "$((max_pods > 0 ? count * 100 / max_pods : 0))" 22)" "$count"
    done < <(sorted_nodes)

    subsection_header 'ATTENTION ITEMS'
    local hot_list
    hot_list=$(echo "$pods_data" | awk -F'\t' '($5 != "Running" && $5 != "Succeeded") || ($6+0 > 0) {print $2 "\t" $3 "\t" $1 "\t" $4 "\t" $5 "\t" $6 "\t" $7}' | head -12)
    if [[ -z "$hot_list" ]]; then
        empty_state 'No unhealthy pods or container restarts found.'
    else
        print_namespace_table "$hot_list" $'POD\tNODE\tREADY\tSTATUS\tRESTARTS\tAGE'
    fi
}

section_object() {
    section_header "OBJECT — ${SECTION_TITLES[object]}"
    local nodes pods_data node node_info role ready version addresses namespaces status_color role_color
    load_resource nodes nodes
    load_resource pods pods
    nodes="${CACHE_JSON[nodes]}"
    pods_data=$(all_pods)

    subsection_header 'NODES'
    local node_rows=''
    while IFS= read -r node; do
        node_info=$(echo "$nodes" | jq -r --arg node "$node" '
            .items[] | select(.metadata.name == $node) |
            (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "control-plane" else "worker" end) as $role |
            ([.status.conditions[]? | select(.type == "Ready") | .status] | first // "Unknown") as $ready |
            (.status.nodeInfo.kubeletVersion // "-") as $version |
            ([.status.addresses[]? | select(.type == "InternalIP") | .address] | first // ([.status.addresses[]?.address] | first // "-")) as $address |
            [$role, $ready, $version, $address] | @tsv
        ')
        role=$(cut -f1 <<< "$node_info"); ready=$(cut -f2 <<< "$node_info"); version=$(cut -f3 <<< "$node_info"); addresses=$(cut -f4 <<< "$node_info")
        namespaces=$(echo "$pods_data" | awk -F'\t' -v node="$node" '$1 == node {count[$2]++} END {for (ns in count) printf "%s(%d) ", ns, count[ns]}' | sed 's/ $//')
        [[ -n "$namespaces" ]] || namespaces='-'
        [[ "$ready" == True ]] && status_color="$GREEN" || status_color="$RED"
        [[ "$role" == control-plane ]] && role_color="$PURPLE" || role_color="$ORANGE"
        node_rows+="$node\t${status_color}$([[ "$ready" == True ]] && echo Ready || echo NotReady)${NC}\t${role_color}${role}${NC}\t${version}\t${addresses}\t${namespaces}\n"
    done < <(sorted_nodes)
    print_simple_table "$node_rows" $'NODE\tSTATUS\tROLE\tKUBELET\tADDRESS\tNAMESPACES'

    subsection_header 'PODS BY NODE'
    while IFS= read -r node; do
        echo -e "     ${ORANGE}>> $node${NC}"
        local node_pods
        node_pods=$(echo "$pods_data" | awk -F'\t' -v node="$node" '$1 == node {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7}')
        if [[ -z "$node_pods" ]]; then empty_state 'No pods scheduled.'; else print_namespace_table "$node_pods" $'NAME\tREADY\tSTATUS\tRESTARTS\tAGE' '        ' '             '; fi
    done < <(sorted_nodes)
}

section_workload() {
    section_header "WORKLOAD — ${SECTION_TITLES[workload]}"
    local data
    load_resource workloads 'deploy,sts,ds'
    load_resource hpa hpa
    load_resource services svc
    subsection_header 'WORKLOADS'
    data=$(workloads_json | jq -r '
        .items[] | select(.metadata.namespace != "kube-system") |
        .metadata.namespace as $ns | .kind as $kind |
        (if $kind == "Deployment" then [$ns, "Deployment", .metadata.name, (.spec.replicas // 0), (.status.readyReplicas // 0), (.status.updatedReplicas // 0), (.status.availableReplicas // 0)]
         elif $kind == "StatefulSet" then [$ns, "StatefulSet", .metadata.name, (.spec.replicas // 0), (.status.readyReplicas // 0), (.status.updatedReplicas // 0), (.status.availableReplicas // 0)]
         elif $kind == "DaemonSet" then [$ns, "DaemonSet", .metadata.name, (.status.desiredNumberScheduled // 0), (.status.numberReady // 0), (.status.updatedNumberScheduled // 0), (.status.numberAvailable // 0)]
         else empty end) | @tsv
    ' | sort -k1,1 -k2,2 -k3,3)
    if [[ -z "$data" ]]; then empty_state 'No workloads found outside kube-system.'; else print_namespace_table "$data" $'KIND\tNAME\tDESIRED\tREADY\tUP-TO-DATE\tAVAILABLE'; fi

    subsection_header 'AUTOSCALING (HPA)'
    data=$(hpa_json | jq -r '
        .items[] | select(.metadata.namespace != "kube-system") |
        [.metadata.namespace, .metadata.name, "\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)", "\(.spec.minReplicas // 1) -> \(.spec.maxReplicas)", "\(.status.currentReplicas // 0)/\(.status.desiredReplicas // 0)"] | @tsv
    ' | sort -k1,1 -k2,2)
    if [[ -z "$data" ]]; then empty_state 'No HorizontalPodAutoscalers configured.'; else print_namespace_table "$data" $'HPA\tTARGET\tMIN -> MAX\tCURRENT/DESIRED'; fi

    subsection_header 'SERVICES'
    data=$(services_json | jq -r '
        .items[] | select(.metadata.namespace != "kube-system" and .metadata.name != "kubernetes") |
        [.metadata.namespace, .metadata.name, (.spec.type // "-"), (.spec.clusterIP // "-"), ([.spec.ports[]? | "\(.port)/\(.protocol)"] | join(", "))] | @tsv
    ' | sort -k1,1 -k2,2)
    if [[ -z "$data" ]]; then empty_state 'No services found outside kube-system.'; else print_namespace_table "$data" $'NAME\tTYPE\tCLUSTER-IP\tPORTS'; fi
}

section_storage() {
    section_header "STORAGE — ${SECTION_TITLES[storage]}"
    local claims mounts node node_claims
    load_resource pvc pvc
    load_resource pods pods
    load_resource nodes nodes
    claims=$(printf '%s' "${CACHE_JSON[pvc]}" | jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.phase // "Unknown"), (.status.capacity.storage // "-")] | @tsv' | sort -k1,1 -k2,2)
    mounts=$(printf '%s' "${CACHE_JSON[pods]}" | jq -r '.items[] | .spec.nodeName as $node | .metadata.namespace as $namespace | (.spec.volumes[]? | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName) as $claim | select($claim != null and $node != null) | [$namespace, $claim, $node] | @tsv' | sort -u)

    subsection_header 'PERSISTENT VOLUME CLAIMS BY NODE'
    while IFS= read -r node; do
        echo -e "     ${ORANGE}>> $node${NC}"
        node_claims=$(awk -F'\t' -v node="$node" 'NR == FNR {owner[$1 FS $2] = $3; next} owner[$1 FS $2] == node {print}' <(printf '%s\n' "$mounts") <(printf '%s\n' "$claims"))
        if [[ -z "$node_claims" ]]; then empty_state 'No mounted PVCs.'; else print_namespace_table "$node_claims" $'NAME\tSTATUS\tSIZE' '        ' '             '; fi
    done < <(sorted_nodes)

    local unmounted
    unmounted=$(awk -F'\t' 'NR == FNR {mounted[$1 FS $2] = 1; next} !mounted[$1 FS $2] {print}' <(printf '%s\n' "$mounts") <(printf '%s\n' "$claims"))
    if [[ -n "$unmounted" ]]; then
        subsection_header 'UNMOUNTED CLAIMS'
        print_namespace_table "$unmounted" $'NAME\tSTATUS\tSIZE'
    fi
}

section_system() {
    section_header "SYSTEM — ${SECTION_TITLES[system]}"
    local cores load1 load5 load15 load_pct ram_used ram_total ram_pct swap_used swap_total swap_pct disk_used disk_total disk_pct uptime_text
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    uptime_text=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo '-')
    printf "  ${CYAN}%-14s${NC} %s\n" 'Hostname:' "$(hostname)"
    printf "  ${CYAN}%-14s${NC} %s\n" 'Kernel:' "$(uname -r)"
    printf "  ${CYAN}%-14s${NC} %s\n" 'Uptime:' "$uptime_text"
    printf "  ${CYAN}%-14s${NC} %s cores\n" 'CPU:' "$cores"
    read -r load1 load5 load15 < <(uptime | awk -F'load average:' 'NF > 1 {gsub(",", "", $2); print $2}' | awk '{print $1, $2, $3}')
    load1=${load1:-0}; load5=${load5:-0}; load15=${load15:-0}
    load_pct=$(awk -v one_minute_load="$load1" -v cores="$cores" 'BEGIN {if (cores < 1) cores=1; printf "%d", one_minute_load * 100 / cores}')
    printf "  ${CYAN}%-14s${NC} %b  %s / %s / %s\n" 'Load average:' "$(bar_pct "$load_pct" 22)" "$load1" "$load5" "$load15"

    if command -v free >/dev/null 2>&1; then
        read -r ram_used ram_total ram_pct < <(free -m | awk 'NR == 2 {printf "%d %d %d", $3, $2, ($2 ? $3 * 100 / $2 : 0)}')
        read -r swap_used swap_total swap_pct < <(free -m | awk 'NR == 3 {printf "%d %d %d", $3, $2, ($2 ? $3 * 100 / $2 : 0)}')
        printf "  ${CYAN}%-14s${NC} %b  %s/%s MiB\n" 'Memory:' "$(bar_pct "$ram_pct" 22)" "$ram_used" "$ram_total"
        if ((swap_total > 0)); then printf "  ${CYAN}%-14s${NC} %b  %s/%s MiB\n" 'Swap:' "$(bar_pct "$swap_pct" 22)" "$swap_used" "$swap_total"; else printf "  ${CYAN}%-14s${NC} ${GREEN}disabled${NC}\n" 'Swap:'; fi
    else
        printf "  ${CYAN}%-14s${NC} ${ORANGE}unavailable${NC}\n" 'Memory:'
    fi
    read -r disk_used disk_total disk_pct < <(df -hP / | awk 'NR == 2 {pct=$(NF-1); gsub("%", "", pct); print $(NF-3), $(NF-4), pct}')
    printf "  ${CYAN}%-14s${NC} %b  %s/%s\n" 'Root disk:' "$(bar_pct "$disk_pct" 22)" "$disk_used" "$disk_total"
}

section_image() {
    section_header "IMAGE — ${SECTION_TITLES[image]}"
    local nodes pods images node node_images image_data
    load_resource nodes nodes
    load_resource pods pods
    nodes="${CACHE_JSON[nodes]}"; pods="${CACHE_JSON[pods]}"
    image_data=$(echo "$pods" | jq -r '.items[] | .spec.nodeName as $node | .metadata.name as $pod | (.spec.containers[]?, .spec.initContainers[]?) | [$node, .image, $pod] | @tsv' | sort -u)
    subsection_header 'IMAGES BY NODE'
    while IFS= read -r node; do
        echo -e "     ${ORANGE}>> $node${NC}"
        node_images=$(echo "$nodes" | jq -r --arg node "$node" '.items[] | select(.metadata.name == $node) | .status.images[]? | [(.names[0] // "-"), ((.sizeBytes // 0) | tostring)] | @tsv' | sort -u)
        if [[ -z "$node_images" ]]; then empty_state 'No image inventory reported by the kubelet.'; continue; fi
        images=''
        while IFS=$'\t' read -r image size; do
            [[ -n "$image" ]] || continue
            local using size_gib state
            using=$(echo "$image_data" | awk -F'\t' -v node="$node" -v image="$image" '$1 == node && $2 == image {print $3}' | paste -sd ',' -)
            size_gib=$(awk -v bytes="$size" 'BEGIN {printf "%.2f GiB", bytes / 1073741824}')
            [[ -n "$using" ]] && state="${GREEN}In use${NC} (${using})" || state="${ORANGE}Cached only${NC}"
            images+="${image}\t${size_gib}\t${state}\n"
        done <<< "$node_images"
        print_simple_table "$images" $'IMAGE\tSIZE\tSTATUS' '        '
    done < <(sorted_nodes)
}

section_helm() {
    section_header "HELM — ${SECTION_TITLES[helm]}"
    require_commands jq column
    if ! command -v helm >/dev/null 2>&1; then
        empty_state 'Helm is not installed on this host.'
        return
    fi
    local releases repositories
    subsection_header 'RELEASES'
    releases=$(helm list -A -o json 2>/dev/null) || die 'Unable to read Helm releases.'
    if [[ "$(echo "$releases" | jq 'length' 2>/dev/null)" == 0 ]]; then
        empty_state 'No Helm releases found.'
    else
        releases=$(echo "$releases" | jq -r '.[] | [.namespace, .name, (.revision | tostring), (.updated | split(".")[0] | sub("T"; " ")), .status, .chart, .app_version] | @tsv' | sort -k1,1 -k2,2)
        print_namespace_table "$releases" $'NAME\tREVISION\tUPDATED\tSTATUS\tCHART\tAPP VERSION'
    fi
    subsection_header 'REPOSITORIES'
    repositories=$(helm repo list -o json 2>/dev/null) || die 'Unable to read Helm repositories.'
    if [[ "$(echo "$repositories" | jq 'length' 2>/dev/null)" == 0 ]]; then
        empty_state 'No Helm repositories configured.'
    else
        repositories=$(echo "$repositories" | jq -r '.[] | [.name, .url] | @tsv' | sort)
        print_simple_table "$repositories" $'NAME\tURL'
    fi
}

section_secret() {
    section_header "SECRET — ${SECTION_TITLES[secret]}"
    local data
    load_resource secrets secrets
    data=$(printf '%s' "${CACHE_JSON[secrets]}" | jq -r '.items[] | select(.type != "kubernetes.io/service-account-token" and .metadata.namespace != "kube-system") | [.metadata.namespace, .metadata.name, .type, ((.data // {}) | keys | join(", "))] | @tsv' | sort -k1,1 -k2,2)
    subsection_header 'SECRET METADATA'
    if [[ -z "$data" ]]; then empty_state 'No non-service-account secrets found outside kube-system.'; else print_namespace_table "$data" $'NAME\tTYPE\tKEYS'; fi
}

# ======================== STATIC LEGENDS ========================
legend_item() { printf "  ${CYAN}%-20s${NC} %s\n" "$1" "$2"; }

explain_health() {
    subsection_header 'HEALTH LEGEND'
    legend_item 'Nodes Ready' 'Nodes whose Ready condition is True.'
    legend_item 'Healthy Pods' 'Pods in Running or Succeeded phase.'
    legend_item 'PVCs Bound' 'PersistentVolumeClaims successfully bound to a volume.'
    legend_item 'Ready Workloads' 'Workloads with the required replicas available.'
    legend_item 'Problem Pods' 'Pods not healthy, terminating, or waiting on a container error.'
}
explain_object() { subsection_header 'OBJECT LEGEND'; legend_item 'ADDRESS' 'The node InternalIP when available, otherwise another Kubernetes-reported address.'; legend_item 'READY' 'Ready containers divided by total containers in a pod.'; legend_item 'RESTARTS' 'Total container restart count for the pod.'; }
explain_workload() { subsection_header 'WORKLOAD LEGEND'; legend_item 'DESIRED' 'Replica count requested by the workload specification.'; legend_item 'UP-TO-DATE' 'Replicas using the current workload revision.'; legend_item 'AVAILABLE' 'Replicas available to serve traffic.'; legend_item 'HPA' 'HorizontalPodAutoscaler replica limits and current target.'; }
explain_storage() { subsection_header 'STORAGE LEGEND'; legend_item 'PVC' 'PersistentVolumeClaim: a request for persistent storage.'; legend_item 'Mounted PVCs' 'Claims referenced by pods scheduled on the shown node.'; legend_item 'Unmounted Claims' 'Claims not referenced by a currently scheduled pod.'; }
explain_system() { subsection_header 'SYSTEM LEGEND'; legend_item 'Load average' 'Average runnable work over 1, 5, and 15 minutes, relative to CPU core count.'; legend_item 'Memory / disk' 'Resources on the host running this script, not cluster-wide usage.'; }
explain_image() { subsection_header 'IMAGE LEGEND'; legend_item 'In use' 'An image referenced by a pod currently scheduled on that node.'; legend_item 'Cached only' 'An image reported by the kubelet but not referenced by a current pod.'; }
explain_helm() { subsection_header 'HELM LEGEND'; legend_item 'Release' 'An installed instance of a Helm chart.'; legend_item 'Revision' 'Release version after installs, upgrades, or rollbacks.'; legend_item 'Repository' 'A Helm chart source configured on this host.'; }
explain_secret() { subsection_header 'SECRET LEGEND'; legend_item 'Keys' 'Data key names only; secret values are never printed.'; legend_item 'Type' 'Kubernetes Secret type used to describe its intended format.'; }

run_section() { "section_$1"; }
run_explanation() { section_header "EXPLAIN — ${SECTION_TITLES[$1]}"; "explain_$1"; }

main() {
    local action="${1:-}" argument="${2:-}"
    case "$action" in
        -h|--help|help) [[ $# -eq 1 ]] || die 'Help does not accept additional arguments.'; usage; return ;;
        get)
            [[ $# -eq 2 ]] || die 'Use get with --all, -A, or one comma-separated section list.'
            case "$argument" in
                --all|-A) select_all_sections ;;
                -*) die "Unsupported get option: $argument" ;;
                *) validate_sections "$argument" ;;
            esac
            local section
            for section in "${SELECTED_SECTIONS[@]}"; do run_section "$section"; done
            ;;
        explain)
            [[ $# -eq 2 ]] || die 'Use explain with one comma-separated section list.'
            [[ "$argument" != -* ]] || die "Unsupported explain option: $argument"
            validate_sections "$argument"
            local section
            for section in "${SELECTED_SECTIONS[@]}"; do run_explanation "$section"; done
            ;;
        '') usage; exit 1 ;;
        *) die "Unknown command: $action. Use ./check-cluster.sh --help for usage." ;;
    esac
}

main "$@"
