#!/bin/bash
VERSION="NetCoreOS 0.1 BETA"
AUTHOR="Silent Cell"
BASE_DIR="/var/lib/netcoreos"
CONFIGS_DIR="$BASE_DIR/configs"
BR="br0"
MODE="ncos"
WAN_IF="eth0"
WEBEXEC_MODE=0
START_TIME=$(date +%s)
ROUTES_FILE="$BASE_DIR/netcoreos_routes.list"
FW_CHAIN="SILENTOS"
DNSMASQ_PIDS_FILE="$BASE_DIR/dnsmasq_pids.list"
SUBIFS_FILE="$BASE_DIR/subifs.list"
BONDS_FILE="$BASE_DIR/bonds.list"
BRIDGE_MEMBERS_FILE="$BASE_DIR/bridge_members.list"
VXLANS_FILE="$BASE_DIR/vxlans.list"
MIRRORS_FILE="$BASE_DIR/mirrors.list"
MONITORS_FILE="$BASE_DIR/monitors.list"
QOS_FILE="$BASE_DIR/qos.list"
ALIASES_FILE="$BASE_DIR/aliases.cfg"
LOG_FILE="$BASE_DIR/netcoreos.log"
HISTORY_FILE="$BASE_DIR/.netcoreos_history"
BACKUPS_DIR="$BASE_DIR/backups"
SCHEDULES_FILE="$BASE_DIR/schedules.list"
WEB_STATE_FILE="$BASE_DIR/webui_state.env"
GUARDS_PIDS_FILE="$BASE_DIR/guards_pids.list"
ERRDIS_PIDS_FILE="$BASE_DIR/errdis_pids.list"
PORTFWD_FILE="$BASE_DIR/portfwd.list"
WG_FILE="$BASE_DIR/wireguard.list"
BLOCKED_IPS_FILE="$BASE_DIR/blocked_ips.list"
GRE_FILE="$BASE_DIR/gre.list"
IPSEC_FILE="$BASE_DIR/ipsec.list"
OPEN_PORTS_FILE="$BASE_DIR/open_ports.list"
PORTSEC_FILE="$BASE_DIR/portsec.list"
VRFS_FILE="$BASE_DIR/vrfs.list"
PASS_FILE="$BASE_DIR/ncos.passwd"
RESCUE_USER="ncos-rescue"
DESC_FILE="$BASE_DIR/if-descriptions.list"
ACLV2_FILE="$BASE_DIR/acl_rules.list"
CONSOLE_SHELLS_FILE="$BASE_DIR/console_orig_shells.list"
FRR_DAEMONS="/etc/frr/daemons"
FRR_CONF="/etc/frr/frr.conf"
BGP_FILE="$BASE_DIR/bgp.conf"
OSPF_FILE="$BASE_DIR/ospf.conf"
VRRP_FILE="$BASE_DIR/vrrp.list"
ROUTEMAP_FILE="$BASE_DIR/routemaps.list"
PREFIXLIST_FILE="$BASE_DIR/prefixlists.list"
BFD_FILE="$BASE_DIR/bfd.list"
mkdir -p "$BASE_DIR" "$CONFIGS_DIR" "$BACKUPS_DIR"
touch "$ROUTES_FILE" "$DNSMASQ_PIDS_FILE" "$SUBIFS_FILE" \
      "$BONDS_FILE" "$BRIDGE_MEMBERS_FILE" "$VXLANS_FILE" "$MIRRORS_FILE" \
      "$MONITORS_FILE" "$QOS_FILE" "$ALIASES_FILE" "$SCHEDULES_FILE" \
      "$LOG_FILE" "$HISTORY_FILE" \
      "$BGP_FILE" "$OSPF_FILE" "$VRRP_FILE" "$ROUTEMAP_FILE" \
      "$PREFIXLIST_FILE" "$BFD_FILE" \
      "$GUARDS_PIDS_FILE" "$ERRDIS_PIDS_FILE" \
      "$PORTFWD_FILE" "$WG_FILE" \
      "$BLOCKED_IPS_FILE" "$GRE_FILE" "$IPSEC_FILE" "$OPEN_PORTS_FILE" \
      "$PORTSEC_FILE" "$VRFS_FILE" "$DESC_FILE" "$ACLV2_FILE" "$CONSOLE_SHELLS_FILE"
_load_web_state() {
    # Only source the shared state file if it is valid, parseable bash.
    # Multiple ncos instances (one per tty, plus --web-exec calls from the
    # web UI) read/write this file, so a corrupted/partial write must never
    # be blindly sourced into a live shell.
    [[ -f "$WEB_STATE_FILE" ]] || return 0
    bash -n "$WEB_STATE_FILE" 2>/dev/null && source "$WEB_STATE_FILE" 2>/dev/null
}
_save_web_state() {
    # Atomic, lock-protected write: write to a temp file then rename, and
    # serialize concurrent writers with flock so simultaneous instances on
    # different ttys / web-exec calls can never interleave or truncate
    # each other's writes.
    local LOCK="${WEB_STATE_FILE}.lock"
    (
        flock -w 2 200 || exit 0
        printf "MODE=%s\nBR=%s\nWAN_IF=%s\n" "$MODE" "$BR" "$WAN_IF" > "${WEB_STATE_FILE}.tmp" 2>/dev/null \
            && mv -f "${WEB_STATE_FILE}.tmp" "$WEB_STATE_FILE" 2>/dev/null
    ) 200>"$LOCK" 2>/dev/null
}
_load_web_state
RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
CYAN='\033[0;36m';   BLUE='\033[0;34m';    MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';        NC='\033[0m'
KERNEL_VER=$(uname -r 2>/dev/null || echo 'unknown')
log() {
    local LEVEL="$1"; shift
    local MSG="$*"
    local TS; TS=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TS] [$LEVEL] $MSG" >> "$LOG_FILE"
    case "$LEVEL" in
        INFO)  echo -e "${GREEN}[+]${NC} $MSG" ;;
        WARN)  echo -e "${YELLOW}[!]${NC} $MSG" ;;
        ERROR) echo -e "${RED}[-]${NC} $MSG" ;;
        CMD)   echo -e "${CYAN}[>]${NC} $MSG" ;;
        OK)    echo -e "${BOLD}${GREEN}[✔]${NC} $MSG" ;;
    esac
}
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[Error]${NC} NetCoreOS must be run as root."
    exit 1
fi
check_deps() {
    local MISSING=()
    local DEPS=(ip bridge iptables dnsmasq tcpdump sysctl tc tput)
    for dep in "${DEPS[@]}"; do
        command -v "$dep" &>/dev/null || MISSING+=("$dep")
    done
    [[ ${#MISSING[@]} -gt 0 ]] \
        && log WARN "Missing tools: ${MISSING[*]} — some features may not work." \
        || log OK "All core dependencies present."
}
_mstpd_check() {
    if ! command -v mstpctl &>/dev/null; then
        log ERROR "mstpd/mstpctl not installed — rstp/mstp/portfast unavailable."
        log INFO  "Install: apt install mstpd"
        return 1
    fi
    return 0
}
_ebtables_check() {
    if ! command -v ebtables &>/dev/null; then
        log ERROR "ebtables not installed — port-security unavailable."
        log INFO  "Install: apt install ebtables"
        return 1
    fi
    return 0
}
_lldpd_check() {
    if ! command -v lldpcli &>/dev/null; then
        log ERROR "lldpd not installed — lldp/neighbor discovery unavailable."
        log INFO  "Install: apt install lldpd"
        return 1
    fi
    return 0
}
_password_new_salt() { head -c16 /dev/urandom | sha256sum | awk '{print $1}' | head -c16; }
_password_hash()     { printf '%s' "${2}${1}" | sha256sum | awk '{print $1}'; }
_init_password() {
    if [[ ! -f "$PASS_FILE" ]]; then
        local SALT; SALT=$(_password_new_salt)
        echo "${SALT}:$(_password_hash "ncos" "$SALT")" > "$PASS_FILE"
        chmod 600 "$PASS_FILE"
        log WARN "Default NCOS password is 'ncos' — change it: change password"
    fi
}
_password_verify() {
    local ATTEMPT="$1"
    local STORED; STORED=$(cat "$PASS_FILE" 2>/dev/null)
    [[ -z "$STORED" ]] && return 1
    if [[ "$STORED" == *:* ]]; then
        local SALT="${STORED%%:*}" HASH="${STORED#*:}"
        [[ "$(_password_hash "$ATTEMPT" "$SALT")" == "$HASH" ]]
    else
        [[ "$(printf '%s' "$ATTEMPT" | sha256sum | awk '{print $1}')" == "$STORED" ]]
    fi
}
_login_gate() {
    [[ -f "$PASS_FILE" ]] || _init_password
    local TRIES=0 LOCKOUT=5
    while true; do
        local ENTERED
        read -r -s -p "Password: " ENTERED; echo
        _password_verify "$ENTERED" && return 0
        (( TRIES++ ))
        log ERROR "Access denied."
        if (( TRIES >= 4 )); then
            echo -e "${RED}Too many failed attempts. Locked for ${LOCKOUT}s.${NC}"
            sleep "$LOCKOUT"
            LOCKOUT=$(( LOCKOUT + 5 ))
            TRIES=3
        fi
    done
}
_change_password() {
    [[ -f "$PASS_FILE" ]] || _init_password
    local CUR NEW1 NEW2 TRIES=0 LOCKOUT=5
    while true; do
        read -r -s -p "Current password: " CUR; echo
        _password_verify "$CUR" && break
        (( TRIES++ ))
        log ERROR "Current password incorrect."
        if (( TRIES >= 4 )); then
            echo -e "${RED}Too many failed attempts. Locked for ${LOCKOUT}s.${NC}"
            sleep "$LOCKOUT"
            LOCKOUT=$(( LOCKOUT + 5 ))
            TRIES=3
        fi
    done
    read -r -s -p "New password: " NEW1; echo
    read -r -s -p "Confirm new password: " NEW2; echo
    if [[ -z "$NEW1" ]]; then
        log ERROR "Password cannot be empty."; return 1
    fi
    if [[ "$NEW1" != "$NEW2" ]]; then
        log ERROR "Passwords do not match."; return 1
    fi
    local SALT; SALT=$(_password_new_salt)
    echo "${SALT}:$(_password_hash "$NEW1" "$SALT")" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    if echo "root:${NEW1}" | chpasswd 2>/dev/null; then
        log OK "Password changed (NCOS console + root's Linux/SSH password)."
    else
        log OK "NCOS password changed."
        log WARN "Could not update root's Linux password to match — SSH still uses the old one. Run 'passwd root' to sync it manually."
    fi
}
validate_iface() {
    local IFACE="$1"
    if [[ "$IFACE" =~ [^a-zA-Z0-9._:-] ]]; then
        log ERROR "Interface name '$IFACE' contains illegal characters."
        return 1
    fi
    if ! ip link show "$IFACE" &>/dev/null; then
        log ERROR "Interface '$IFACE' does not exist."
        return 1
    fi
    return 0
}
validate_vlan() {
    local VLAN="$1"
    if ! [[ "$VLAN" =~ ^[0-9]+$ ]] || (( VLAN < 1 || VLAN > 4094 )); then
        log ERROR "Invalid VLAN ID '$VLAN'. Must be 1–4094."
        return 1
    fi
    return 0
}
validate_ip() {
    local RAW="$1"
    local IP="${RAW%%/*}"
    local PREFIX="${RAW##*/}"
    local OCTETS
    IFS='.' read -ra OCTETS <<< "$IP"
    if [[ ${#OCTETS[@]} -ne 4 ]]; then
        log ERROR "Invalid IP: '$RAW'"; return 1
    fi
    for OCT in "${OCTETS[@]}"; do
        if ! [[ "$OCT" =~ ^[0-9]+$ ]] || (( OCT < 0 || OCT > 255 )); then
            log ERROR "Invalid IP octet '$OCT' in '$RAW'"; return 1
        fi
    done
    if [[ "$RAW" == */* ]]; then
        if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || (( PREFIX < 0 || PREFIX > 32 )); then
            log ERROR "Invalid prefix length '$PREFIX' in '$RAW'"; return 1
        fi
    fi
    return 0
}
validate_cidr() {
    local RAW="$1"
    if [[ "$RAW" != */* ]]; then
        log ERROR "Expected CIDR notation (e.g. 10.0.0.1/24), got '$RAW'"
        return 1
    fi
    validate_ip "$RAW"
}
validate_ip6() {
    local RAW="$1"
    local ADDR="${RAW%%/*}"
    local PREFIX="${RAW##*/}"
    if [[ "$RAW" == */* ]]; then
        if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || (( PREFIX < 0 || PREFIX > 128 )); then
            log ERROR "Invalid IPv6 prefix length '$PREFIX' in '$RAW'"; return 1
        fi
    fi
    if [[ "$ADDR" != *:* ]]; then
        log ERROR "Invalid IPv6 address: '$ADDR'"; return 1
    fi
    local DCOUNT; DCOUNT=$(grep -o "::" <<< "$ADDR" | wc -l)
    if (( DCOUNT > 1 )); then
        log ERROR "Invalid IPv6 address: '$ADDR' has more than one '::'"; return 1
    fi
    if [[ "$ADDR" == *::* ]]; then
        local LEFT="${ADDR%%::*}" RIGHT="${ADDR#*::}"
        local -a LG=() RG=()
        [[ -n "$LEFT"  ]] && IFS=':' read -ra LG <<< "$LEFT"
        [[ -n "$RIGHT" ]] && IFS=':' read -ra RG <<< "$RIGHT"
        local G
        for G in "${LG[@]}" "${RG[@]}"; do
            [[ "$G" =~ ^[0-9A-Fa-f]{1,4}$ ]] || { log ERROR "Invalid IPv6 group '$G' in '$ADDR'"; return 1; }
        done
        if (( ${#LG[@]} + ${#RG[@]} > 7 )); then
            log ERROR "Invalid IPv6 address: '$ADDR' has too many groups alongside '::'"; return 1
        fi
    else
        local -a GA
        IFS=':' read -ra GA <<< "$ADDR"
        if [[ ${#GA[@]} -ne 8 ]]; then
            log ERROR "Invalid IPv6 address: '$ADDR' (expected 8 groups, or compress with '::')"; return 1
        fi
        local G
        for G in "${GA[@]}"; do
            [[ "$G" =~ ^[0-9A-Fa-f]{1,4}$ ]] || { log ERROR "Invalid IPv6 group '$G' in '$ADDR'"; return 1; }
        done
    fi
    return 0
}
validate_cidr6() {
    local RAW="$1"
    if [[ "$RAW" != */* ]]; then
        log ERROR "Expected CIDR notation (e.g. 2001:db8::1/64), got '$RAW'"
        return 1
    fi
    validate_ip6 "$RAW"
}
validate_port() {
    local PORT="$1"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        log ERROR "Invalid port '$PORT'. Must be 1–65535."
        return 1
    fi
    return 0
}
validate_proto() {
    local PROTO="$1"
    if [[ "$PROTO" != "tcp" && "$PROTO" != "udp" && "$PROTO" != "icmp" ]]; then
        log ERROR "Invalid protocol '$PROTO'. Use: tcp | udp | icmp"
        return 1
    fi
    return 0
}
validate_positive_int() {
    local VAL="$1"; local LABEL="${2:-value}"
    if ! [[ "$VAL" =~ ^[0-9]+$ ]] || (( VAL <= 0 )); then
        log ERROR "Invalid $LABEL '$VAL'. Must be a positive integer."
        return 1
    fi
    return 0
}
validate_mac() {
    local MAC="$1"
    if ! [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        log ERROR "Invalid MAC address '$MAC'. Format: AA:BB:CC:DD:EE:FF"
        return 1
    fi
    return 0
}
require_args() {
    local GIVEN="$1"; local NEED="$2"; local USAGE="$3"
    if [[ -z "$GIVEN" ]] || (( ${#GIVEN} == 0 && NEED > 0 )); then
        log ERROR "Missing arguments. Usage: $USAGE"; return 1
    fi
    return 0
}
confirm() {
    local MSG="$1"
    if [[ "$WEBEXEC_MODE" == "1" ]]; then
        log INFO "[auto-confirm, non-interactive] $MSG"
        return 0
    fi
    echo -en "${YELLOW}[?]${NC} $MSG ${BOLD}[y/N]${NC} "
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]]
}
_on_exit() {
    _save_web_state
    echo ""
    log INFO "NetCoreOS session closed — live config on this host was left running (mode: $MODE)."
    log INFO "Log: $LOG_FILE"
}
trap _on_exit EXIT TERM
cleanup_router() {
    log INFO "Cleaning up router config..."
    local FRR_SENTINEL="$BASE_DIR/.frr_started_by_netcoreos"
    if [[ -f "$FRR_SENTINEL" ]]; then
        if systemctl is-active frr &>/dev/null 2>&1; then
            log INFO "Stopping FRR (started by NetCoreOS)..."
            systemctl stop frr 2>/dev/null && log INFO "FRR stopped."
        fi
        rm -f "$FRR_SENTINEL"
    fi
    while IFS= read -r route; do
        [[ -n "$route" ]] && ip route del $route 2>/dev/null
    done < "$ROUTES_FILE"
    > "$ROUTES_FILE"
    ip addr flush dev "$BR" 2>/dev/null
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done < "$DNSMASQ_PIDS_FILE"
    > "$DNSMASQ_PIDS_FILE"
    while IFS='|' read -r VNI _L _R; do
        [[ -n "$VNI" ]] && ip link del "vxlan${VNI}" 2>/dev/null
    done < "$VXLANS_FILE"
    > "$VXLANS_FILE"
    if [[ -s "$VRFS_FILE" ]]; then
        while IFS='|' read -r VNAME _; do
            [[ -n "$VNAME" ]] && ip link del "$VNAME" 2>/dev/null
        done < "$VRFS_FILE"
        > "$VRFS_FILE"
    fi
    _fw_cleanup
    _qos_cleanup_all
    log INFO "Router cleanup done."
}
cleanup_switch() {
    log INFO "Cleaning up Switch L2 config..."
    while IFS= read -r SUBIF; do
        [[ -n "$SUBIF" ]] && ip link del "$SUBIF" 2>/dev/null
    done < "$SUBIFS_FILE"
    > "$SUBIFS_FILE"
    if [[ -s "$GUARDS_PIDS_FILE" ]]; then
        while IFS='|' read -r PID _; do
            [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
        done < "$GUARDS_PIDS_FILE"
        > "$GUARDS_PIDS_FILE"
    fi
    if [[ -s "$ERRDIS_PIDS_FILE" ]]; then
        while IFS='|' read -r PID _; do
            [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
        done < "$ERRDIS_PIDS_FILE"
        > "$ERRDIS_PIDS_FILE"
    fi
    if [[ -s "$PORTSEC_FILE" ]]; then
        while IFS='|' read -r PSIFACE PSMAC; do
            [[ -n "$PSIFACE" ]] && ebtables -D FORWARD -i "$PSIFACE" ! -s "$PSMAC" -j DROP 2>/dev/null
        done < "$PORTSEC_FILE"
        > "$PORTSEC_FILE"
    fi
    while IFS='|' read -r SRC DST; do
        [[ -n "$SRC" ]] && tc qdisc del dev "$SRC" ingress 2>/dev/null \
                        && tc qdisc del dev "$SRC" root 2>/dev/null
    done < "$MIRRORS_FILE"
    > "$MIRRORS_FILE"
    while IFS='|' read -r BOND _MEMBERS; do
        [[ -n "$BOND" ]] && lacp_remove "$BOND"
    done < <(cat "$BONDS_FILE")
    > "$BONDS_FILE"
    _bridge_restore_all_members
    ip link set "$BR" down 2>/dev/null
    ip link delete "$BR" type bridge 2>/dev/null
    log INFO "Switch L2 cleanup done."
}
cleanup_switch_mls() {
    log INFO "Cleaning up Switch MLS (L3) config..."
    cleanup_switch
    cleanup_router
    log INFO "Switch MLS cleanup done."
}
cleanup_firewall() {
    log INFO "Cleaning up firewall rules..."
    _fw_cleanup
    log INFO "Firewall cleanup done."
}
_fw_cleanup() {
    iptables -D FORWARD    -j "$FW_CHAIN"        2>/dev/null
    iptables -t nat -D POSTROUTING -j "${FW_CHAIN}_NAT" 2>/dev/null
    iptables -F "$FW_CHAIN"                      2>/dev/null
    iptables -X "$FW_CHAIN"                      2>/dev/null
    iptables -t nat -F "${FW_CHAIN}_NAT"         2>/dev/null
    iptables -t nat -X "${FW_CHAIN}_NAT"         2>/dev/null
    if command -v ip6tables &>/dev/null; then
        ip6tables -D FORWARD -j "$FW_CHAIN" 2>/dev/null
        ip6tables -F "$FW_CHAIN"            2>/dev/null
        ip6tables -X "$FW_CHAIN"            2>/dev/null
    fi
    > "$ACLV2_FILE"
}
_qos_cleanup_all() {
    while IFS='|' read -r IFACE _POLICY; do
        [[ -n "$IFACE" ]] && tc qdisc del dev "$IFACE" root 2>/dev/null
    done < "$QOS_FILE"
    > "$QOS_FILE"
}
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    log INFO "IPv4 + IPv6 forwarding enabled."
}
_bridge_snap_iface() {
    local IFACE="$1"
    local STATE
    STATE=$(ip -br link show "$IFACE" 2>/dev/null | awk '{print $2}')
    local ADDRS
    ADDRS=$(ip -4 addr show dev "$IFACE" 2>/dev/null \
            | awk '/inet / {print $2}' | tr '\n' ' ' | sed 's/ $//')
    local MASTER
    MASTER=$(ip link show "$IFACE" 2>/dev/null | grep -oP 'master \K\S+' || true)
    local MAC
    MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/link\/ether/ {print $2}' | head -1)
    echo "${IFACE}|${STATE}|${ADDRS}|${MASTER}|${MAC}" >> "$BRIDGE_MEMBERS_FILE"
    log INFO "  Snapshot: $IFACE (state=$STATE, IPs='${ADDRS:-none}', master='${MASTER:-none}')"
}
_bridge_restore_all_members() {
    [[ -s "$BRIDGE_MEMBERS_FILE" ]] || return
    log INFO "Restoring bridge member interfaces..."
    while IFS='|' read -r IFACE STATE ADDRS MASTER MAC; do
        [[ -z "$IFACE" ]] && continue
        log INFO "  Restoring $IFACE..."
        ip link set "$IFACE" down 2>/dev/null
        ip link set "$IFACE" nomaster 2>/dev/null
        if [[ -n "$MAC" ]]; then
            ip link set "$IFACE" address "$MAC" 2>/dev/null \
                && log INFO "    MAC restored: $MAC"
        fi
        if [[ -n "$MASTER" ]] && ip link show "$MASTER" &>/dev/null; then
            ip link set "$IFACE" master "$MASTER" 2>/dev/null \
                && log INFO "    Master restored: $MASTER"
        fi
        ip addr flush dev "$IFACE" 2>/dev/null
        if [[ -n "$ADDRS" ]]; then
            for ADDR in $ADDRS; do
                ip addr add "$ADDR" dev "$IFACE" 2>/dev/null \
                    && log INFO "    IP restored: $ADDR"
            done
        fi
        if [[ "$STATE" == "UP" ]]; then
            ip link set "$IFACE" up 2>/dev/null \
                && log INFO "    $IFACE brought UP"
        else
            log INFO "    $IFACE left DOWN (was down before)"
        fi
    done < "$BRIDGE_MEMBERS_FILE"
    > "$BRIDGE_MEMBERS_FILE"
    log OK "All bridge members restored to pre-bridge state."
}
select_bridge_members() {
    local CANDIDATES=()
    while IFS= read -r LINE; do
        local IFACE STATE
        IFACE=$(echo "$LINE" | awk '{print $1}')
        STATE=$(echo "$LINE" | awk '{print $2}')
        [[ "$IFACE" == "lo"    ]] && continue
        [[ "$IFACE" == "$BR"   ]] && continue
        [[ "$IFACE" == "$WAN_IF" ]] && continue
        ip link show "$IFACE" 2>/dev/null | grep -q 'master' && continue
        local TYPE
        TYPE=$(ip -d link show "$IFACE" 2>/dev/null | awk 'NR==3{print $1}')
        case "$TYPE" in
            vxlan|bond|vlan|dummy|tun|tap|wireguard) continue ;;
        esac
        [[ "$IFACE" == *.* ]] && continue
        CANDIDATES+=("$IFACE|$STATE")
    done < <(ip -br link show 2>/dev/null)
    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        log ERROR "No available physical interfaces to add to the bridge."
        log WARN  "All interfaces are either in use, virtual, or protected (WAN: $WAN_IF)."
        return 1
    fi
    echo ""
    echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│   Select Bridge Member Interfaces        │${NC}"
    echo -e "${BOLD}${CYAN}├─────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}${CYAN}│${NC}  Protected (will NOT be listed):         ${BOLD}${CYAN}│${NC}"
    echo -e "${BOLD}${CYAN}│${NC}    WAN/Mgmt: ${YELLOW}$WAN_IF${NC}                        ${BOLD}${CYAN}│${NC}"
    echo -e "${BOLD}${CYAN}├─────────────────────────────────────────┤${NC}"
    local i=1
    for ENTRY in "${CANDIDATES[@]}"; do
        local IF_NAME IF_STATE
        IF_NAME=$(echo "$ENTRY"  | cut -d'|' -f1)
        IF_STATE=$(echo "$ENTRY" | cut -d'|' -f2)
        local IP_INFO
        IP_INFO=$(ip -4 addr show dev "$IF_NAME" 2>/dev/null \
                  | awk '/inet / {print $2}' | head -1)
        [[ -z "$IP_INFO" ]] && IP_INFO="no IP"
        if [[ "$IF_STATE" == "UP" ]]; then
            local STATE_COLOR="${GREEN}"
        else
            local STATE_COLOR="${DIM}"
        fi
        printf "${BOLD}${CYAN}│${NC}  ${BOLD}[%d]${NC} %-12s ${STATE_COLOR}%-6s${NC} %s\n" \
               "$i" "$IF_NAME" "$IF_STATE" "$IP_INFO"
        (( i++ ))
    done
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -e " Enter interface numbers separated by spaces."
    echo -e " ${DIM}Example: 1 3  or  1 2 3${NC}"
    echo -e " ${YELLOW}[!]${NC} Interfaces with IPs will have them removed (moved to bridge)."
    echo ""
    read -e -p "$(echo -e "${CYAN}bridge members>${NC} ")" SELECTION
    if [[ -z "${SELECTION// }" ]]; then
        log WARN "No interfaces selected. Bridge created with no members."
        log WARN "Use 'access <iface> <vlan>' or 'trunk <iface> <vlan>' to add them later."
        return 0
    fi
    local ADDED=0
    for NUM in $SELECTION; do
        if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#CANDIDATES[@]} )); then
            log WARN "  '$NUM' is not a valid selection — skipped."
            continue
        fi
        local CHOSEN_ENTRY="${CANDIDATES[$((NUM-1))]}"
        local CHOSEN_IF
        CHOSEN_IF=$(echo "$CHOSEN_ENTRY" | cut -d'|' -f1)
        _bridge_snap_iface "$CHOSEN_IF"
        ip link set "$CHOSEN_IF" down 2>/dev/null
        ip addr flush dev "$CHOSEN_IF" 2>/dev/null
        ip link set "$CHOSEN_IF" master "$BR" 2>/dev/null
        ip link set "$CHOSEN_IF" up 2>/dev/null
        log OK "  $CHOSEN_IF added to bridge $BR"
        (( ADDED++ ))
    done
    if (( ADDED > 0 )); then
        log OK "$ADDED interface(s) added to bridge $BR."
    else
        log WARN "No valid interfaces were added to the bridge."
    fi
}
create_bridge() {
    ip link add name "$BR" type bridge vlan_filtering 1 2>/dev/null
    ip link set "$BR" up
    log OK "Bridge $BR created."
    select_bridge_members
}
start_dhcp() {
    local VLAN_IF="$1"; local RANGE_START="$2"; local RANGE_END="$3"
    local GW="$4"
    local DNS="$5"
    local CONF_FILE="/tmp/dhcp-${VLAN_IF//\//-}.conf"
    {
        echo "interface=${VLAN_IF}"
        echo "bind-interfaces"
        echo "except-interface=lo"
        echo "dhcp-range=${RANGE_START},${RANGE_END},255.255.255.0,12h"
        [[ -n "$GW"  ]] && echo "dhcp-option=3,${GW}"
        [[ -n "$DNS" ]] && echo "dhcp-option=6,${DNS}"
    } > "$CONF_FILE"
    dnsmasq --no-daemon --conf-file="$CONF_FILE" &
    local DPID=$!
    sleep 0.3
    if ! kill -0 "$DPID" 2>/dev/null; then
        log ERROR "dnsmasq failed to start on $VLAN_IF (check: no other DHCP/DNS server bound to this interface, and dnsmasq is installed)."
        return 1
    fi
    echo "$DPID" >> "$DNSMASQ_PIDS_FILE"
    log OK "DHCP started on $VLAN_IF ($RANGE_START–$RANGE_END) [PID $DPID]"
}
start_dhcp6() {
    local VLAN_IF="$1"; local PREFIX="$2"; local DNS6="$3"
    local CONF_FILE="/tmp/dhcp6-${VLAN_IF//\//-}.conf"
    {
        echo "interface=${VLAN_IF}"
        echo "bind-interfaces"
        echo "except-interface=lo"
        echo "enable-ra"
        echo "dhcp-range=::,constructor:${VLAN_IF},ra-stateless,64,12h"
        [[ -n "$DNS6" ]] && echo "dhcp-option=option6:23,[${DNS6}]"
    } > "$CONF_FILE"
    dnsmasq --no-daemon --conf-file="$CONF_FILE" &
    local DPID=$!
    sleep 0.3
    if ! kill -0 "$DPID" 2>/dev/null; then
        log ERROR "dnsmasq failed to start IPv6 RA on $VLAN_IF (check: $VLAN_IF has a global IPv6 address in $PREFIX, and dnsmasq is installed)."
        return 1
    fi
    echo "$DPID" >> "$DNSMASQ_PIDS_FILE"
    log OK "IPv6 RA/SLAAC started on $VLAN_IF (prefix $PREFIX) [PID $DPID]"
}
track_route()  { echo "$*"  >> "$ROUTES_FILE"; }
track_subif()  { echo "$1"  >> "$SUBIFS_FILE"; }
svi_create() {
    local VLAN="$1"; local IP="$2"
    validate_vlan "$VLAN" || return 1
    local SVI="${BR}.${VLAN}"
    if ! ip link show "$SVI" &>/dev/null; then
        bridge vlan add dev "$BR" vid "$VLAN" self 2>/dev/null
        ip link add link "$BR" name "$SVI" type vlan id "$VLAN" 2>/dev/null \
            || { log ERROR "Failed to create SVI $SVI."; return 1; }
        ip link set "$SVI" up 2>/dev/null
        track_subif "$SVI"
        log OK "SVI $SVI created."
    fi
    if [[ -n "$IP" ]]; then
        if [[ "$IP" == *:* ]]; then
            validate_cidr6 "$IP" || return 1
            if ! ip -6 addr show dev "$SVI" 2>/dev/null | grep -q "$IP"; then
                ip -6 addr add "$IP" dev "$SVI" 2>/dev/null \
                    && log OK "$IP (v6) assigned to $SVI."
            else
                log INFO "$IP already assigned to $SVI."
            fi
        else
            validate_cidr "$IP" || return 1
            if ! ip -4 addr show dev "$SVI" 2>/dev/null | grep -q "$IP"; then
                ip addr add "$IP" dev "$SVI" 2>/dev/null \
                    && log OK "$IP assigned to $SVI."
            else
                log INFO "$IP already assigned to $SVI."
            fi
        fi
        [[ "$MODE" == "switch-mls" ]] && fw_allow_vlan "$SVI"
    fi
    return 0
}
svi_remove() {
    local VLAN="$1"
    validate_vlan "$VLAN" || return 1
    local SVI="${BR}.${VLAN}"
    if ip link show "$SVI" &>/dev/null; then
        ip link del "$SVI" 2>/dev/null
        grep -vxF "$SVI" "$SUBIFS_FILE" > "${SUBIFS_FILE}.tmp" 2>/dev/null \
            && mv "${SUBIFS_FILE}.tmp" "$SUBIFS_FILE"
        log OK "SVI $SVI removed."
    else
        log ERROR "SVI $SVI does not exist."
    fi
}
svi_show() {
    echo -e "${BOLD}--- SVIs (VLAN interfaces) on $BR ---${NC}"
    local FOUND=0
    while IFS= read -r SUBIF; do
        [[ "$SUBIF" == "${BR}."* ]] || continue
        local ADDRS
        ADDRS=$(ip -4 addr show dev "$SUBIF" 2>/dev/null | awk '/inet /{print $2}' | paste -sd, -)
        printf "  %-14s VLAN %-6s %s\n" "$SUBIF" "${SUBIF##*.}" "${ADDRS:-(no IP)}"
        FOUND=1
    done < "$SUBIFS_FILE"
    (( FOUND == 0 )) && echo "  (none)"
}
_pvlan_set_port() {
    local IFACE="$1" VLAN="$2" ISOLATED="$3"
    validate_iface "$IFACE" && validate_vlan "$VLAN" || return 1
    grep -q "^${IFACE}|" "$BRIDGE_MEMBERS_FILE" 2>/dev/null || _bridge_snap_iface "$IFACE"
    ip link set "$IFACE" down 2>/dev/null
    ip addr flush dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" master "$BR" 2>/dev/null
    bridge vlan add dev "$IFACE" vid "$VLAN" pvid untagged 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    if bridge link set dev "$IFACE" isolated "$ISOLATED" 2>/dev/null; then
        log OK "PVLAN: $IFACE on VLAN $VLAN (isolated=$ISOLATED). Isolated ports can't reach each other, only non-isolated ports."
    else
        log ERROR "PVLAN: this kernel/iproute2 doesn't support bridge port isolation. $IFACE is on VLAN $VLAN as a plain access port, but real isolation was NOT applied."
        return 1
    fi
}
uptime_str() {
    local NOW; NOW=$(date +%s)
    local SECS=$(( NOW - START_TIME ))
    printf '%02dh:%02dm:%02ds' $(( SECS/3600 )) $(( (SECS%3600)/60 )) $(( SECS%60 ))
}
bpdu_monitor() {
    local IFACE="$1"; local TYPE="$2"
    while true; do
        local BPDU
        BPDU=$(timeout 1 tcpdump -c 1 -i "$IFACE" ether dst 01:80:C2:00:00:00 2>/dev/null)
        if [[ -n "$BPDU" ]]; then
            case "$TYPE" in
                bpdu) log WARN "BPDU Guard triggered on $IFACE — shutting down port"
                      ip link set "$IFACE" down ;;
                root) log WARN "Root Guard triggered on $IFACE — blocking superior BPDU"
                      ip link set "$IFACE" down ;;
                loop) log WARN "Loop Guard triggered on $IFACE — blocking"
                      ip link set "$IFACE" down ;;
                tc)   log WARN "STP Topology Change detected on $IFACE" ;;
            esac
        fi
        sleep 1
    done
}
_guard_disable() {
    local IFACE="$1" TYPE="$2"
    [[ -f "$GUARDS_PIDS_FILE" ]] || { log WARN "No active ${TYPE} guard found on ${IFACE}."; return 1; }
    local TMP; TMP=$(mktemp)
    local FOUND=0
    while IFS='|' read -r PID GIF GTYPE; do
        [[ -z "$PID" ]] && continue
        if [[ "$GIF" == "$IFACE" && "$GTYPE" == "$TYPE" ]]; then
            kill "$PID" 2>/dev/null
            FOUND=1
        else
            echo "${PID}|${GIF}|${GTYPE}" >> "$TMP"
        fi
    done < "$GUARDS_PIDS_FILE"
    mv "$TMP" "$GUARDS_PIDS_FILE"
    if [[ "$FOUND" == "1" ]]; then
        ip link set "$IFACE" up 2>/dev/null
        log OK "${TYPE} guard disabled on ${IFACE}."
    else
        log WARN "No active ${TYPE} guard found on ${IFACE}."
    fi
}
fw_init() {
    log INFO "Initializing NetCoreOS firewall chains..."
    _fw_cleanup
    iptables -N "$FW_CHAIN"
    iptables -t nat -N "${FW_CHAIN}_NAT"
    iptables -I FORWARD 1 -j "$FW_CHAIN"
    iptables -t nat -I POSTROUTING 1 -j "${FW_CHAIN}_NAT"
    iptables -A "$FW_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A "$FW_CHAIN" -m comment --comment "netcoreos-default-drop" -j DROP
    if command -v ip6tables &>/dev/null; then
        ip6tables -N "$FW_CHAIN" 2>/dev/null
        ip6tables -I FORWARD 1 -j "$FW_CHAIN" 2>/dev/null
        ip6tables -A "$FW_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        ip6tables -A "$FW_CHAIN" -m comment --comment "netcoreos-default-drop" -j DROP 2>/dev/null
    fi
    log OK "Chain '$FW_CHAIN' active$(command -v ip6tables &>/dev/null && echo " (IPv4+IPv6)"). System policies unchanged."
}
fw_allow_vlan() {
    local VLAN_IF="$1"
    iptables -I "$FW_CHAIN" 1 -i "$VLAN_IF" -o "$BR"      -j ACCEPT 2>/dev/null
    iptables -I "$FW_CHAIN" 1 -i "$BR"      -o "$VLAN_IF" -j ACCEPT 2>/dev/null
    if ! iptables -C "$FW_CHAIN" -i "${BR}.+" -o "${BR}.+" -j ACCEPT 2>/dev/null; then
        iptables -I "$FW_CHAIN" 1 -i "${BR}.+" -o "${BR}.+" -j ACCEPT 2>/dev/null
    fi
    log INFO "Firewall: inter-VLAN traffic allowed on $VLAN_IF"
}
fw_allow_wan() {
    iptables -I "$FW_CHAIN" 1 -i "$BR"      -o "$WAN_IF" -j ACCEPT
    iptables -I "$FW_CHAIN" 1 -i "$WAN_IF"  -o "$BR"     -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -t nat -I "${FW_CHAIN}_NAT" 1  -o "$WAN_IF" -j MASQUERADE
    log OK "NAT + WAN forwarding enabled on $WAN_IF"
}
fw_acl_deny() {
    local SRC="$1"; local DST="$2"
    iptables -I "$FW_CHAIN" 1 -i "$SRC" -o "$DST" -j DROP
    iptables -I "$FW_CHAIN" 1 -i "$DST" -o "$SRC" -j DROP
    log OK "ACL DENY: $SRC <-> $DST (bidirectional)"
}
fw_acl_allow_port() {
    local SRC="$1"; local DST="$2"; local PROTO="$3"; local PORT="$4"
    iptables -I "$FW_CHAIN" 1 -i "$SRC" -o "$DST" -p "$PROTO" --dport "$PORT" -j ACCEPT
    log OK "ACL ALLOW: $PROTO/$PORT  $SRC -> $DST"
}
_acl2_family_bin() {
    [[ "$1" == *:* || "$2" == *:* ]] && echo "ip6tables" || echo "iptables"
}
_acl2_insert_pos() {
    local BIN="$1" POS
    POS=$("$BIN" -L "$FW_CHAIN" --line-numbers -n 2>/dev/null \
          | awk '/netcoreos-default-drop/ {print $1; exit}')
    [[ -n "$POS" ]] && echo "$POS" || echo "1"
}
_acl2_add() {
    local DIR="$1" IFACE="$2" ACTION="$3" PROTO="$4" SRC="$5" DST="$6" PORT="$7"
    validate_iface "$IFACE" || return 1
    [[ "$DIR" == "in" || "$DIR" == "out" ]] \
        || { log ERROR "Direction must be 'in' or 'out'."; return 1; }
    [[ "$ACTION" == "permit" || "$ACTION" == "deny" ]] \
        || { log ERROR "Action must be 'permit' or 'deny'."; return 1; }
    if [[ "$PROTO" != "any" && "$PROTO" != "ip" ]]; then
        validate_proto "$PROTO" || return 1
    fi
    [[ "$SRC" == "any" ]] || { [[ "$SRC" == *:* ]] && { validate_ip6 "$SRC" || return 1; } || { validate_ip "$SRC" || return 1; }; }
    [[ "$DST" == "any" ]] || { [[ "$DST" == *:* ]] && { validate_ip6 "$DST" || return 1; } || { validate_ip "$DST" || return 1; }; }
    if [[ -n "$PORT" ]] && [[ "$PROTO" != "tcp" && "$PROTO" != "udp" ]]; then
        log ERROR "A port only makes sense with tcp or udp."; return 1
    fi
    local BIN; BIN=$(_acl2_family_bin "$SRC" "$DST")
    if ! "$BIN" -L "$FW_CHAIN" &>/dev/null; then
        log ERROR "Firewall chain not initialized for $( [[ "$BIN" == ip6tables ]] && echo IPv6 || echo IPv4 ). Run 'firewall init' first."
        return 1
    fi
    local TARGET; [[ "$ACTION" == "permit" ]] && TARGET="ACCEPT" || TARGET="DROP"
    local POS; POS=$(_acl2_insert_pos "$BIN")
    local -a RULE=("-I" "$FW_CHAIN" "$POS")
    [[ "$DIR" == "in"  ]] && RULE+=("-i" "$IFACE")
    [[ "$DIR" == "out" ]] && RULE+=("-o" "$IFACE")
    [[ "$PROTO" != "any" && "$PROTO" != "ip" ]] && RULE+=("-p" "$PROTO")
    [[ "$SRC" != "any" ]] && RULE+=("-s" "$SRC")
    [[ "$DST" != "any" ]] && RULE+=("-d" "$DST")
    [[ -n "$PORT" ]] && RULE+=("--dport" "$PORT")
    RULE+=("-j" "$TARGET")
    if "$BIN" "${RULE[@]}" 2>/dev/null; then
        local SEQ=1
        [[ -s "$ACLV2_FILE" ]] && SEQ=$(( $(tail -1 "$ACLV2_FILE" | cut -d'|' -f1) + 1 ))
        echo "${SEQ}|${DIR}|${IFACE}|${ACTION}|${PROTO}|${SRC}|${DST}|${PORT}" >> "$ACLV2_FILE"
        log OK "ACL #$SEQ: $ACTION $PROTO $SRC -> $DST ($DIR $IFACE)"
    else
        log ERROR "Failed to install ACL rule ($BIN)."
        return 1
    fi
}
_acl2_remove() {
    local SEQ="$1"
    require_args "$SEQ" 1 "acl remove <seq>" || return 1
    local LINE; LINE=$(grep "^${SEQ}|" "$ACLV2_FILE" 2>/dev/null)
    [[ -n "$LINE" ]] || { log ERROR "No ACL rule #$SEQ."; return 1; }
    local DIR IFACE ACTION PROTO SRC DST PORT
    IFS='|' read -r _ DIR IFACE ACTION PROTO SRC DST PORT <<< "$LINE"
    local BIN; BIN=$(_acl2_family_bin "$SRC" "$DST")
    local TARGET; [[ "$ACTION" == "permit" ]] && TARGET="ACCEPT" || TARGET="DROP"
    local -a RULE=("-D" "$FW_CHAIN")
    [[ "$DIR" == "in"  ]] && RULE+=("-i" "$IFACE")
    [[ "$DIR" == "out" ]] && RULE+=("-o" "$IFACE")
    [[ "$PROTO" != "any" && "$PROTO" != "ip" ]] && RULE+=("-p" "$PROTO")
    [[ "$SRC" != "any" ]] && RULE+=("-s" "$SRC")
    [[ "$DST" != "any" ]] && RULE+=("-d" "$DST")
    [[ -n "$PORT" ]] && RULE+=("--dport" "$PORT")
    RULE+=("-j" "$TARGET")
    "$BIN" "${RULE[@]}" 2>/dev/null
    grep -v "^${SEQ}|" "$ACLV2_FILE" > "${ACLV2_FILE}.tmp" && mv "${ACLV2_FILE}.tmp" "$ACLV2_FILE"
    log OK "ACL #$SEQ removed."
}
fw_ratelimit() {
    local IFACE="$1"; local SRC_IP="$2"; local KBPS="$3"
    local MARK=$(( RANDOM % 999 + 1 ))
    iptables -I "$FW_CHAIN" 1 -i "$IFACE" -s "$SRC_IP" -j MARK --set-mark "$MARK"
    tc qdisc add dev "$IFACE" root handle 1: htb default 99 2>/dev/null
    tc class add dev "$IFACE" parent 1: classid "1:${MARK}" htb \
        rate "${KBPS}kbit" ceil "${KBPS}kbit" burst 15k 2>/dev/null
    tc filter add dev "$IFACE" parent 1: protocol ip handle "$MARK" \
        fw flowid "1:${MARK}" 2>/dev/null
    log OK "Rate limit: $SRC_IP on $IFACE capped at ${KBPS}kbps [mark $MARK]"
}
QOS_POLICY_DIR="$BASE_DIR/qos"
mkdir -p "$QOS_POLICY_DIR"
qos_policy_create() {
    local NAME="$1"; local RATE="$2"
    validate_positive_int "$RATE" "total rate (mbit)" || return 1
    echo "TOTAL_RATE=${RATE}" > "$QOS_POLICY_DIR/${NAME}.cfg"
    log OK "QoS policy '$NAME' created (total ${RATE}mbit)."
}
qos_class_add() {
    local POLICY="$1"; local CLASSID="$2"
    local RATE="$3";   local CEIL="$4"; local PRIO="${5:-5}"
    local CFG="$QOS_POLICY_DIR/${POLICY}.cfg"
    [[ -f "$CFG" ]] || { log ERROR "Policy '$POLICY' not found. Create it first."; return 1; }
    validate_positive_int "$RATE" "class rate"  || return 1
    validate_positive_int "$CEIL" "class ceil"  || return 1
    validate_positive_int "$PRIO" "priority"    || return 1
    echo "${CLASSID}|${RATE}|${CEIL}|${PRIO}" >> "$CFG"
    log OK "QoS class $CLASSID added to policy '$POLICY' (${RATE}mbit/${CEIL}mbit ceil, prio $PRIO)."
}
qos_apply() {
    local IFACE="$1"; local POLICY="$2"
    validate_iface "$IFACE" || return 1
    local CFG="$QOS_POLICY_DIR/${POLICY}.cfg"
    [[ -f "$CFG" ]] || { log ERROR "Policy '$POLICY' not found."; return 1; }
    local TOTAL_RATE
    TOTAL_RATE=$(grep '^TOTAL_RATE=' "$CFG" | cut -d= -f2)
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc add dev "$IFACE" root handle 1: htb default 99
    tc class add dev "$IFACE" parent 1: classid 1:1 htb \
        rate "${TOTAL_RATE}mbit" ceil "${TOTAL_RATE}mbit"
    tc class add dev "$IFACE" parent 1:1 classid 1:99 htb \
        rate "1mbit" ceil "${TOTAL_RATE}mbit" prio 7
    while IFS='|' read -r CID RATE CEIL PRIO; do
        [[ "$CID" =~ ^[0-9]+$ ]] || continue
        tc class add dev "$IFACE" parent 1:1 classid "1:${CID}" htb \
            rate "${RATE}mbit" ceil "${CEIL}mbit" prio "$PRIO"
        tc qdisc add dev "$IFACE" parent "1:${CID}" handle "${CID}:" sfq perturb 10
        log INFO "  Class 1:${CID} — ${RATE}mbit rate, ${CEIL}mbit ceil, prio $PRIO"
    done < <(grep -v '^TOTAL_RATE' "$CFG")
    echo "${IFACE}|${POLICY}" >> "$QOS_FILE"
    log OK "QoS policy '$POLICY' applied to $IFACE."
}
qos_show() {
    local IFACE="${1:-}"
    if [[ -n "$IFACE" ]]; then
        validate_iface "$IFACE" || return 1
        echo -e "${BOLD}--- QoS qdiscs on $IFACE ---${NC}"
        tc qdisc show dev "$IFACE"
        echo -e "${BOLD}--- QoS classes on $IFACE ---${NC}"
        tc class show dev "$IFACE"
    else
        echo -e "${BOLD}--- All QoS policies ---${NC}"
        ls "$QOS_POLICY_DIR"/*.cfg 2>/dev/null | while read -r f; do
            echo -e "${CYAN}$(basename "$f" .cfg)${NC}:"
            cat "$f"
            echo ""
        done
        echo -e "${BOLD}--- Applied interfaces ---${NC}"
        cat "$QOS_FILE"
    fi
}
qos_remove() {
    local IFACE="$1"
    validate_iface "$IFACE" || return 1
    tc qdisc del dev "$IFACE" root 2>/dev/null && log OK "QoS removed from $IFACE."
    grep -v "^${IFACE}|" "$QOS_FILE" > "${QOS_FILE}.tmp" && mv "${QOS_FILE}.tmp" "$QOS_FILE"
}
mirror_create() {
    local SRC="$1"; local DST="$2"
    validate_iface "$SRC" || return 1
    validate_iface "$DST" || return 1
    ip link set "$DST" promisc on
    tc qdisc add dev "$SRC" ingress handle ffff: 2>/dev/null
    tc filter add dev "$SRC" parent ffff: protocol all u32 match u8 0 0 \
        action mirred egress mirror dev "$DST" 2>/dev/null
    if ip link add ifb-sos type ifb 2>/dev/null; then
        ip link set ifb-sos up
        tc qdisc add dev "$SRC" root handle 1: prio 2>/dev/null
        tc filter add dev "$SRC" parent 1: protocol all u32 match u8 0 0 \
            action mirred egress redirect dev ifb-sos 2>/dev/null
        tc qdisc add dev ifb-sos root handle 10: prio 2>/dev/null
        tc filter add dev ifb-sos parent 10: protocol all u32 match u8 0 0 \
            action mirred egress mirror dev "$DST" 2>/dev/null
    fi
    echo "${SRC}|${DST}" >> "$MIRRORS_FILE"
    log OK "Port mirror: $SRC -> $DST (SPAN active)"
}
mirror_remove() {
    local SRC="$1"
    validate_iface "$SRC" || return 1
    tc qdisc del dev "$SRC" ingress 2>/dev/null
    tc qdisc del dev "$SRC" root    2>/dev/null
    ip link del ifb-sos 2>/dev/null
    grep -v "^${SRC}|" "$MIRRORS_FILE" > "${MIRRORS_FILE}.tmp" \
        && mv "${MIRRORS_FILE}.tmp" "$MIRRORS_FILE"
    log OK "Port mirror removed from $SRC."
}
BOND_SNAP_DIR="$BASE_DIR/bond_snaps"
mkdir -p "$BOND_SNAP_DIR"
_lacp_snap_iface() {
    local IFACE="$1"
    local BOND="$2"
    local SNAP_DIR="$BOND_SNAP_DIR/${BOND}"
    mkdir -p "$SNAP_DIR"
    local SNAP_FILE="$SNAP_DIR/${IFACE}.snap"
    local STATE
    STATE=$(ip -br link show "$IFACE" 2>/dev/null | awk '{print $2}')
    echo "LINK_STATE=${STATE}" > "$SNAP_FILE"
    local ADDRS
    ADDRS=$(ip -4 addr show dev "$IFACE" 2>/dev/null \
            | awk '/inet / {print $2}' | tr '\n' ' ' | sed 's/ $//')
    echo "ADDRS=${ADDRS}" >> "$SNAP_FILE"
    local MAC
    MAC=$(ip link show "$IFACE" 2>/dev/null \
          | awk '/link\/ether/ {print $2}' | head -1)
    echo "MAC=${MAC}" >> "$SNAP_FILE"
    local MASTER
    MASTER=$(ip link show "$IFACE" 2>/dev/null \
             | grep -oP 'master \K\S+' || true)
    echo "MASTER=${MASTER}" >> "$SNAP_FILE"
    log INFO "  Snapshot saved for $IFACE -> $SNAP_FILE"
}
_lacp_restore_iface() {
    local IFACE="$1"
    local BOND="$2"
    local SNAP_FILE="$BOND_SNAP_DIR/${BOND}/${IFACE}.snap"
    if [[ ! -f "$SNAP_FILE" ]]; then
        log WARN "  No snapshot found for $IFACE — leaving as-is."
        return
    fi
    local LINK_STATE ADDRS MAC MASTER
    while IFS='=' read -r KEY VAL; do
        case "$KEY" in
            LINK_STATE) LINK_STATE="$VAL" ;;
            ADDRS)      ADDRS="$VAL"      ;;
            MAC)        MAC="$VAL"        ;;
            MASTER)     MASTER="$VAL"     ;;
        esac
    done < "$SNAP_FILE"
    log INFO "  Restoring $IFACE (was: $LINK_STATE, IPs: '${ADDRS:-none}', master: '${MASTER:-none}')"
    ip link set "$IFACE" down 2>/dev/null
    ip link set "$IFACE" nomaster 2>/dev/null
    if [[ -n "$MAC" ]]; then
        ip link set "$IFACE" address "$MAC" 2>/dev/null \
            && log INFO "  MAC restored: $MAC"
    fi
    if [[ -n "$MASTER" ]] && ip link show "$MASTER" &>/dev/null; then
        ip link set "$IFACE" master "$MASTER" 2>/dev/null \
            && log INFO "  Master restored: $MASTER"
    fi
    if [[ -n "$ADDRS" ]]; then
        for ADDR in $ADDRS; do
            ip addr add "$ADDR" dev "$IFACE" 2>/dev/null \
                && log INFO "  IP restored: $ADDR"
        done
    fi
    if [[ "$LINK_STATE" == "UP" ]]; then
        ip link set "$IFACE" up 2>/dev/null && log INFO "  $IFACE brought UP"
    else
        ip link set "$IFACE" down 2>/dev/null && log INFO "  $IFACE left DOWN"
    fi
    rm -f "$SNAP_FILE"
}
lacp_create() {
    local BOND="$1"; shift
    local MEMBERS=("$@")
    [[ ${#MEMBERS[@]} -lt 2 ]] && { log ERROR "Need at least 2 member interfaces."; return 1; }
    for M in "${MEMBERS[@]}"; do
        validate_iface "$M" || return 1
    done
    log INFO "Snapshotting member interfaces before bonding..."
    for M in "${MEMBERS[@]}"; do
        _lacp_snap_iface "$M" "$BOND"
    done
    modprobe bonding 2>/dev/null
    ip link add name "$BOND" type bond 2>/dev/null
    echo 4   > "/sys/class/net/${BOND}/bonding/mode"      2>/dev/null
    echo 100 > "/sys/class/net/${BOND}/bonding/miimon"    2>/dev/null
    echo 1   > "/sys/class/net/${BOND}/bonding/lacp_rate" 2>/dev/null
    for M in "${MEMBERS[@]}"; do
        ip link set "$M" down    2>/dev/null
        ip addr flush dev "$M"   2>/dev/null
        ip link set "$M" master "$BOND" 2>/dev/null
        ip link set "$M" up      2>/dev/null
        log INFO "  $M enslaved to $BOND"
    done
    ip link set "$BOND" up
    echo "${BOND}|$(IFS=','; echo "${MEMBERS[*]}")" >> "$BONDS_FILE"
    log OK "LACP bond '$BOND' created with members: ${MEMBERS[*]}"
}
lacp_show() {
    if [[ -s "$BONDS_FILE" ]]; then
        while IFS='|' read -r BOND MEMBERS; do
            [[ -z "$BOND" ]] && continue
            echo -e "${BOLD}Bond: $BOND${NC}  (members: $MEMBERS)"
            ip -br link show "$BOND" 2>/dev/null
            [[ -f "/sys/class/net/${BOND}/bonding/mode" ]] && \
                echo "  mode:    $(cat "/sys/class/net/${BOND}/bonding/mode")"
            [[ -f "/sys/class/net/${BOND}/bonding/slaves" ]] && \
                echo "  slaves:  $(cat "/sys/class/net/${BOND}/bonding/slaves")"
            [[ -f "/sys/class/net/${BOND}/bonding/active_slave" ]] && \
                echo "  active:  $(cat "/sys/class/net/${BOND}/bonding/active_slave")"
            echo ""
        done < "$BONDS_FILE"
    else
        echo "(no bonds configured)"
    fi
}
lacp_remove() {
    local BOND="$1"
    if [[ -z "$BOND" ]]; then
        log ERROR "Usage: lacp remove <bond>"
        return 1
    fi
    local MEMBERS_CSV
    MEMBERS_CSV=$(grep "^${BOND}|" "$BONDS_FILE" 2>/dev/null | cut -d'|' -f2)
    local MEMBERS=()
    IFS=',' read -ra MEMBERS <<< "$MEMBERS_CSV"
    log INFO "Releasing bond '$BOND' and restoring ${#MEMBERS[@]} member(s)..."
    ip link set "$BOND" down 2>/dev/null
    for M in "${MEMBERS[@]}"; do
        [[ -n "$M" ]] && _lacp_restore_iface "$M" "$BOND"
    done
    if [[ -f "/sys/class/net/${BOND}/bonding/slaves" ]]; then
        for M in $(cat "/sys/class/net/${BOND}/bonding/slaves" 2>/dev/null); do
            ip link set "$M" nomaster 2>/dev/null
            ip link set "$M" up       2>/dev/null
            log WARN "  $M released (not in snapshot — brought up bare)"
        done
    fi
    ip link del "$BOND" 2>/dev/null
    rm -rf "${BOND_SNAP_DIR:?}/${BOND}"
    grep -v "^${BOND}|" "$BONDS_FILE" > "${BONDS_FILE}.tmp" \
        && mv "${BONDS_FILE}.tmp" "$BONDS_FILE"
    log OK "Bond '$BOND' removed. All members restored to pre-bond state."
}
vxlan_create() {
    local VNI="$1"; local LOCAL_IP="$2"; local REMOTE_IP="$3"
    local DPORT="${4:-4789}"
    validate_positive_int "$VNI"  "VNI"       || return 1
    validate_ip "$LOCAL_IP"                    || return 1
    validate_ip "$REMOTE_IP"                   || return 1
    validate_port "$DPORT"                     || return 1
    local IFNAME="vxlan${VNI}"
    ip link add "$IFNAME" type vxlan \
        id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" \
        dstport "$DPORT" dev "$WAN_IF" 2>/dev/null
    ip link set "$IFNAME" up
    ip link set "$IFNAME" master "$BR" 2>/dev/null
    echo "${VNI}|${LOCAL_IP}|${REMOTE_IP}" >> "$VXLANS_FILE"
    log OK "VXLAN VNI $VNI created: $LOCAL_IP <-> $REMOTE_IP (port $DPORT)"
}
vxlan_remove() {
    local VNI="$1"
    validate_positive_int "$VNI" "VNI" || return 1
    ip link del "vxlan${VNI}" 2>/dev/null && log OK "VXLAN VNI $VNI removed."
    grep -v "^${VNI}|" "$VXLANS_FILE" > "${VXLANS_FILE}.tmp" \
        && mv "${VXLANS_FILE}.tmp" "$VXLANS_FILE"
}
vxlan_show() {
    echo -e "${BOLD}--- VXLAN Tunnels ---${NC}"
    if [[ -s "$VXLANS_FILE" ]]; then
        printf "%-8s %-18s %-18s\n" "VNI" "LOCAL" "REMOTE"
        while IFS='|' read -r VNI L R; do
            printf "%-8s %-18s %-18s\n" "$VNI" "$L" "$R"
        done < "$VXLANS_FILE"
    else
        echo "(none)"
    fi
}
arp_static_add() {
    local IP="$1"; local MAC="$2"; local IFACE="$3"
    validate_ip "$IP"       || return 1
    validate_mac "$MAC"     || return 1
    validate_iface "$IFACE" || return 1
    arp -s "$IP" "$MAC" -i "$IFACE" 2>/dev/null \
        || ip neigh add "$IP" lladdr "$MAC" dev "$IFACE" nud permanent 2>/dev/null
    log OK "Static ARP: $IP -> $MAC on $IFACE"
}
arp_static_del() {
    local IP="$1"; local IFACE="$2"
    validate_ip "$IP"       || return 1
    validate_iface "$IFACE" || return 1
    ip neigh del "$IP" dev "$IFACE" 2>/dev/null
    log OK "Static ARP entry $IP removed from $IFACE."
}
_monitor_worker() {
    local TARGET="$1"; local INTERVAL="$2"
    local THRESHOLD="$3"; local ACTION="$4"
    local FAIL_COUNT=0; local DOWN=0
    while true; do
        if ping -c 1 -W 2 "$TARGET" &>/dev/null; then
            if (( DOWN == 1 )); then
                log WARN "[Monitor] $TARGET recovered."
                DOWN=0; FAIL_COUNT=0
            fi
        else
            (( FAIL_COUNT++ ))
            if (( FAIL_COUNT >= THRESHOLD && DOWN == 0 )); then
                log WARN "[Monitor] $TARGET UNREACHABLE after $FAIL_COUNT failures — running action"
                eval "$ACTION" 2>/dev/null
                DOWN=1
            fi
        fi
        sleep "$INTERVAL"
    done
}
monitor_add() {
    local TARGET="$1"; local INTERVAL="${2:-5}"
    local THRESHOLD="${3:-3}"; local ACTION="${4:-echo '[Monitor] target down'}"
    validate_ip "$TARGET"             || return 1
    validate_positive_int "$INTERVAL"  "interval"  || return 1
    validate_positive_int "$THRESHOLD" "threshold" || return 1
    _monitor_worker "$TARGET" "$INTERVAL" "$THRESHOLD" "$ACTION" &
    local PID=$!
    echo "${TARGET}|${INTERVAL}|${ACTION}|${PID}" >> "$MONITORS_FILE"
    log OK "IP-SLA monitor: $TARGET every ${INTERVAL}s, threshold=$THRESHOLD [PID $PID]"
}
monitor_list() {
    echo -e "${BOLD}--- IP-SLA Monitors ---${NC}"
    if [[ -s "$MONITORS_FILE" ]]; then
        printf "%-18s %-6s %s\n" "TARGET" "PID" "ACTION"
        while IFS='|' read -r TGT INT ACT PID; do
            local STATUS="running"
            kill -0 "$PID" 2>/dev/null || STATUS="dead"
            printf "%-18s %-6s [%-7s] %s\n" "$TGT" "$PID" "$STATUS" "$ACT"
        done < "$MONITORS_FILE"
    else
        echo "(none)"
    fi
}
monitor_remove() {
    local TARGET="$1"
    while IFS='|' read -r TGT _INT _ACT PID; do
        [[ "$TGT" == "$TARGET" ]] && kill "$PID" 2>/dev/null
    done < "$MONITORS_FILE"
    grep -v "^${TARGET}|" "$MONITORS_FILE" > "${MONITORS_FILE}.tmp" \
        && mv "${MONITORS_FILE}.tmp" "$MONITORS_FILE"
    log OK "Monitor for $TARGET removed."
}
config_save() {
    local NAME="$1"
    require_args "$NAME" 1 "config save <name>" || return 1
    local FILE="$CONFIGS_DIR/${NAME}.cfg"
    {
        echo "# NetCoreOS config saved: $(date)"
        echo "MODE=${MODE}"
        echo "BR=${BR}"
        echo "WAN_IF=${WAN_IF}"
        echo "# Routes"
        cat "$ROUTES_FILE"
        echo "# Sub-interfaces"
        cat "$SUBIFS_FILE"
        echo "# Bonds"
        cat "$BONDS_FILE"
        echo "# VXLANs"
        cat "$VXLANS_FILE"
        echo "# QoS applied"
        cat "$QOS_FILE"
    } > "$FILE"
    log OK "Config saved to $FILE"
}
config_list() {
    echo -e "${BOLD}--- Saved Configs ---${NC}"
    ls "$CONFIGS_DIR"/*.cfg 2>/dev/null | while read -r f; do
        echo "  $(basename "$f" .cfg)   ($(head -1 "$f"))"
    done || echo "(none)"
}
config_delete() {
    local NAME="$1"
    require_args "$NAME" 1 "config delete <name>" || return 1
    local FILE="$CONFIGS_DIR/${NAME}.cfg"
    if [[ -f "$FILE" ]]; then
        confirm "Delete config '$NAME'?" && rm "$FILE" && log OK "Config '$NAME' deleted."
    else
        log ERROR "Config '$NAME' not found."
    fi
}
config_load() {
    local NAME="$1"
    require_args "$NAME" 1 "config load <name>" || return 1
    local FILE="$CONFIGS_DIR/${NAME}.cfg"
    [[ -f "$FILE" ]] || { log ERROR "Config '$NAME' not found. Use: config list"; return 1; }
    confirm "Load '$NAME'? This will tear down current mode/routes and re-apply the saved config." || return 1
    local SAVED_MODE SAVED_BR SAVED_WAN
    SAVED_MODE=$(grep -m1 '^MODE=' "$FILE" | cut -d= -f2-)
    SAVED_BR=$(grep -m1 '^BR=' "$FILE" | cut -d= -f2-)
    SAVED_WAN=$(grep -m1 '^WAN_IF=' "$FILE" | cut -d= -f2-)
    case "$MODE" in
        switch|switch-mls) cleanup_switch ;;
        router)             cleanup_router ;;
        firewall)           cleanup_firewall ;;
    esac
    MODE="${SAVED_MODE:-ncos}"
    BR="${SAVED_BR:-br0}"
    WAN_IF="${SAVED_WAN:-eth0}"
    log INFO "Loading config '$NAME' — mode: $MODE | bridge: $BR | WAN: $WAN_IF"
    case "$MODE" in
        switch)     create_bridge; log OK "Switch mode re-applied." ;;
        switch-mls) create_bridge; enable_ip_forward; log OK "Switch-MLS mode re-applied." ;;
        router)     enable_ip_forward; log OK "Router mode re-applied." ;;
        firewall)   log OK "Firewall mode ready." ;;
        *)          log INFO "NCOS mode — no bridge needed." ;;
    esac
    local SECTION=""
    while IFS= read -r LINE; do
        case "$LINE" in
            "# Routes")         SECTION="routes"; continue ;;
            "# Sub-interfaces") SECTION="subifs"; continue ;;
            "# Bonds")          SECTION="bonds";  continue ;;
            "# VXLANs")         SECTION="vxlans"; continue ;;
            "# QoS applied")    SECTION="qos";    continue ;;
            \#*|"")             continue ;;
            MODE=*|BR=*|WAN_IF=*) continue ;;
        esac
        case "$SECTION" in
            routes)
                ip route add $LINE 2>/dev/null && track_route "$LINE" \
                    && log OK "  Route: $LINE" ;;
            subifs)
                if [[ "$LINE" == *.* ]]; then
                    local PARENT="${LINE%%.*}" VID="${LINE##*.}"
                    ip link add link "$PARENT" name "$LINE" type vlan id "$VID" 2>/dev/null
                    ip link set "$LINE" up 2>/dev/null && track_subif "$LINE" \
                        && log OK "  Sub-interface: $LINE"
                fi ;;
            bonds)
                local BOND="${LINE%%|*}" MEMBERS_CSV="${LINE#*|}"
                [[ -n "$BOND" && "$LINE" == *"|"* ]] || continue
                local MLIST=(); IFS=',' read -ra MLIST <<< "$MEMBERS_CSV"
                lacp_create "$BOND" "${MLIST[@]}" 2>/dev/null && log OK "  Bond: $BOND" ;;
            vxlans)
                IFS='|' read -r VNI LOC REM DEV <<< "$LINE"
                [[ -n "$VNI" ]] && vxlan_create "$VNI" "$LOC" "$REM" "$DEV" 2>/dev/null \
                    && log OK "  VXLAN: $VNI" ;;
            qos)
                IFS='|' read -r QPOLICY QIFACE _ <<< "$LINE"
                [[ -n "$QPOLICY" && -n "$QIFACE" ]] && qos_apply "$QPOLICY" "$QIFACE" 2>/dev/null \
                    && log OK "  QoS: $QPOLICY on $QIFACE" ;;
        esac
    done < "$FILE"
    log OK "Config '$NAME' loaded and applied."
}
alias_set() {
    local NAME="$1"; shift; local CMD_STR="$*"
    require_args "$NAME" 1 "alias set <name> <command>" || return 1
    grep -v "^${NAME}=" "$ALIASES_FILE" > "${ALIASES_FILE}.tmp" \
        && mv "${ALIASES_FILE}.tmp" "$ALIASES_FILE"
    echo "${NAME}=${CMD_STR}" >> "$ALIASES_FILE"
    log OK "Alias '${NAME}' -> '${CMD_STR}'"
}
alias_list() {
    echo -e "${BOLD}--- Aliases ---${NC}"
    [[ -s "$ALIASES_FILE" ]] && cat "$ALIASES_FILE" || echo "(none)"
}
alias_delete() {
    local NAME="$1"
    require_args "$NAME" 1 "alias delete <name>" || return 1
    grep -v "^${NAME}=" "$ALIASES_FILE" > "${ALIASES_FILE}.tmp" \
        && mv "${ALIASES_FILE}.tmp" "$ALIASES_FILE"
    log OK "Alias '$NAME' removed."
}
alias_resolve() {
    local INPUT="$1"
    local KEY="${INPUT%% *}"
    local REST="${INPUT#* }"
    [[ "$REST" == "$KEY" ]] && REST=""
    local MATCH
    MATCH=$(grep "^${KEY}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -n "$MATCH" ]]; then
        echo "${MATCH} ${REST}"
    else
        echo ""
    fi
}
dashboard() {
    if [[ "$WEBEXEC_MODE" == "1" ]]; then
        echo "(interactive command, not available via web/schedule)"
        return 1
    fi
    local REFRESH="${1:-2}"
    local ROWS COLS
    local _DASH_EXIT=0
    tput civis
    trap '_DASH_EXIT=1' INT
    while (( ! _DASH_EXIT )); do
        ROWS=$(tput lines)
        COLS=$(tput cols)
        tput clear
        tput cup 0 0
        printf "${BOLD}${CYAN}%-${COLS}s${NC}" " NetCoreOS Dashboard  |  Mode: $MODE  |  Uptime: $(uptime_str)  |  Press Ctrl+C to exit"
        tput cup 2 0
        echo -e "${BOLD}INTERFACES${NC}"
        local ROW=3
        while IFS= read -r LINE; do
            tput cup $ROW 0
            printf "%-${COLS}s" "$LINE"
            (( ROW++ ))
            (( ROW >= ROWS/3 )) && break
        done < <(ip -br link 2>/dev/null)
        tput cup $ROW 0; (( ROW++ ))
        echo -e "${BOLD}ROUTES${NC}"
        while IFS= read -r LINE; do
            tput cup $ROW 0
            printf "%-${COLS}s" "$LINE"
            (( ROW++ ))
            (( ROW >= ROWS*2/3 )) && break
        done < <(ip route 2>/dev/null)
        tput cup $ROW 0; (( ROW++ ))
        echo -e "${BOLD}FIREWALL CHAIN (hit counts)${NC}"
        while IFS= read -r LINE; do
            tput cup $ROW 0
            printf "%-${COLS}s" "$LINE"
            (( ROW++ ))
            (( ROW >= ROWS - 2 )) && break
        done < <(iptables -L "$FW_CHAIN" -v -n 2>/dev/null || echo "(not initialized)")
        tput cup $(( ROWS - 1 )) 0
        printf "${DIM}%-${COLS}s${NC}" " Refreshing every ${REFRESH}s  |  Log: $LOG_FILE"
        sleep "$REFRESH"
    done
    tput cnorm
    trap 'echo; continue' INT
    echo -e "\n${DIM}Exited dashboard — back to $MODE mode.${NC}"
}
show_status() {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
    printf "${BOLD}${CYAN}║${NC}  %-36s${BOLD}${CYAN}║${NC}\n" "$VERSION"
    printf "${BOLD}${CYAN}║${NC}  Mode: %-30s${BOLD}${CYAN}║${NC}\n" "$MODE"
    printf "${BOLD}${CYAN}║${NC}  Uptime: %-28s${BOLD}${CYAN}║${NC}\n" "$(uptime_str)"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}\n"
    _section "Interfaces"
    ip -br link
    _section "IP Addresses"
    ip -br addr
    _section "VLAN Table"
    bridge vlan 2>/dev/null || echo "(no bridge)"
    _section "MAC Table"
    bridge fdb show 2>/dev/null | grep -v "permanent" | head -20 || echo "(no bridge)"
    _section "Routes"
    ip route
    _section "Firewall Chain: $FW_CHAIN"
    iptables -L "$FW_CHAIN" -v -n 2>/dev/null || echo "(not initialized)"
    _section "VXLAN Tunnels"
    vxlan_show
    _section "Tracked Sub-Interfaces"
    [[ -s "$SUBIFS_FILE" ]] && cat "$SUBIFS_FILE" || echo "(none)"
    _section "Bonds / LACP"
    if [[ -s "$BONDS_FILE" ]]; then
        while IFS='|' read -r BOND MEMBERS; do
            printf "  %-12s members: %s\n" "$BOND" "$MEMBERS"
        done < "$BONDS_FILE"
    else
        echo "(none)"
    fi
    _section "IP-SLA Monitors"
    monitor_list
    _section "DHCP Processes"
    if [[ -s "$DNSMASQ_PIDS_FILE" ]]; then
        while read -r p; do
            printf "PID %-6s : %s\n" "$p" "$(ps -p "$p" -o args= 2>/dev/null || echo 'not running')"
        done < "$DNSMASQ_PIDS_FILE"
    else
        echo "(none)"
    fi
}
_section() {
    echo -e "\n${BOLD}── $1 $( printf '─%.0s' $(seq 1 $(( 40 - ${#1} ))) )${NC}"
}
show_acl_matrix() {
    local VLANS
    VLANS=$(bridge vlan 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+$' | sort -u)
    local IFS_LIST=()
    for V in $VLANS; do
        ip link show "${BR}.${V}" &>/dev/null && IFS_LIST+=("${BR}.${V}")
    done
    if [[ ${#IFS_LIST[@]} -eq 0 ]]; then
        log WARN "No VLAN sub-interfaces found for matrix."
        return
    fi
    echo -e "${BOLD}--- ACL Matrix (✔=ALLOW  ✘=DENY  ?=unset) ---${NC}"
    printf "%-16s" "SRC \\ DST"
    for DST in "${IFS_LIST[@]}"; do printf "%-14s" "$DST"; done
    echo ""
    for SRC in "${IFS_LIST[@]}"; do
        printf "%-16s" "$SRC"
        for DST in "${IFS_LIST[@]}"; do
            if [[ "$SRC" == "$DST" ]]; then
                printf "%-14s" "  —"
            else
                local DENY ALLOW
                DENY=$(iptables -L "$FW_CHAIN" -n 2>/dev/null \
                    | grep -c "DROP.*${SRC}.*${DST}" || true)
                ALLOW=$(iptables -L "$FW_CHAIN" -n 2>/dev/null \
                    | grep -c "ACCEPT.*${SRC}.*${DST}" || true)
                if (( DENY > 0 )); then
                    printf "${RED}%-14s${NC}" "  ✘"
                elif (( ALLOW > 0 )); then
                    printf "${GREEN}%-14s${NC}" "  ✔"
                else
                    printf "${DIM}%-14s${NC}" "  ?"
                fi
            fi
        done
        echo ""
    done
}
show_running_config() {
    echo -e "${BOLD}${CYAN}! NetCoreOS running-config (live state — not a saved file)${NC}"
    echo "! mode: $MODE   bridge: $BR   wan: $WAN_IF   $(date)"
    _section "Interfaces"
    ip -br addr
    if [[ -s "$DESC_FILE" ]]; then
        while IFS='|' read -r DIF DTXT; do
            [[ -n "$DIF" ]] && printf "  %-14s description: %s\n" "$DIF" "$DTXT"
        done < "$DESC_FILE"
    fi
    if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
        _section "VLANs"
        bridge vlan 2>/dev/null
        _section "SVIs"
        svi_show
    fi
    _section "Routes (IPv4)"
    ip -4 route 2>/dev/null
    _section "Routes (IPv6)"
    ip -6 route 2>/dev/null
    if [[ "$MODE" == "router" && -s "$VRFS_FILE" ]]; then
        _section "VRFs"
        while IFS='|' read -r VN VT; do
            [[ -n "$VN" ]] || continue
            local VM
            VM=$(ip -o link show 2>/dev/null | awk -F': ' -v n="$VN" '$0 ~ ("master "n" "){print $2}' | paste -sd, -)
            printf "  %-14s table %-6s members: %s\n" "$VN" "$VT" "${VM:-(none)}"
        done < "$VRFS_FILE"
    fi
    if [[ -s "$PORTSEC_FILE" ]]; then
        _section "Port Security"
        while IFS='|' read -r PIF PMAC; do
            [[ -n "$PIF" ]] && printf "  %-14s locked to %s\n" "$PIF" "$PMAC"
        done < "$PORTSEC_FILE"
    fi
    [[ -s "$BONDS_FILE" ]]  && { _section "LACP Bonds";    lacp_show; }
    [[ -s "$VXLANS_FILE" ]] && { _section "VXLAN Tunnels"; vxlan_show; }
    if iptables -L "$FW_CHAIN" &>/dev/null; then
        _section "Firewall (chain: $FW_CHAIN)"
        iptables -L "$FW_CHAIN" -v -n 2>/dev/null
        if [[ -s "$ACLV2_FILE" ]]; then
            echo ""
            printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" SEQ DIR IFACE ACTION PROTO SRC DST PORT
            while IFS='|' read -r SEQ DIR AIF ACT PROTO SRC DST PORT; do
                [[ -n "$SEQ" ]] && printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" \
                    "$SEQ" "$DIR" "$AIF" "$ACT" "$PROTO" "$SRC" "$DST" "${PORT:-any}"
            done < "$ACLV2_FILE"
        fi
    fi
    if [[ -s "$DNSMASQ_PIDS_FILE" ]]; then
        _section "DHCP / DHCPv6 servers"
        while IFS= read -r PID; do
            [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null \
                && ps -p "$PID" -o args= 2>/dev/null | sed 's/^/  /'
        done < "$DNSMASQ_PIDS_FILE"
    fi
    if [[ "$MODE" == "router" ]] && _frr_running; then
        _section "OSPF"; _show_ospf "" 2>/dev/null
        _section "BGP";  _show_bgp ""  2>/dev/null
    fi
    [[ -s "$VRRP_FILE" ]] && { _section "VRRP"; _vrrp_cmd show 2>/dev/null; }
    echo -e "\n${DIM}! end${NC}"
}
show_tech_support() {
    local DEST="$BASE_DIR/netcoreos_tech-support_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "=== NetCoreOS tech-support bundle ==="
        echo "Generated: $(date)"
        echo ""
        echo "=== show version ==="
        do_version
        echo ""
        echo "=== show health ==="
        do_health
        echo ""
        echo "=== show running-config ==="
        show_running_config
        echo ""
        echo "=== Recent log (last 200 lines) ==="
        tail -200 "$LOG_FILE" 2>/dev/null
    } 2>&1 | tee "$DEST"
    echo ""
    log OK "Tech-support bundle saved: $DEST"
}
show_log() {
    local LINES="${1:-50}"
    echo -e "${BOLD}--- Last $LINES log entries ($LOG_FILE) ---${NC}"
    tail -n "$LINES" "$LOG_FILE"
}
_frr_installed() {
    command -v vtysh &>/dev/null && return 0
    command -v frr  &>/dev/null && return 0
    return 1
}
_frr_running() { systemctl is-active frr &>/dev/null 2>&1; }
_frr_check_install() {
    if ! _frr_installed; then
        log ERROR "FRR is not installed."
        log INFO  "  Debian/Ubuntu: apt install frr frr-pythontools"
        log INFO  "  RHEL/Rocky:    dnf install frr"
        log INFO  "After install, run: frr status"
        return 1
    fi
    return 0
}
_vtysh() {
    _frr_check_install || return 1
    vtysh -c "$*" 2>&1
}
_vtysh_multi() {
    _frr_check_install || return 1
    local ARGS=()
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        ARGS+=("-c" "$LINE")
    done <<< "$1"
    [[ ${#ARGS[@]} -eq 0 ]] && return 0
    vtysh "${ARGS[@]}" 2>&1
}
_vtysh_conf() {
    _frr_check_install || return 1
    local ARGS=("-c" "configure terminal")
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        ARGS+=("-c" "$LINE")
    done <<< "$1"
    ARGS+=("-c" "end" "-c" "write memory")
    vtysh "${ARGS[@]}" 2>&1
    log INFO "FRR config written."
}
_frr_ensure_started() {
    _frr_check_install || return 1
    if ! _frr_running; then
        log INFO "Starting FRR..."
        systemctl start frr 2>/dev/null
        local TRIES=0
        while ! _frr_running && (( TRIES < 8 )); do sleep 0.5; (( TRIES++ )); done
        if ! _frr_running; then
            log ERROR "FRR failed to start."
            log INFO  "Check: systemctl status frr"
            log INFO  "Check: journalctl -u frr -n 20"
            return 1
        fi
        touch "$BASE_DIR/.frr_started_by_netcoreos"
        log OK "FRR started."
    fi
    return 0
}
_frr_stop_graceful() {
    if _frr_running; then
        log INFO "Stopping FRR..."
        systemctl stop frr 2>/dev/null && log INFO "FRR stopped."
    fi
}
_frr_enable_daemon() {
    local D="$1"
    if [[ ! -f "$FRR_DAEMONS" ]]; then
        log WARN "FRR daemons file not found at $FRR_DAEMONS"
        return 1
    fi
    if grep -q "^${D}=" "$FRR_DAEMONS"; then
        sed -i "s/^${D}=.*/${D}=yes/" "$FRR_DAEMONS"
    else
        echo "${D}=yes" >> "$FRR_DAEMONS"
    fi
    if grep -q "^zebra=" "$FRR_DAEMONS"; then
        sed -i "s/^zebra=.*/zebra=yes/" "$FRR_DAEMONS"
    else
        echo "zebra=yes" >> "$FRR_DAEMONS"
    fi
    log INFO "FRR daemon ${D} enabled."
}
_frr_admin() {
    case "$1" in
        status)
            if ! _frr_installed; then
                echo -e "${RED}[-] FRR is NOT installed${NC}"
                echo -e "    Install: ${CYAN}apt install frr frr-pythontools${NC}  (Debian/Ubuntu)"
                echo -e "             ${CYAN}dnf install frr${NC}  (RHEL/Rocky)"
                return 1
            fi
            if _frr_running; then
                echo -e "${GREEN}[+] FRR is running${NC}"
                systemctl status frr --no-pager 2>/dev/null | grep -E "Active:|Loaded:|Main PID:"
                echo ""
                _vtysh "show version" 2>/dev/null | head -5
                echo -e "\n${BOLD}Enabled daemons:${NC}"
                grep "=yes" "$FRR_DAEMONS" 2>/dev/null | sed 's/^/  /' || echo "  (file not found)"
                echo -e "\n${BOLD}Running processes:${NC}"
                ps aux 2>/dev/null | grep -E "zebra|ospfd|bgpd|bfdd|rpkid" \
                    | grep -v grep | awk '{printf "  %-20s PID:%s\n",$11,$2}'
            else
                echo -e "${YELLOW}[!] FRR installed but not running${NC}"
                echo -e "    Start: ${CYAN}frr restart${NC}"
                echo -e "    Logs:  ${CYAN}frr logs${NC}"
            fi ;;
        restart)
            _frr_check_install || return 1
            systemctl restart frr 2>/dev/null && log OK "FRR restarted." || log ERROR "Restart failed." ;;
        stop)   _frr_stop_graceful ;;
        logs)
            journalctl -u frr -n 80 --no-pager 2>/dev/null \
                || tail -80 /var/log/frr/frr.log 2>/dev/null \
                || log ERROR "No FRR logs found." ;;
        version)
            _frr_check_install || return 1
            _vtysh "show version" ;;
        daemons)
            echo -e "${BOLD}FRR Daemon Config ($FRR_DAEMONS):${NC}"
            grep -v "^#\|^$" "$FRR_DAEMONS" 2>/dev/null | sed 's/^/  /' \
                || log ERROR "$FRR_DAEMONS not found" ;;
        running-config)
            _frr_ensure_started || return 1
            _vtysh "show running-config" ;;
        install-help)
            echo -e "${BOLD}Installing FRR:${NC}"
            echo "  Debian/Ubuntu:  apt install frr frr-pythontools"
            echo "  RHEL/Rocky:     dnf install frr"
            echo "  Arch:           pacman -S frr"
            echo ""
            echo -e "${BOLD}After install:${NC}"
            echo "  1. Edit $FRR_DAEMONS — set zebra=yes + your protocol daemons"
            echo "  2. systemctl enable frr && systemctl start frr"
            echo "  3. Run: frr status"
            echo ""
            echo -e "${BOLD}NetCoreOS auto-enables daemons when you use:${NC}"
            echo "  ospf enable   — enables zebra + ospfd"
            echo "  bgp as <ASN>  — enables zebra + bgpd"
            echo "  bfd enable    — enables zebra + bfdd" ;;
        *) log ERROR "Usage: frr status|restart|stop|logs|version|daemons|running-config|install-help" ;;
    esac
}
_ospf_cmd() {
    local INPUT="$*"
    read -ra _OARGS <<< "$INPUT"
    local SUBCMD="${_OARGS[0]}"; local ARGS=("${_OARGS[@]:1}")
    case "$SUBCMD" in
        enable)
            _frr_enable_daemon zebra; _frr_enable_daemon ospfd
            _frr_ensure_started || return 1
            log OK "OSPF enabled (zebra + ospfd running)."
            log INFO "Next: ospf router-id <ip>  /  ospf network <prefix> area 0" ;;
        disable)
            _frr_ensure_started || return 1
            _vtysh_conf "no router ospf"
            log OK "OSPF disabled." ;;
        router-id)
            validate_ip "${ARGS[0]}" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "router ospf
 ospf router-id ${ARGS[0]}"
            log OK "OSPF router-id ${ARGS[0]}" ;;
        network)
            local PREFIX="${ARGS[0]}" AREA="${ARGS[2]}"
            [[ -z "$PREFIX" || -z "$AREA" ]] && { log ERROR "Usage: ospf network <prefix/len> area <id>"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router ospf
 network ${PREFIX} area ${AREA}"
            log OK "OSPF: $PREFIX in area $AREA" ;;
        cost)
            validate_iface "${ARGS[0]}" && validate_positive_int "${ARGS[1]}" cost || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "interface ${ARGS[0]}
 ip ospf cost ${ARGS[1]}"
            log OK "OSPF cost ${ARGS[1]} on ${ARGS[0]}" ;;
        hello)
            validate_iface "${ARGS[0]}" && validate_positive_int "${ARGS[1]}" interval || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "interface ${ARGS[0]}
 ip ospf hello-interval ${ARGS[1]}
 ip ospf dead-interval $(( ${ARGS[1]} * 4 ))"
            log OK "OSPF hello ${ARGS[1]}s on ${ARGS[0]}" ;;
        passive)
            validate_iface "${ARGS[0]}" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "router ospf
 passive-interface ${ARGS[0]}"
            log OK "OSPF: ${ARGS[0]} set passive" ;;
        auth)
            [[ -z "${ARGS[0]}" || -z "${ARGS[1]}" ]] && { log ERROR "Usage: ospf auth <iface> <key>"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "interface ${ARGS[0]}
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${ARGS[1]}"
            log OK "OSPF MD5 auth on ${ARGS[0]}" ;;
        redistribute)
            [[ -z "${ARGS[0]}" ]] && { log ERROR "Usage: ospf redistribute connected|static|bgp"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router ospf
 redistribute ${ARGS[0]}"
            log OK "OSPF redistributing ${ARGS[0]}" ;;
        area)
            [[ -z "${ARGS[0]}" ]] && { log ERROR "Usage: ospf area <id>"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router ospf
 area ${ARGS[0]} authentication"
            log OK "OSPF area ${ARGS[0]} configured" ;;
        *) log ERROR "Unknown ospf subcommand: $SUBCMD. Type 'help' for usage." ;;
    esac
}
_show_ospf() {
    _frr_ensure_started || return 1
    case "$1" in
        neighbors|neighbor) _vtysh "show ip ospf neighbor" ;;
        routes|route)       _vtysh "show ip ospf route" ;;
        database|db)        _vtysh "show ip ospf database" ;;
        interface|iface)    _vtysh "show ip ospf interface" ;;
        *)                  _vtysh "show ip ospf" ;;
    esac
}
_bgp_cmd() {
    local INPUT="$*"
    read -ra _BARGS <<< "$INPUT"
    local SUBCMD="${_BARGS[0]}"; local ARGS=("${_BARGS[@]:1}")
    local ASN; ASN=$(grep "^BGP_ASN=" "$BGP_FILE" 2>/dev/null | cut -d= -f2)
    case "$SUBCMD" in
        as)
            validate_positive_int "${ARGS[0]}" ASN || return 1
            _frr_enable_daemon zebra; _frr_enable_daemon bgpd
            _frr_ensure_started || return 1
            echo "BGP_ASN=${ARGS[0]}" > "$BGP_FILE"
            _vtysh_conf "router bgp ${ARGS[0]}"
            log OK "BGP AS ${ARGS[0]} configured."
            log INFO "Next: bgp router-id <ip>  /  bgp neighbor <ip> remote-as <asn>" ;;
        disable)
            [[ -z "$ASN" ]] && { log ERROR "No BGP AS configured."; return 1; }
            _vtysh_conf "no router bgp ${ASN}"; > "$BGP_FILE"
            log OK "BGP disabled." ;;
        router-id)
            [[ -z "$ASN" ]] && { log ERROR "Run 'bgp as <asn>' first"; return 1; }
            validate_ip "${ARGS[0]}" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "router bgp ${ASN}
 bgp router-id ${ARGS[0]}"
            log OK "BGP router-id ${ARGS[0]}" ;;
        neighbor)
            local NIP="${ARGS[0]}" ACTION="${ARGS[1]}"
            [[ -z "$NIP" || -z "$ACTION" ]] && { log ERROR "Usage: bgp neighbor <ip> <action> ..."; return 1; }
            [[ -z "$ASN" ]] && { log ERROR "Run 'bgp as <asn>' first"; return 1; }
            validate_ip "$NIP" || return 1
            _frr_ensure_started || return 1
            case "$ACTION" in
                remote-as)
                    validate_positive_int "${ARGS[2]}" "remote-AS" || return 1
                    _vtysh_conf "router bgp ${ASN}
 neighbor ${NIP} remote-as ${ARGS[2]}"
                    _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  neighbor ${NIP} activate
 exit-address-family"
                    log OK "BGP neighbor $NIP AS${ARGS[2]} added and activated." ;;
                description)
                    local DESC="${ARGS[*]:2}"
                    _vtysh_conf "router bgp ${ASN}
 neighbor ${NIP} description ${DESC}"
                    log OK "BGP neighbor $NIP description set." ;;
                password)
                    [[ -z "${ARGS[2]}" ]] && { log ERROR "Usage: bgp neighbor <ip> password <key>"; return 1; }
                    _vtysh_conf "router bgp ${ASN}
 neighbor ${NIP} password ${ARGS[2]}"
                    log OK "BGP neighbor $NIP MD5 password set." ;;
                prefix-list)
                    [[ -z "${ARGS[2]}" || -z "${ARGS[3]}" ]] && { log ERROR "Usage: bgp neighbor <ip> prefix-list <n> in|out"; return 1; }
                    _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  neighbor ${NIP} prefix-list ${ARGS[2]} ${ARGS[3]}
 exit-address-family"
                    log OK "BGP neighbor $NIP prefix-list ${ARGS[2]} ${ARGS[3]}" ;;
                route-map)
                    [[ -z "${ARGS[2]}" || -z "${ARGS[3]}" ]] && { log ERROR "Usage: bgp neighbor <ip> route-map <n> in|out"; return 1; }
                    _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  neighbor ${NIP} route-map ${ARGS[2]} ${ARGS[3]}
 exit-address-family"
                    log OK "BGP neighbor $NIP route-map ${ARGS[2]} ${ARGS[3]}" ;;
                shutdown)
                    _vtysh_conf "router bgp ${ASN}
 neighbor ${NIP} shutdown"
                    log OK "BGP neighbor $NIP shut down." ;;
                activate)
                    _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  neighbor ${NIP} activate
 exit-address-family"
                    log OK "BGP neighbor $NIP activated." ;;
                remove)
                    _vtysh_conf "router bgp ${ASN}
 no neighbor ${NIP}"
                    log OK "BGP neighbor $NIP removed." ;;
                *) log ERROR "Unknown neighbor action: $ACTION" ;;
            esac ;;
        network)
            [[ -z "${ARGS[0]}" ]] && { log ERROR "Usage: bgp network <prefix/len>"; return 1; }
            [[ -z "$ASN" ]] && { log ERROR "Run 'bgp as <asn>' first"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  network ${ARGS[0]}
 exit-address-family"
            log OK "BGP advertising ${ARGS[0]}" ;;
        redistribute)
            [[ -z "${ARGS[0]}" ]] && { log ERROR "Usage: bgp redistribute ospf|connected|static"; return 1; }
            [[ -z "$ASN" ]] && { log ERROR "Run 'bgp as <asn>' first"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router bgp ${ASN}
 address-family ipv4 unicast
  redistribute ${ARGS[0]}
 exit-address-family"
            log OK "BGP redistributing ${ARGS[0]}" ;;
        timers)
            [[ -z "$ASN" ]] && { log ERROR "Run 'bgp as <asn>' first"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "router bgp ${ASN}
 timers bgp ${ARGS[0]} ${ARGS[1]}"
            log OK "BGP timers: keepalive=${ARGS[0]}s hold=${ARGS[1]}s" ;;
        *) log ERROR "Unknown bgp subcommand: $SUBCMD. Type 'help' for usage." ;;
    esac
}
_show_bgp() {
    _frr_ensure_started || return 1
    case "$1" in
        summary)            _vtysh "show bgp summary" ;;
        routes|table)       _vtysh "show bgp ipv4 unicast" ;;
        neighbors|neighbor) _vtysh "show bgp neighbors" ;;
        advertised)
            [[ -z "$2" ]] && { log ERROR "Usage: show bgp advertised <neighbor>"; return 1; }
            _vtysh "show bgp neighbors $2 advertised-routes" ;;
        received)
            [[ -z "$2" ]] && { log ERROR "Usage: show bgp received <neighbor>"; return 1; }
            _vtysh "show bgp neighbors $2 received-routes" ;;
        *)                  _vtysh "show bgp summary" ;;
    esac
}
_routemap_cmd() {
    local SUBCMD="$1"; shift; local ARGS=("$@")
    case "$SUBCMD" in
        create)
            local NAME="${ARGS[0]}" ACTION="${ARGS[1]}" SEQ="${ARGS[2]:-10}"
            [[ -z "$NAME" || -z "$ACTION" ]] && { log ERROR "Usage: routemap create <n> permit|deny [seq]"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "route-map ${NAME} ${ACTION} ${SEQ}"
            grep -q "^${NAME}|" "$ROUTEMAP_FILE" 2>/dev/null || echo "${NAME}|${ACTION}|${SEQ}" >> "$ROUTEMAP_FILE"
            log OK "Route-map $NAME $ACTION $SEQ created." ;;
        match)
            local NAME="${ARGS[0]}" TYPE="${ARGS[1]}" VAL="${ARGS[2]}"
            [[ -z "$NAME" || -z "$TYPE" || -z "$VAL" ]] && { log ERROR "Usage: routemap match <n> prefix-list|as-path|community <val>"; return 1; }
            _frr_ensure_started || return 1
            local META; META=$(grep "^${NAME}|" "$ROUTEMAP_FILE" 2>/dev/null | head -1)
            local ACT; ACT=$(echo "$META" | cut -d'|' -f2); ACT="${ACT:-permit}"
            local SEQ; SEQ=$(echo "$META" | cut -d'|' -f3); SEQ="${SEQ:-10}"
            case "$TYPE" in
                prefix-list) _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 match ip address prefix-list ${VAL}" ;;
                as-path)     _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 match as-path ${VAL}" ;;
                community)   _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 match community ${VAL}" ;;
                *) log ERROR "Type must be: prefix-list|as-path|community"; return 1 ;;
            esac
            log OK "Route-map $NAME: match $TYPE $VAL" ;;
        set)
            local NAME="${ARGS[0]}" ATTR="${ARGS[1]}" VAL="${ARGS[2]}"
            [[ -z "$NAME" || -z "$ATTR" || -z "$VAL" ]] && { log ERROR "Usage: routemap set <n> <attr> <val>"; return 1; }
            _frr_ensure_started || return 1
            local META; META=$(grep "^${NAME}|" "$ROUTEMAP_FILE" 2>/dev/null | head -1)
            local ACT; ACT=$(echo "$META" | cut -d'|' -f2); ACT="${ACT:-permit}"
            local SEQ; SEQ=$(echo "$META" | cut -d'|' -f3); SEQ="${SEQ:-10}"
            case "$ATTR" in
                local-pref)      _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set local-preference ${VAL}" ;;
                community)       _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set community ${VAL}" ;;
                metric)          _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set metric ${VAL}" ;;
                as-path-prepend) _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set as-path prepend ${VAL}" ;;
                weight)          _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set weight ${VAL}" ;;
                origin)          _vtysh_conf "route-map ${NAME} ${ACT} ${SEQ}
 set origin ${VAL}" ;;
                *) log ERROR "Unknown attribute: $ATTR"; return 1 ;;
            esac
            log OK "Route-map $NAME: set $ATTR $VAL" ;;
        show)
            _frr_running && _vtysh "show route-map" || { echo "${BOLD}Saved route-maps:${NC}"; cat "$ROUTEMAP_FILE" 2>/dev/null || echo "(none)"; } ;;
        delete)
            local NAME="${ARGS[0]}"
            [[ -z "$NAME" ]] && { log ERROR "Usage: routemap delete <n>"; return 1; }
            _frr_ensure_started || return 1
            local META; META=$(grep "^${NAME}|" "$ROUTEMAP_FILE" 2>/dev/null | head -1)
            local ACT; ACT=$(echo "$META" | cut -d'|' -f2); ACT="${ACT:-permit}"
            local SEQ; SEQ=$(echo "$META" | cut -d'|' -f3); SEQ="${SEQ:-10}"
            _vtysh_conf "no route-map ${NAME} ${ACT} ${SEQ}"
            sed -i "/^${NAME}|/d" "$ROUTEMAP_FILE"
            log OK "Route-map $NAME deleted." ;;
        *) log ERROR "Usage: routemap create|match|set|show|delete" ;;
    esac
}
_prefixlist_cmd() {
    local SUBCMD="$1"; shift; local ARGS=("$@")
    case "$SUBCMD" in
        create)
            local NAME="${ARGS[0]}" ACTION="${ARGS[1]}" PREFIX="${ARGS[2]}"
            [[ -z "$NAME" || -z "$ACTION" || -z "$PREFIX" ]] && {
                log ERROR "Usage: prefix-list create <n> permit|deny <prefix> [le <n>] [ge <n>]"
                return 1
            }
            local QUAL="" i=3
            while (( i < ${#ARGS[@]} )); do
                case "${ARGS[$i]}" in
                    le) (( i++ )); QUAL="$QUAL le ${ARGS[$i]}" ;;
                    ge) (( i++ )); QUAL="$QUAL ge ${ARGS[$i]}" ;;
                esac
                (( i++ ))
            done
            _frr_ensure_started || return 1
            _vtysh_conf "ip prefix-list ${NAME} seq 10 ${ACTION} ${PREFIX}${QUAL}"
            echo "${NAME}|${ACTION}|${PREFIX}${QUAL}" >> "$PREFIXLIST_FILE"
            log OK "Prefix-list $NAME: $ACTION $PREFIX$QUAL" ;;
        show)
            _frr_running && _vtysh "show ip prefix-list" || { echo "${BOLD}Saved prefix-lists:${NC}"; cat "$PREFIXLIST_FILE" 2>/dev/null || echo "(none)"; } ;;
        delete)
            local NAME="${ARGS[0]}"
            [[ -z "$NAME" ]] && { log ERROR "Usage: prefix-list delete <n>"; return 1; }
            _frr_ensure_started || return 1
            _vtysh_conf "no ip prefix-list ${NAME}"
            sed -i "/^${NAME}|/d" "$PREFIXLIST_FILE"
            log OK "Prefix-list $NAME deleted." ;;
        *) log ERROR "Usage: prefix-list create|show|delete" ;;
    esac
}
_bfd_cmd() {
    local INPUT="$*"
    read -ra _BFDARGS <<< "$INPUT"
    local SUBCMD="${_BFDARGS[0]}"; local ARGS=("${_BFDARGS[@]:1}")
    case "$SUBCMD" in
        enable)
            _frr_enable_daemon zebra; _frr_enable_daemon bfdd
            _frr_ensure_started || return 1
            log OK "BFD daemon enabled (sub-second failure detection)."
            log INFO "Next: bfd peer <ip>  or  bfd ospf <iface>  or  bfd bgp <peer-ip>" ;;
        peer)
            local PEER="${ARGS[0]}"
            [[ -z "$PEER" ]] && { log ERROR "Usage: bfd peer <ip>"; return 1; }
            validate_ip "$PEER" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "bfd
 peer ${PEER}"
            grep -q "^${PEER}$" "$BFD_FILE" 2>/dev/null || echo "${PEER}" >> "$BFD_FILE"
            log OK "BFD peer $PEER configured." ;;
        ospf)
            local IFACE="${ARGS[0]}"
            validate_iface "$IFACE" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "interface ${IFACE}
 ip ospf bfd"
            log OK "BFD enabled on OSPF interface $IFACE (fast failure detection active)." ;;
        bgp)
            local PEER="${ARGS[0]}"
            local ASN; ASN=$(grep "^BGP_ASN=" "$BGP_FILE" 2>/dev/null | cut -d= -f2)
            [[ -z "$ASN" ]] && { log ERROR "Configure BGP first: bgp as <asn>"; return 1; }
            validate_ip "$PEER" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "router bgp ${ASN}
 neighbor ${PEER} bfd"
            log OK "BFD enabled on BGP neighbor $PEER." ;;
        show)
            _frr_ensure_started || return 1
            echo -e "${BOLD}BFD Peers:${NC}"
            _vtysh "show bfd peers" 2>/dev/null || echo "(no BFD peers configured)"
            echo -e "\n${BOLD}BFD Counters:${NC}"
            _vtysh "show bfd peers counters" 2>/dev/null ;;
        remove)
            local PEER="${ARGS[0]}"
            validate_ip "$PEER" || return 1
            _frr_ensure_started || return 1
            _vtysh_conf "no bfd
 no peer ${PEER}"
            sed -i "/^${PEER}$/d" "$BFD_FILE"
            log OK "BFD peer $PEER removed." ;;
        *) log ERROR "Usage: bfd enable | bfd peer <ip> | bfd ospf <iface> | bfd bgp <peer> | bfd show | bfd remove <ip>" ;;
    esac
}
_rpki_cmd() {
    local SUBCMD="$1"; shift; local ARGS=("$@")
    case "$SUBCMD" in
        enable)
            local VALIDATOR="${ARGS[0]}" PORT="${ARGS[1]:-323}"
            [[ -z "$VALIDATOR" ]] && { log ERROR "Usage: rpki enable <validator-ip> [port]"; return 1; }
            validate_ip "$VALIDATOR" || return 1
            _frr_enable_daemon rpkid
            _frr_ensure_started || return 1
            _vtysh_conf "rpki
 rpki cache ${VALIDATOR} ${PORT} preference 1"
            log OK "RPKI validator $VALIDATOR:$PORT configured."
            log INFO "Public RTR servers: rtr.rpki.cloudflare.com:8282  |  rpki-validator.realmv6.org:8323" ;;
        disable)
            _frr_ensure_started || return 1
            _vtysh_conf "no rpki"
            log OK "RPKI disabled." ;;
        enforce)
            _frr_ensure_started || return 1
            _vtysh_conf "route-map RPKI-FILTER deny 10
 match rpki invalid
route-map RPKI-FILTER permit 20"
            log OK "RPKI enforcement route-map RPKI-FILTER created."
            log INFO "Apply: bgp neighbor <ip> route-map RPKI-FILTER in" ;;
        *) log ERROR "Usage: rpki enable <validator-ip> [port]|disable|enforce" ;;
    esac
}
_show_rpki() {
    _frr_ensure_started || return 1
    echo -e "${BOLD}RPKI Cache Connections:${NC}"
    _vtysh "show rpki cache-connection" 2>/dev/null || echo "(not configured)"
    echo -e "\n${BOLD}RPKI Prefix Table (first 30):${NC}"
    _vtysh "show rpki prefix-table" 2>/dev/null | head -30 || echo "(no data)"
    echo -e "\n${BOLD}RPKI Counters:${NC}"
    _vtysh "show rpki counter" 2>/dev/null || echo "(no data)"
}
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"
_vrrp_installed() { command -v keepalived &>/dev/null; }
_vrrp_cmd() {
    local SUBCMD="$1"; shift; local ARGS=("$@")
    case "$SUBCMD" in
        create)
            local VRID="${ARGS[0]}" IFACE="${ARGS[1]}" VIP="${ARGS[2]}" PRIO=100
            local i=3
            while (( i < ${#ARGS[@]} )); do
                [[ "${ARGS[$i]}" == priority ]] && (( i++ )) && PRIO="${ARGS[$i]}"
                (( i++ ))
            done
            [[ -z "$VRID" || -z "$IFACE" || -z "$VIP" ]] && {
                log ERROR "Usage: vrrp create <vrid> <iface> <vip> [priority <n>]"
                log INFO  "Example: vrrp create 1 eth0 192.168.1.100 priority 110"
                return 1
            }
            validate_positive_int "$VRID" VRID || return 1
            validate_iface "$IFACE" || return 1
            validate_ip "$VIP" || return 1
            if ! _vrrp_installed; then
                log ERROR "keepalived not installed. Install: apt install keepalived"
                return 1
            fi
            mkdir -p /etc/keepalived /var/log/netcoreos
            [[ ! -f "$KEEPALIVED_CONF" ]] && echo "global_defs { router_id NETCOREOS }" > "$KEEPALIVED_CONF"
            local STATE; [[ "$PRIO" -ge 100 ]] && STATE=MASTER || STATE=BACKUP
            cat >> "$KEEPALIVED_CONF" << VCONF

vrrp_instance VRRP_${VRID} {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id ${VRID}
    priority ${PRIO}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass nc${VRID}pass
    }
    virtual_ipaddress {
        ${VIP}
    }
    notify_master "/bin/bash -c 'echo [\$(date)] VRRP_${VRID} MASTER >> /var/log/netcoreos/vrrp.log'"
    notify_backup "/bin/bash -c 'echo [\$(date)] VRRP_${VRID} BACKUP >> /var/log/netcoreos/vrrp.log'"
    notify_fault  "/bin/bash -c 'echo [\$(date)] VRRP_${VRID} FAULT >> /var/log/netcoreos/vrrp.log'"
}
VCONF
            echo "${VRID}|${IFACE}|${VIP}|${PRIO}" >> "$VRRP_FILE"
            systemctl enable keepalived 2>/dev/null
            systemctl restart keepalived 2>/dev/null && log OK "VRRP $VRID: VIP=$VIP iface=$IFACE prio=$PRIO state=$STATE" \
                || log ERROR "keepalived failed to start. Check: systemctl status keepalived"
            ;;
        remove)
            [[ -z "${ARGS[0]}" ]] && { log ERROR "Usage: vrrp remove <vrid>"; return 1; }
            local VRID="${ARGS[0]}"
            if [[ -f "$KEEPALIVED_CONF" ]]; then
                python3 -c "
import re
with open('$KEEPALIVED_CONF') as f: t=f.read()
t=re.sub(r'\nvrrp_instance VRRP_${VRID}\s*\{[^}]*\}','',t,flags=re.DOTALL)
with open('$KEEPALIVED_CONF','w') as f: f.write(t)
" 2>/dev/null
            fi
            sed -i "/^${VRID}|/d" "$VRRP_FILE"
            systemctl restart keepalived 2>/dev/null
            log OK "VRRP $VRID removed." ;;
        show)
            echo -e "${BOLD}VRRP Instances:${NC}"
            if [[ -s "$VRRP_FILE" ]]; then
                printf "  %-6s %-12s %-20s %-6s %-8s\n" "VRID" "IFACE" "VIP" "PRIO" "STATE"
                while IFS='|' read -r VID IF VIP PRI; do
                    local ST; ip addr show "$IF" 2>/dev/null | grep -q "$VIP" && ST="${GREEN}MASTER${NC}" || ST="${DIM}BACKUP${NC}"
                    printf "  %-6s %-12s %-20s %-6s " "$VID" "$IF" "$VIP" "$PRI"
                    echo -e "$ST"
                done < "$VRRP_FILE"
            else echo -e "  ${DIM}(none)${NC}"; fi
            systemctl is-active keepalived &>/dev/null \
                && echo -e "\n  keepalived: ${GREEN}running${NC}" \
                || echo -e "\n  keepalived: ${RED}stopped${NC}" ;;
        *) log ERROR "Usage: vrrp create|remove|show" ;;
    esac
}
_vrrp_cleanup_all() {
    [[ -s "$VRRP_FILE" ]] && _vrrp_installed && {
        systemctl stop keepalived 2>/dev/null
        log INFO "VRRP (keepalived) stopped."
    }
}
_frr_show_dispatch() {
    local WHAT="$1" EXTRA="$2"
    case "$WHAT" in
        "ospf neighbors"|"ospf neighbor") _show_ospf neighbors ;;
        "ospf routes"|"ospf route")       _show_ospf routes ;;
        "ospf database"|"ospf db")        _show_ospf database ;;
        "ospf interface"|"ospf iface")    _show_ospf interface ;;
        ospf)                             _show_ospf ;;
        "bgp summary")     _show_bgp summary ;;
        "bgp routes"|"bgp table") _show_bgp routes ;;
        "bgp neighbors"|"bgp neighbor") _show_bgp neighbors ;;
        "bgp advertised")  _show_bgp advertised "$EXTRA" ;;
        "bgp received")    _show_bgp received   "$EXTRA" ;;
        bgp)               _show_bgp summary ;;
        rpki)              _show_rpki ;;
        *) return 1 ;;
    esac
    return 0
}
do_version() {
    case "$MODE" in
        ncos)
            echo -e "${BOLD}Version  :${NC} NetCoreOS 0.1 ${DIM}(internal 5.0)${NC}"
            echo -e "${BOLD}Kernel   :${NC} $KERNEL_VER"
            ;;
        switch|switch-mls)
            echo -e "${BOLD}Version  :${NC} NetCoreOS SW 0.1 ${DIM}(internal sw5.0)${NC}"
            echo -e "${BOLD}Kernel   :${NC} $KERNEL_VER"
            ;;
        router)
            echo -e "${BOLD}Version  :${NC} NetCoreOS R 0.1 ${DIM}(internal r5.0)${NC}"
            echo -e "${BOLD}Kernel   :${NC} $KERNEL_VER"
            ;;
        firewall)
            echo -e "${BOLD}Version  :${NC} NetCoreOS FW 0.1 ${DIM}(internal fw5.0)${NC}"
            echo -e "${BOLD}Kernel   :${NC} $KERNEL_VER"
            ;;
    esac
}
log_search() {
    local KW="$1"
    [[ -z "$KW" ]] && { log ERROR "Usage: log search <keyword>"; return 1; }
    [[ ! -f "$LOG_FILE" ]] && { log WARN "Log file not found."; return 1; }
    local COUNT; COUNT=$(grep -ic "$KW" "$LOG_FILE" 2>/dev/null || echo 0)
    echo -e "${BOLD}--- Search: '${CYAN}${KW}${NC}${BOLD}' -- ${COUNT} match(es) ---${NC}"
    grep --color=always -i "$KW" "$LOG_FILE" 2>/dev/null | tail -200 \
        || echo -e "${DIM}(no matches)${NC}"
}
schedule_add() {
    local DELAY="$1"; shift; local CMD_STR="$*"
    [[ -z "$DELAY" || -z "$CMD_STR" ]] && { log ERROR "Usage: schedule <seconds> <command>"; return 1; }
    validate_positive_int "$DELAY" "seconds" || return 1
    (
        sleep "$DELAY"
        log INFO "[SCHEDULE] Running: $CMD_STR"
        bash "$0" --web-exec "$CMD_STR" 2>&1 | while IFS= read -r L; do log INFO "[SCHEDULE] $L"; done
    ) &
    local SPID=$!
    local TS; TS=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${SPID}|${DELAY}|${TS}|${CMD_STR}" >> "$SCHEDULES_FILE"
    log OK "Scheduled in ${DELAY}s: '${CMD_STR}' (PID $SPID)"
}
schedule_list() {
    if [[ ! -s "$SCHEDULES_FILE" ]]; then echo -e "${DIM}(no scheduled tasks)${NC}"; return; fi
    echo -e "${BOLD}--- Scheduled Tasks ---${NC}"
    printf "  %-8s %-8s %-22s %s\n" "PID" "DELAY" "AT" "COMMAND"
    while IFS='|' read -r PID DELAY TS CMD_STR; do
        local S; kill -0 "$PID" 2>/dev/null && S="${GREEN}pending${NC}" || S="${DIM}done${NC}"
        printf "  %-8s %-8s %-22s " "$PID" "${DELAY}s" "$TS"
        echo -e "${CMD_STR}  [${S}]"
    done < "$SCHEDULES_FILE"
}
schedule_cancel() {
    local PID="$1"
    [[ -z "$PID" ]] && { log ERROR "Usage: schedule cancel <pid>"; return 1; }
    if kill "$PID" 2>/dev/null; then
        sed -i "/^${PID}|/d" "$SCHEDULES_FILE" 2>/dev/null
        log OK "Schedule PID $PID cancelled."
    else log WARN "PID $PID not found or already done."; fi
}
backup_create() {
    local NAME="$1"
    [[ -z "$NAME" ]] && { log ERROR "Usage: backup <n>"; return 1; }
    mkdir -p "$BACKUPS_DIR"
    local FILE="$BACKUPS_DIR/${NAME}.tar.gz"
    local TMP; TMP=$(mktemp -d)
    log INFO "Creating backup '$NAME'..."
    mkdir -p "$TMP/netcoreos" "$TMP/network"
    for F in "$ROUTES_FILE" "$SUBIFS_FILE" "$BONDS_FILE" "$VXLANS_FILE" \
             "$QOS_FILE" "$MONITORS_FILE" "$BRIDGE_MEMBERS_FILE" \
             "$ALIASES_FILE" "$DNSMASQ_PIDS_FILE" "$SCHEDULES_FILE"; do
        [[ -f "$F" ]] && cp "$F" "$TMP/netcoreos/" 2>/dev/null
    done
    [[ -d "$CONFIGS_DIR" ]] && cp -r "$CONFIGS_DIR" "$TMP/netcoreos/configs" 2>/dev/null
    printf "# NetCoreOS backup: %s\n# Created: %s\nMODE=%s\nBR=%s\nWAN_IF=%s\n" \
        "$NAME" "$(date)" "$MODE" "$BR" "$WAN_IF" > "$TMP/netcoreos/env.conf"
    ip addr show  > "$TMP/network/ip_addr.txt"  2>/dev/null
    ip route show > "$TMP/network/ip_route.txt" 2>/dev/null
    iptables-save > "$TMP/network/iptables.txt" 2>/dev/null
    tc qdisc show > "$TMP/network/tc_qdisc.txt" 2>/dev/null
    bridge vlan   > "$TMP/network/vlans.txt"     2>/dev/null
    [[ -f "$LOG_FILE" ]] && cp "$LOG_FILE" "$TMP/netcoreos.log"
    tar -czf "$FILE" -C "$TMP" . 2>/dev/null
    local RC=$?; rm -rf "$TMP"
    if [[ $RC -eq 0 ]]; then
        local SZ; SZ=$(du -sh "$FILE" 2>/dev/null | awk '{print $1}')
        log OK "Backup '$NAME' saved to $FILE ($SZ)"
    else log ERROR "Backup failed."; return 1; fi
}
backup_list() {
    echo -e "${BOLD}--- Saved Backups ($BACKUPS_DIR) ---${NC}"
    local N=0
    while IFS= read -r F; do
        local NM; NM=$(basename "$F" .tar.gz)
        local SZ; SZ=$(du -sh "$F" 2>/dev/null | awk '{print $1}')
        local MT; MT=$(stat -c '%y' "$F" 2>/dev/null | cut -d'.' -f1)
        printf "  ${CYAN}%-20s${NC}  %-6s  %s\n" "$NM" "$SZ" "$MT"
        (( N++ ))
    done < <(ls "$BACKUPS_DIR"/*.tar.gz 2>/dev/null)
    [[ $N -eq 0 ]] && echo -e "  ${DIM}(no backups)${NC}"
}
backup_delete() {
    local NAME="$1"
    [[ -z "$NAME" ]] && { log ERROR "Usage: backup delete <n>"; return 1; }
    local FILE="$BACKUPS_DIR/${NAME}.tar.gz"
    if [[ -f "$FILE" ]]; then
        confirm "Delete backup '$NAME'?" && rm "$FILE" && log OK "Backup '$NAME' deleted."
    else log ERROR "Backup '$NAME' not found."; fi
}
restore_backup() {
    local NAME="$1"
    [[ -z "$NAME" ]] && { log ERROR "Usage: restore <n>"; return 1; }
    local FILE="$BACKUPS_DIR/${NAME}.tar.gz"
    [[ ! -f "$FILE" ]] && { log ERROR "Backup '$NAME' not found. Use: backup list"; return 1; }
    confirm "Restore '$NAME'? This will tear down current config and re-apply the backup." || return
    local TMP; TMP=$(mktemp -d)
    log INFO "Extracting backup '$NAME'..."
    tar -xzf "$FILE" -C "$TMP" 2>/dev/null || { log ERROR "Extraction failed."; rm -rf "$TMP"; return 1; }
    log INFO "Tearing down current live config..."
    if [[ -s "$MONITORS_FILE" ]]; then
        while IFS='|' read -r _ _ _ PID; do [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; done < "$MONITORS_FILE"
        > "$MONITORS_FILE"
    fi
    if [[ -s "$DNSMASQ_PIDS_FILE" ]]; then
        while IFS= read -r pid; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done < "$DNSMASQ_PIDS_FILE"
        > "$DNSMASQ_PIDS_FILE"
    fi
    if iptables -L "$FW_CHAIN" &>/dev/null 2>&1; then
        iptables -F "$FW_CHAIN" 2>/dev/null
        iptables -D FORWARD -j "$FW_CHAIN" 2>/dev/null
        iptables -X "$FW_CHAIN" 2>/dev/null
        iptables -t nat -F "${FW_CHAIN}_NAT" 2>/dev/null
        iptables -t nat -D POSTROUTING -j "${FW_CHAIN}_NAT" 2>/dev/null
        iptables -t nat -X "${FW_CHAIN}_NAT" 2>/dev/null
    fi
    if [[ -s "$QOS_FILE" ]]; then
        while IFS='|' read -r IFACE _; do [[ -n "$IFACE" ]] && tc qdisc del dev "$IFACE" root 2>/dev/null; done < "$QOS_FILE"
        > "$QOS_FILE"
    fi
    if [[ -s "$VXLANS_FILE" ]]; then
        while IFS='|' read -r VNI _; do [[ -n "$VNI" ]] && ip link del "vxlan${VNI}" 2>/dev/null; done < "$VXLANS_FILE"
        > "$VXLANS_FILE"
    fi
    if [[ -s "$SUBIFS_FILE" ]]; then
        while IFS= read -r SUBIF; do [[ -n "$SUBIF" ]] && ip link del "$SUBIF" 2>/dev/null; done < "$SUBIFS_FILE"
        > "$SUBIFS_FILE"
    fi
    if [[ -s "$ROUTES_FILE" ]]; then
        while IFS= read -r route; do
            [[ -n "$route" ]] && ip route del $route 2>/dev/null
        done < "$ROUTES_FILE"
        > "$ROUTES_FILE"
    fi
    if [[ -s "$BONDS_FILE" ]]; then
        while IFS='|' read -r BOND _; do [[ -n "$BOND" ]] && lacp_remove "$BOND" 2>/dev/null; done < <(cat "$BONDS_FILE")
        > "$BONDS_FILE"
    fi
    _bridge_restore_all_members 2>/dev/null
    if ip link show "$BR" &>/dev/null 2>&1; then
        ip link set "$BR" down 2>/dev/null && ip link del "$BR" 2>/dev/null
    fi
    log OK "Current live config torn down."
    log INFO "Restoring state files..."
    for DIR in "$TMP/netcoreos" "$TMP/silentos"; do
        [[ -d "$DIR" ]] || continue
        for F in "$DIR/"*.list "$DIR/"*.conf "$DIR/"*.cfg; do
            [[ -f "$F" ]] && cp "$F" "$BASE_DIR/" 2>/dev/null
        done
        [[ -d "$DIR/configs" ]] && cp -r "$DIR/configs/." "$CONFIGS_DIR/" 2>/dev/null
    done
    log OK "State files restored."
    for ENV_FILE in "$TMP/netcoreos/env.conf" "$TMP/silentos/env.conf"; do
        if [[ -f "$ENV_FILE" ]]; then
            source "$ENV_FILE" 2>/dev/null
            MODE="${MODE:-ncos}"; BR="${BR:-br0}"; WAN_IF="${WAN_IF:-eth0}"
            log INFO "Saved mode: $MODE | bridge: $BR | WAN: $WAN_IF"
            break
        fi
    done
    log INFO "Re-applying mode: $MODE"
    case "$MODE" in
        switch)     create_bridge; log OK "Switch mode re-applied." ;;
        switch-mls) create_bridge; enable_ip_forward; log OK "Switch-MLS mode re-applied." ;;
        router)     enable_ip_forward; log OK "Router mode re-applied." ;;
        firewall)   log OK "Firewall mode ready." ;;
        *)          log INFO "Linux mode — no bridge needed." ;;
    esac
    if [[ -f "$TMP/network/vlans.txt" ]] && [[ "$MODE" == switch* ]]; then
        log INFO "Restoring VLAN assignments..."
        while IFS= read -r L; do
            [[ "$L" =~ ^[^[:space:]] ]] || continue
            local VID; VID=$(echo "$L" | awk '{print $1}')
            [[ "$VID" =~ ^[0-9]+$ ]] && bridge vlan add dev "$BR" vid "$VID" self 2>/dev/null
        done < "$TMP/network/vlans.txt"
        log OK "VLANs restored."
    fi
    if [[ -s "$BONDS_FILE" ]]; then
        log INFO "Re-applying LACP bonds..."
        while IFS='|' read -r BOND MEMBERS; do
            [[ -z "$BOND" ]] && continue
            IFS=',' read -ra MLIST <<< "$MEMBERS"
            lacp_create "$BOND" "${MLIST[@]}" 2>/dev/null && log OK "  Bond $BOND restored."
        done < "$BONDS_FILE"
    fi
    if [[ -s "$VXLANS_FILE" ]]; then
        log INFO "Re-applying VXLAN tunnels..."
        while IFS='|' read -r VNI LOCAL REMOTE DEV; do
            [[ -z "$VNI" ]] && continue
            vxlan_create "$VNI" "$LOCAL" "$REMOTE" "$DEV" 2>/dev/null && log OK "  VXLAN VNI $VNI restored."
        done < "$VXLANS_FILE"
    fi
    if [[ -f "$TMP/network/ip_addr.txt" ]]; then
        log INFO "Re-applying IP addresses..."
        while IFS= read -r L; do
            if [[ "$L" =~ ^[[:space:]]+inet[[:space:]]([0-9./]+).*scope\ global\ ([^[:space:]]+) ]]; then
                ip addr add "${BASH_REMATCH[1]}" dev "${BASH_REMATCH[2]}" 2>/dev/null \
                    && log INFO "  IP ${BASH_REMATCH[1]} on ${BASH_REMATCH[2]}"
            fi
        done < "$TMP/network/ip_addr.txt"
        log OK "IP addresses restored."
    fi
    if [[ -s "$ROUTES_FILE" ]]; then
        log INFO "Re-applying static routes..."
        while IFS= read -r route; do
            [[ -z "$route" ]] && continue
            ip route add $route 2>/dev/null && log INFO "  Route: $route"
        done < "$ROUTES_FILE"
        log OK "Static routes restored."
    fi
    if [[ -f "$TMP/network/iptables.txt" ]]; then
        iptables-restore < "$TMP/network/iptables.txt" 2>/dev/null \
            && log OK "Firewall rules restored." \
            || log WARN "Could not restore iptables (may need manual: firewall init)."
    fi
    if [[ -s "$QOS_FILE" ]]; then
        log INFO "Re-applying QoS policies..."
        while IFS='|' read -r POLICY IFACE _; do
            [[ -z "$POLICY" || -z "$IFACE" ]] && continue
            qos_apply "$POLICY" "$IFACE" 2>/dev/null && log OK "  QoS $POLICY on $IFACE."
        done < "$QOS_FILE"
    fi
    rm -rf "$TMP"
    log OK "Backup '$NAME' fully restored and re-applied."
    log OK "Mode: $MODE | Bridge: $BR | WAN: $WAN_IF"
}
do_health() {
    echo -e "\n${BOLD}${CYAN}========== NetCoreOS Health Report ==========${NC}"
    echo -e " $(date)   Mode: ${BOLD}${MODE}${NC}\n"
    local CPU; CPU=$(top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print $2}' | tr -d '%us,')
    echo -e "${BOLD}[CPU]${NC}  ${CPU:-?}% used   load: $(cat /proc/loadavg 2>/dev/null)"
    echo -e "${BOLD}[Memory]${NC}"
    free -h 2>/dev/null | awk 'NR==2{printf "  RAM:  used %-8s / %-8s\n",$3,$2}
                               NR==3{printf "  Swap: used %-8s / %-8s\n",$3,$2}'
    echo -e "${BOLD}[Disk]${NC}   $(df -h "$BASE_DIR" 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}')"
    echo -e "${BOLD}[Interfaces]${NC}"
    while IFS= read -r LINE; do
        local IF ST; IF=$(echo "$LINE"|awk '{print $1}'); ST=$(echo "$LINE"|awk '{print $2}')
        local ERR; ERR=$(cat "/sys/class/net/${IF}/statistics/rx_errors" 2>/dev/null||echo 0)
        local DRP; DRP=$(cat "/sys/class/net/${IF}/statistics/rx_dropped" 2>/dev/null||echo 0)
        local COL="${GREEN}"; [[ "$ST" != UP ]] && COL="${DIM}"
        [[ "$ERR" -gt 0 || "$DRP" -gt 0 ]] && COL="${YELLOW}"
        printf "  ${COL}%-18s${NC} %-8s errors:%-5s drops:%s\n" "$IF" "$ST" "$ERR" "$DRP"
    done < <(ip -br link show 2>/dev/null)
    local GW; GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    echo -e "${BOLD}[Gateway]${NC} ${GW:-none}"
    [[ -n "$GW" ]] && echo -e "  ping: $(ping -c2 -W2 "$GW" 2>/dev/null | tail -1 | awk -F'/' '{print $5}') ms"
    echo -e "${BOLD}[Firewall]${NC}"
    if iptables -L "$FW_CHAIN" &>/dev/null 2>&1; then
        local RC; RC=$({ iptables -L "$FW_CHAIN" 2>/dev/null | grep -c '^[A-Z]' || echo 0; } | tail -1)
        echo -e "  ${GREEN}initialized${NC} -- $RC rules in $FW_CHAIN"
    else echo -e "  ${DIM}not initialized${NC}"; fi
    echo -e "${BOLD}[Monitors]${NC}"
    if [[ -s "$MONITORS_FILE" ]]; then
        while IFS='|' read -r TGT INT _ PID; do
            kill -0 "$PID" 2>/dev/null \
                && echo -e "  ${GREEN}* ${NC} $TGT (every ${INT}s)" \
                || echo -e "  ${RED}* ${NC} $TGT ${DIM}dead PID $PID${NC}"
        done < "$MONITORS_FILE"
    else echo -e "  ${DIM}none${NC}"; fi
    echo -e "${BOLD}[Bonds]${NC}"
    if [[ -s "$BONDS_FILE" ]]; then
        while IFS='|' read -r BOND MEM; do
            local BS; BS=$(cat "/sys/class/net/${BOND}/operstate" 2>/dev/null||echo unknown)
            printf "  %-14s members:%-18s state:%s\n" "$BOND" "$MEM" "$BS"
        done < "$BONDS_FILE"
    else echo -e "  ${DIM}none${NC}"; fi
    echo -e "${BOLD}[VXLANs]${NC}"
    if [[ -s "$VXLANS_FILE" ]]; then
        while IFS='|' read -r VNI LOC REM; do
            printf "  VNI %-8s %s <-> %s\n" "$VNI" "$LOC" "$REM"
        done < "$VXLANS_FILE"
    else echo -e "  ${DIM}none${NC}"; fi
    echo -e "${BOLD}[Log]${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        local TOT ERR WRN OKS
        TOT=$(wc -l < "$LOG_FILE" 2>/dev/null||echo 0)
        ERR=$({ grep -c '\[ERROR\]' "$LOG_FILE" 2>/dev/null || echo 0; } | tail -1)
        WRN=$({ grep -c '\[WARN\]'  "$LOG_FILE" 2>/dev/null || echo 0; } | tail -1)
        OKS=$({ grep -c '\[OK\]'    "$LOG_FILE" 2>/dev/null || echo 0; } | tail -1)
        echo -e "  total:$TOT  ${GREEN}ok:$OKS${NC}  ${YELLOW}warn:$WRN${NC}  ${RED}errors:$ERR${NC}"
        [[ "$ERR" -gt 0 ]] && grep '\[ERROR\]' "$LOG_FILE" | tail -3 | while IFS= read -r L; do
            echo -e "  ${RED}->$NC $L"; done
    else echo -e "  ${DIM}no log${NC}"; fi
    local PEND=0
    [[ -s "$SCHEDULES_FILE" ]] && while IFS='|' read -r PID _; do
        kill -0 "$PID" 2>/dev/null && (( PEND++ ))
    done < "$SCHEDULES_FILE"
    echo -e "${BOLD}[Scheduled]${NC}  pending: $PEND"
    echo -e "${BOLD}[FRR / Routing Protocols]${NC}"
    if _frr_running; then
        echo -e "  FRR: ${GREEN}running${NC}"
        _vtysh "show ip ospf neighbor" 2>/dev/null | grep -E "^[0-9]" | while read -r L; do
            echo -e "  OSPF neighbor: ${CYAN}$L${NC}"
        done
        local ASN; ASN=$(grep "^BGP_ASN=" "$BGP_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$ASN" ]]; then
            local PEERS; PEERS=$(_vtysh "show bgp summary" 2>/dev/null | grep -cE "^[0-9]")
            echo -e "  BGP AS${ASN}: ${CYAN}${PEERS:-0}${NC} peer(s)"
        fi
    else
        echo -e "  FRR: ${DIM}not running${NC}"
    fi
    echo -e "${BOLD}[VRRP]${NC}"
    if [[ -s "$VRRP_FILE" ]]; then
        while IFS='|' read -r VID IF VIP PRI; do
            local VST; ip addr show "$IF" 2>/dev/null | grep -q "$VIP" && VST="${GREEN}MASTER${NC}" || VST="${DIM}BACKUP${NC}"
            echo -e "  VRID $VID  VIP=$VIP  iface=$IF  prio=$PRI  state: $VST"
        done < "$VRRP_FILE"
    else echo -e "  ${DIM}none${NC}"; fi
    echo -e "${BOLD}${CYAN}============================================${NC}\n"
}
do_ping() {
    local TARGET="$1"; local COUNT="${2:-4}"
    validate_ip "$TARGET" || return 1
    validate_positive_int "$COUNT" "count" || return 1
    log CMD "ping -c $COUNT $TARGET"
    ping -c "$COUNT" "$TARGET"
}
do_traceroute() {
    local TARGET="$1"
    validate_ip "$TARGET" || return 1
    command -v traceroute &>/dev/null \
        || { log ERROR "traceroute not installed."; return 1; }
    log CMD "traceroute $TARGET"
    traceroute "$TARGET"
}
do_arp()    { log CMD "ip neigh show"; ip neigh show; }
do_netstat(){ log CMD "ss -tunap";     ss -tunap;     }
do_bandwidth() {
    local IFACE="$1"
    validate_iface "$IFACE" || return 1
    log CMD "Bandwidth snapshot on $IFACE (2s sample)"
    local RX1 TX1 RX2 TX2
    RX1=$(cat "/sys/class/net/${IFACE}/statistics/rx_bytes" 2>/dev/null || echo 0)
    TX1=$(cat "/sys/class/net/${IFACE}/statistics/tx_bytes" 2>/dev/null || echo 0)
    sleep 2
    RX2=$(cat "/sys/class/net/${IFACE}/statistics/rx_bytes" 2>/dev/null || echo 0)
    TX2=$(cat "/sys/class/net/${IFACE}/statistics/tx_bytes" 2>/dev/null || echo 0)
    local RX_RATE=$(( (RX2 - RX1) / 2 / 1024 ))
    local TX_RATE=$(( (TX2 - TX1) / 2 / 1024 ))
    echo -e "  ${GREEN}RX${NC}: ${RX_RATE} KB/s   ${YELLOW}TX${NC}: ${TX_RATE} KB/s"
}
show_versions() {
    echo -e "\n${BOLD}${CYAN}══════════ Installed Tool Versions ══════════${NC}"
    _ver() {
        local NAME="$1"; local CMD="$2"
        local VER
        VER=$(eval "$CMD" 2>/dev/null | head -1)
        if [[ -n "$VER" ]]; then
            printf "  ${GREEN}%-18s${NC} %s\n" "$NAME" "$VER"
        else
            printf "  ${DIM}%-18s not found${NC}\n" "$NAME"
        fi
    }
    echo -e "${BOLD}System:${NC}"
    printf "  ${GREEN}%-18s${NC} %s\n" "NetCoreOS" "$VERSION"
    printf "  ${GREEN}%-18s${NC} %s\n" "Author" "$AUTHOR"
    printf "  ${GREEN}%-18s${NC} %s\n" "Kernel" "$(uname -r)"
    printf "  ${GREEN}%-18s${NC} %s\n" "OS" "$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    printf "  ${GREEN}%-18s${NC} %s\n" "Uptime" "$(uptime_str)"
    echo -e "${BOLD}Networking:${NC}"
    _ver "iproute2 (ip)"   "ip -V"
    _ver "iptables"        "iptables --version"
    _ver "bridge-utils"    "bridge --version"
    _ver "tcpdump"         "tcpdump --version 2>&1"
    _ver "dnsmasq"         "dnsmasq --version"
    _ver "nmap"            "nmap --version"
    _ver "ethtool"         "ethtool --version"
    _ver "traceroute"      "traceroute --version 2>&1"
    _ver "mstpctl"         "mstpctl --version 2>&1"
    echo -e "${BOLD}Routing Protocols:${NC}"
    _ver "FRR (vtysh)"     "vtysh --version 2>&1"
    _ver "ospfd"           "ospfd --version 2>&1"
    _ver "bgpd"            "bgpd --version 2>&1"
    _ver "keepalived"      "keepalived --version 2>&1"
    echo -e "${BOLD}Tunnels / VPN:${NC}"
    _ver "wireguard (wg)"  "wg --version 2>&1"
    _ver "strongSwan"      "ipsec --version 2>/dev/null || swanctl --version 2>/dev/null"
    _ver "openvpn"         "openvpn --version 2>&1"
    echo -e "${BOLD}Tools:${NC}"
    _ver "python3"         "python3 --version"
    _ver "dig"             "dig -v 2>&1"
    _ver "whois"           "whois --version 2>&1"
    _ver "curl"            "curl --version"
    _ver "iperf3"          "iperf3 --version 2>&1"
    _ver "openssl"         "openssl version"
    _ver "chrony"          "chronyc --version 2>&1"
    echo -e "${BOLD}${CYAN}═════════════════════════════════════════════${NC}\n"
}
do_clear() { clear; }
show_log_live() {
    [[ ! -f "$LOG_FILE" ]] && { log WARN "No log file at $LOG_FILE."; return 1; }
    echo -e "${BOLD}${CYAN}Live log — press Ctrl+C to stop${NC}"
    echo -e "${DIM}$LOG_FILE${NC}\n"
    tail -f "$LOG_FILE"
}
arp_flush() {
    local IFACE="${1:-}"
    if [[ -n "$IFACE" ]]; then
        validate_iface "$IFACE" || return 1
        ip neigh flush dev "$IFACE" 2>/dev/null \
            && log OK "ARP cache flushed on $IFACE." \
            || log ERROR "Failed to flush ARP on $IFACE."
    else
        ip neigh flush all 2>/dev/null \
            && log OK "ARP cache fully flushed." \
            || log ERROR "Failed to flush ARP cache."
    fi
}
dns_set() {
    local SERVER="$1"
    [[ -z "$SERVER" ]] && {
        log ERROR "Usage: dns set <server_ip>"
        log INFO  "  Examples: dns set 8.8.8.8"
        log INFO  "            dns set 1.1.1.1"
        log INFO  "            dns set 9.9.9.9"
        return 1
    }
    validate_ip "$SERVER" || return 1
    if systemctl is-active systemd-resolved &>/dev/null; then
        local CONF="/etc/systemd/resolved.conf"
        if grep -q "^DNS=" "$CONF" 2>/dev/null; then
            sed -i "s/^DNS=.*/DNS=${SERVER}/" "$CONF"
        else
            echo "DNS=${SERVER}" >> "$CONF"
        fi
        systemctl restart systemd-resolved 2>/dev/null
        log OK "DNS set to $SERVER via systemd-resolved."
    else
        local RESOLV="/etc/resolv.conf"
        chattr -i "$RESOLV" 2>/dev/null
        local EXISTING
        EXISTING=$(grep -v "^nameserver" "$RESOLV" 2>/dev/null)
        {
            echo "# Set by NetCoreOS"
            echo "nameserver $SERVER"
            [[ -n "$EXISTING" ]] && echo "$EXISTING"
        } > "$RESOLV"
        log OK "DNS set to $SERVER in /etc/resolv.conf."
    fi
}
show_dns() {
    echo -e "\n${BOLD}${CYAN}══════════ DNS Configuration ══════════${NC}"
    _section "Current nameservers (/etc/resolv.conf)"
    if [[ -f /etc/resolv.conf ]]; then
        grep -E "^nameserver|^search|^domain" /etc/resolv.conf | \
            while read -r L; do echo "  $L"; done
    else
        echo -e "  ${DIM}(not found)${NC}"
    fi
    if systemctl is-active systemd-resolved &>/dev/null; then
        _section "systemd-resolved status"
        resolvectl status 2>/dev/null | grep -E "DNS Servers|DNS Domain|DNSSEC|Protocol" | \
            while read -r L; do echo "  $L"; done
    fi
    _section "DNS test (resolving google.com)"
    local RESULT
    RESULT=$(dig +short +time=3 A google.com 2>/dev/null | head -3)
    if [[ -n "$RESULT" ]]; then
        echo -e "  ${GREEN}[OK]${NC} DNS is working:"
        echo "$RESULT" | while read -r R; do echo "    $R"; done
    else
        echo -e "  ${RED}[FAIL]${NC} DNS not resolving. Check nameserver config."
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}\n"
}
dns_lookup() {
    local HOST="$1"
    require_args "$HOST" 1 "dns lookup <hostname>" || return 1
    local RESULT
    if command -v dig &>/dev/null; then
        RESULT=$(dig +short "$HOST" 2>/dev/null)
    elif command -v getent &>/dev/null; then
        RESULT=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}')
    else
        RESULT=$(host "$HOST" 2>/dev/null | awk '/has address/{print $4}')
    fi
    if [[ -n "$RESULT" ]]; then
        log OK "$HOST resolves to:"
        echo "$RESULT" | while read -r R; do echo "  $R"; done
    else
        log ERROR "Could not resolve '$HOST'."
    fi
}
do_whois() {
    local TARGET="$1"
    require_args "$TARGET" 1 "whois <ip|domain>" || return 1
    if ! command -v whois &>/dev/null; then
        log ERROR "'whois' is not installed (apt install whois)."
        return 1
    fi
    whois "$TARGET" 2>/dev/null | head -60
}
set_mtu() {
    local IFACE="$1" SIZE="$2"
    validate_iface "$IFACE" && validate_positive_int "$SIZE" "mtu" || {
        log ERROR "Usage: set mtu <iface> <size>"
        return 1
    }
    if ip link set dev "$IFACE" mtu "$SIZE" 2>/tmp/.ncos_err; then
        log OK "MTU on $IFACE set to $SIZE."
    else
        log ERROR "Failed to set MTU: $(cat /tmp/.ncos_err 2>/dev/null)"
    fi
    rm -f /tmp/.ncos_err
}
set_speed() {
    local IFACE="$1" SPEED="$2"
    validate_iface "$IFACE" || { log ERROR "Usage: set speed <iface> <10|100|1000|auto>"; return 1; }
    if ! command -v ethtool &>/dev/null; then
        log ERROR "'ethtool' is not installed (apt install ethtool)."
        return 1
    fi
    case "$SPEED" in
        10|100|1000|2500|10000)
            ethtool -s "$IFACE" speed "$SPEED" duplex full autoneg off 2>/tmp/.ncos_err \
                && log OK "Speed on $IFACE set to ${SPEED}Mb/s (autoneg off)." \
                || log ERROR "Failed to set speed: $(cat /tmp/.ncos_err 2>/dev/null)" ;;
        auto)
            ethtool -s "$IFACE" autoneg on 2>/tmp/.ncos_err \
                && log OK "Speed on $IFACE set to auto-negotiate." \
                || log ERROR "Failed to set autoneg: $(cat /tmp/.ncos_err 2>/dev/null)" ;;
        *) log ERROR "Usage: set speed <iface> <10|100|1000|auto>" ;;
    esac
    rm -f /tmp/.ncos_err
}
set_mac() {
    local IFACE="$1" MAC="$2"
    validate_iface "$IFACE" || { log ERROR "Usage: set mac <iface> <mac>"; return 1; }
    if [[ ! "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        log ERROR "Invalid MAC address: $MAC (expected format aa:bb:cc:dd:ee:ff)"
        return 1
    fi
    local WAS_UP=0
    ip link show "$IFACE" | grep -q "state UP" && WAS_UP=1
    ip link set dev "$IFACE" down 2>/dev/null
    if ip link set dev "$IFACE" address "$MAC" 2>/tmp/.ncos_err; then
        log OK "MAC on $IFACE set to $MAC."
    else
        log ERROR "Failed to set MAC: $(cat /tmp/.ncos_err 2>/dev/null)"
    fi
    (( WAS_UP )) && ip link set dev "$IFACE" up 2>/dev/null
    rm -f /tmp/.ncos_err
}
_ports_chain_ensure() {
    iptables -C INPUT -j NCOS_PORTS 2>/dev/null || {
        iptables -N NCOS_PORTS 2>/dev/null
        iptables -I INPUT -j NCOS_PORTS 2>/dev/null
    }
}
show_open_ports() {
    echo -e "\n${BOLD}${CYAN}══════════ Listening Ports ══════════${NC}"
    if command -v ss &>/dev/null; then
        ss -tulnp 2>/dev/null || ss -tuln 2>/dev/null
    else
        netstat -tulnp 2>/dev/null || netstat -tuln 2>/dev/null
    fi
    if [[ -s "$OPEN_PORTS_FILE" ]]; then
        _section "Explicitly opened by NetCoreOS (firewall rules)"
        while IFS='|' read -r PORT PROTO; do
            [[ -n "$PORT" ]] && echo "  $PORT/$PROTO"
        done < "$OPEN_PORTS_FILE"
    fi
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"
}
_resolve_port() {
    local P="$1"
    if [[ "$P" =~ ^[0-9]+$ ]]; then
        echo "$P"
    else
        getent services "$P" 2>/dev/null | awk -F'[/ ]+' '{print $2}' | head -1
    fi
}
open_port() {
    local RAW="$1" PROTO="${2:-both}"
    require_args "$RAW" 1 "open port <port/name> [tcp|udp|both]" || return 1
    local PORT; PORT=$(_resolve_port "$RAW")
    [[ -z "$PORT" ]] && { log ERROR "Unknown port/service: $RAW"; return 1; }
    _ports_chain_ensure
    local PROTOS=(); case "$PROTO" in
        tcp) PROTOS=(tcp) ;; udp) PROTOS=(udp) ;; both|"") PROTOS=(tcp udp) ;;
        *) log ERROR "Protocol must be: tcp|udp|both"; return 1 ;;
    esac
    for P in "${PROTOS[@]}"; do
        iptables -C NCOS_PORTS -p "$P" --dport "$PORT" -j ACCEPT 2>/dev/null || \
            iptables -A NCOS_PORTS -p "$P" --dport "$PORT" -j ACCEPT
        echo "${PORT}|${P}" >> "$OPEN_PORTS_FILE"
    done
    log OK "Port $PORT ($RAW) opened for: ${PROTOS[*]}"
}
close_port() {
    local RAW="$1" PROTO="${2:-both}"
    require_args "$RAW" 1 "close port <port/name> [tcp|udp|both]" || return 1
    local PORT; PORT=$(_resolve_port "$RAW")
    [[ -z "$PORT" ]] && { log ERROR "Unknown port/service: $RAW"; return 1; }
    local PROTOS=(); case "$PROTO" in
        tcp) PROTOS=(tcp) ;; udp) PROTOS=(udp) ;; both|"") PROTOS=(tcp udp) ;;
        *) log ERROR "Protocol must be: tcp|udp|both"; return 1 ;;
    esac
    for P in "${PROTOS[@]}"; do
        iptables -D NCOS_PORTS -p "$P" --dport "$PORT" -j ACCEPT 2>/dev/null
        [[ -f "$OPEN_PORTS_FILE" ]] && sed -i "\#^${PORT}|${P}\$#d" "$OPEN_PORTS_FILE"
    done
    log OK "Port $PORT ($RAW) closed for: ${PROTOS[*]}"
}
show_connections() {
    echo -e "\n${BOLD}${CYAN}══════════ Active Connections ══════════${NC}"
    if command -v ss &>/dev/null; then
        ss -tunp 2>/dev/null || ss -tun 2>/dev/null
    else
        netstat -tunp 2>/dev/null || netstat -tun 2>/dev/null
    fi
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"
}
_block_chain_ensure() {
    iptables -C INPUT -j NCOS_BLOCK 2>/dev/null || {
        iptables -N NCOS_BLOCK 2>/dev/null
        iptables -I INPUT -j NCOS_BLOCK 2>/dev/null
    }
    iptables -C FORWARD -j NCOS_BLOCK 2>/dev/null || {
        iptables -I FORWARD -j NCOS_BLOCK 2>/dev/null
    }
}
block_ip() {
    local IP="$1"
    validate_ip "$IP" || { log ERROR "Usage: block ip <ip>"; return 1; }
    _block_chain_ensure
    iptables -C NCOS_BLOCK -s "$IP" -j DROP 2>/dev/null || iptables -A NCOS_BLOCK -s "$IP" -j DROP
    grep -qxF "$IP" "$BLOCKED_IPS_FILE" 2>/dev/null || echo "$IP" >> "$BLOCKED_IPS_FILE"
    log OK "$IP blocked."
}
unblock_ip() {
    local IP="$1"
    validate_ip "$IP" || { log ERROR "Usage: unblock ip <ip>"; return 1; }
    iptables -D NCOS_BLOCK -s "$IP" -j DROP 2>/dev/null
    [[ -f "$BLOCKED_IPS_FILE" ]] && sed -i "\#^${IP}\$#d" "$BLOCKED_IPS_FILE"
    log OK "$IP unblocked."
}
show_blocked_ips() {
    echo -e "\n${BOLD}${CYAN}══════════ Blocked IPs ══════════${NC}"
    if [[ -s "$BLOCKED_IPS_FILE" ]]; then
        cat "$BLOCKED_IPS_FILE"
    else
        echo -e "  ${DIM}(none)${NC}"
    fi
    echo -e "${BOLD}${CYAN}══════════════════════════════════${NC}\n"
}
gre_create() {
    local NAME="$1" LOCAL="$2" REMOTE="$3" IPPFX="$4"
    [[ -z "$NAME" || -z "$LOCAL" || -z "$REMOTE" ]] && {
        log ERROR "Usage: gre create <n> <local> <remote> [ip/prefix]"
        return 1
    }
    validate_ip "$LOCAL" && validate_ip "$REMOTE" || return 1
    modprobe ip_gre 2>/dev/null
    if ip tunnel add "$NAME" mode gre local "$LOCAL" remote "$REMOTE" ttl 255 2>/tmp/.ncos_err; then
        ip link set "$NAME" up 2>/dev/null
        [[ -n "$IPPFX" ]] && { validate_cidr "$IPPFX" && ip addr add "$IPPFX" dev "$NAME" 2>/dev/null; }
        echo "${NAME}|${LOCAL}|${REMOTE}|${IPPFX}" >> "$GRE_FILE"
        log OK "GRE tunnel $NAME created ($LOCAL -> $REMOTE)."
    else
        log ERROR "Failed to create GRE tunnel: $(cat /tmp/.ncos_err 2>/dev/null)"
    fi
    rm -f /tmp/.ncos_err
}
gre_remove() {
    local NAME="$1"
    require_args "$NAME" 1 "gre remove <n>" || return 1
    ip link del "$NAME" 2>/dev/null && log OK "GRE tunnel $NAME removed." \
        || log ERROR "GRE tunnel '$NAME' not found."
    [[ -f "$GRE_FILE" ]] && sed -i "/^${NAME}|/d" "$GRE_FILE"
}
gre_show() {
    echo -e "\n${BOLD}${CYAN}══════════ GRE Tunnels ══════════${NC}"
    if [[ -s "$GRE_FILE" ]]; then
        printf "  %-12s %-16s %-16s %s\n" "NAME" "LOCAL" "REMOTE" "IP"
        while IFS='|' read -r N L R I; do
            [[ -n "$N" ]] && printf "  %-12s %-16s %-16s %s\n" "$N" "$L" "$R" "${I:-—}"
        done < "$GRE_FILE"
    else
        echo -e "  ${DIM}(none)${NC}"
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════${NC}\n"
}
_ipsec_installed() { command -v ipsec &>/dev/null; }
_ipsec_cmd() {
    local SUBCMD="$1"; shift; local ARGS=("$@")
    if ! _ipsec_installed; then
        log ERROR "strongSwan is not installed (apt install strongswan)."
        return 1
    fi
    case "$SUBCMD" in
        status)   ipsec statusall 2>&1 | head -60 ;;
        start)    systemctl start strongswan-starter 2>/dev/null || ipsec start 2>&1
                  log OK "IPsec started." ;;
        stop)     systemctl stop strongswan-starter 2>/dev/null || ipsec stop 2>&1
                  log OK "IPsec stopped." ;;
        restart)  systemctl restart strongswan-starter 2>/dev/null || ipsec restart 2>&1
                  log OK "IPsec restarted." ;;
        reload)   ipsec reload 2>&1; log OK "IPsec config reloaded." ;;
        list)
            echo -e "\n${BOLD}${CYAN}══════════ IPsec Tunnels ══════════${NC}"
            if [[ -s "$IPSEC_FILE" ]]; then
                while IFS='|' read -r N L R LN RN; do
                    [[ -n "$N" ]] && echo "  $N: $L <-> $R  ($LN <-> $RN)"
                done < "$IPSEC_FILE"
            else
                echo -e "  ${DIM}(none)${NC}"
            fi
            echo -e "${BOLD}${CYAN}════════════════════════════════════${NC}\n" ;;
        tunnel)
            local NAME="${ARGS[0]}" LOCAL="${ARGS[1]}" REMOTE="${ARGS[2]}" \
                  LNET="${ARGS[3]}" RNET="${ARGS[4]}" PSK="${ARGS[5]}"
            if [[ -z "$NAME" || -z "$LOCAL" || -z "$REMOTE" || -z "$LNET" || -z "$RNET" || -z "$PSK" ]]; then
                log ERROR "Usage: ipsec tunnel <n> <local> <remote> <local_net> <remote_net> <psk>"
                return 1
            fi
            validate_ip "$LOCAL" && validate_ip "$REMOTE" || return 1
            mkdir -p /etc/ipsec.d 2>/dev/null
            {
                echo ""
                echo "conn ${NAME}"
                echo "    left=${LOCAL}"
                echo "    leftsubnet=${LNET}"
                echo "    right=${REMOTE}"
                echo "    rightsubnet=${RNET}"
                echo "    ike=aes256-sha256-modp2048!"
                echo "    esp=aes256-sha256!"
                echo "    keyexchange=ikev2"
                echo "    auto=start"
            } >> /etc/ipsec.conf
            echo "${LOCAL} ${REMOTE} : PSK \"${PSK}\"" >> /etc/ipsec.secrets
            echo "${NAME}|${LOCAL}|${REMOTE}|${LNET}|${RNET}" >> "$IPSEC_FILE"
            ipsec reload 2>/dev/null; ipsec up "$NAME" 2>&1
            log OK "IPsec tunnel '$NAME' configured ($LOCAL <-> $REMOTE)." ;;
        *) log ERROR "Usage: ipsec status|start|stop|restart|reload|list|tunnel ..." ;;
    esac
}
set_timezone() {
    local TZ_NAME="$1"
    require_args "$TZ_NAME" 1 "set timezone <tz>" || return 1
    if timedatectl set-timezone "$TZ_NAME" 2>/tmp/.ncos_err; then
        log OK "Timezone set to $TZ_NAME."
    else
        log ERROR "Failed to set timezone: $(cat /tmp/.ncos_err 2>/dev/null)"
        log INFO "  List valid zones: timedatectl list-timezones"
    fi
    rm -f /tmp/.ncos_err
}
ntp_sync() {
    local SERVER="${1:-pool.ntp.org}"
    log INFO "Syncing time from $SERVER..."
    if command -v chronyd &>/dev/null; then
        systemctl stop chrony 2>/dev/null
        if chronyd -q "server ${SERVER} iburst" 2>&1 | tail -5; then
            log OK "Time synced from $SERVER."
        else
            log ERROR "chronyd sync failed."
        fi
        systemctl start chrony 2>/dev/null
    elif command -v ntpdate &>/dev/null; then
        ntpdate "$SERVER" 2>&1 && log OK "Time synced from $SERVER." || log ERROR "ntpdate sync failed."
    else
        log ERROR "No NTP client found (install 'chrony')."
        return 1
    fi
    date
}
do_reboot() {
    confirm "Reboot the system now?" || return 1
    log WARN "Rebooting..."
    systemctl reboot 2>/dev/null || reboot 2>/dev/null
}
do_shutdown() {
    confirm "Shut down the system now?" || return 1
    log WARN "Shutting down..."
    systemctl poweroff 2>/dev/null || shutdown -h now 2>/dev/null
}
log_export() {
    local DEST="${1:-$BASE_DIR/netcoreos_export_$(date +%Y%m%d_%H%M%S).log}"
    cp "$LOG_FILE" "$DEST" 2>/tmp/.ncos_err \
        && log OK "Log exported to $DEST." \
        || log ERROR "Export failed: $(cat /tmp/.ncos_err 2>/dev/null)"
    rm -f /tmp/.ncos_err
}
run_system() {
    local CMD_LINE="$*"
    require_args "$CMD_LINE" 1 "run system <cmd>" || return 1
    log CMD "Running: $CMD_LINE"
    bash -c "$CMD_LINE"
    local RC=$?
    (( RC == 0 )) && log OK "Command finished (exit 0)." || log WARN "Command finished (exit $RC)."
}
port_forward() {
    local EXT_PORT="$1"
    local INT_IP="$2"
    local INT_PORT="${3:-$1}"
    local PROTO="${4:-tcp}"
    [[ -z "$EXT_PORT" || -z "$INT_IP" ]] && {
        log ERROR "Usage: port forward <ext_port> <internal_ip> [int_port] [tcp|udp|both]"
        log INFO  "  Example: port forward 8080 192.168.1.100 80"
        log INFO  "           port forward 2222 192.168.1.50 22 tcp"
        return 1
    }
    validate_port "$EXT_PORT" || return 1
    validate_ip "$INT_IP"     || return 1
    validate_port "$INT_PORT" || return 1
    PROTO="${PROTO,,}"
    if [[ "$PROTO" != "tcp" && "$PROTO" != "udp" && "$PROTO" != "both" ]]; then
        log ERROR "Protocol must be: tcp | udp | both"
        return 1
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    local ADDED=0
    for P in tcp udp; do
        [[ "$PROTO" != "both" && "$PROTO" != "$P" ]] && continue
        if iptables -t nat -C PREROUTING -p "$P" --dport "$EXT_PORT" \
            -j DNAT --to-destination "${INT_IP}:${INT_PORT}" &>/dev/null 2>&1; then
            log WARN "Port forward $EXT_PORT/$P -> ${INT_IP}:${INT_PORT} already exists."
            continue
        fi
        iptables -t nat -A PREROUTING -p "$P" --dport "$EXT_PORT" \
            -j DNAT --to-destination "${INT_IP}:${INT_PORT}" 2>/dev/null
        iptables -A FORWARD -p "$P" -d "$INT_IP" --dport "$INT_PORT" \
            -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo "${EXT_PORT}|${INT_IP}|${INT_PORT}|${P}" >> "$PORTFWD_FILE"
        log OK "Port forward: *:${EXT_PORT}/$P -> ${INT_IP}:${INT_PORT}"
        (( ADDED++ ))
    done
    [[ $ADDED -gt 0 ]] && log INFO "  Use 'show nat' to see all active forwards."
}
port_forward_remove() {
    local EXT_PORT="$1"
    [[ -z "$EXT_PORT" ]] && { log ERROR "Usage: port forward remove <ext_port>"; return 1; }
    validate_port "$EXT_PORT" || return 1
    local REMOVED=0
    while IFS='|' read -r EP IP IP2 PROTO; do
        [[ "$EP" != "$EXT_PORT" ]] && continue
        iptables -t nat -D PREROUTING -p "$PROTO" --dport "$EP" \
            -j DNAT --to-destination "${IP}:${IP2}" 2>/dev/null && (( REMOVED++ ))
        iptables -D FORWARD -p "$PROTO" -d "$IP" --dport "$IP2" \
            -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    done < "$PORTFWD_FILE"
    sed -i "/^${EXT_PORT}|/d" "$PORTFWD_FILE" 2>/dev/null
    if (( REMOVED > 0 )); then
        log OK "Port forward on ext port $EXT_PORT removed."
    else
        log WARN "No port forward found for port $EXT_PORT."
    fi
}
show_nat() {
    echo -e "\n${BOLD}${CYAN}══════════ NAT Rules ══════════${NC}"
    _section "Port Forwards (DNAT)"
    if [[ -s "$PORTFWD_FILE" ]]; then
        printf "  ${BOLD}%-12s %-18s %-12s %s${NC}\n" "Ext Port" "Internal IP" "Int Port" "Proto"
        echo "  ──────────────────────────────────────────────"
        while IFS='|' read -r EP IP IP2 PROTO; do
            [[ -z "$EP" ]] && continue
            printf "  ${CYAN}%-12s${NC} %-18s %-12s %s\n" "*:$EP" "$IP" "$IP2" "$PROTO"
        done < "$PORTFWD_FILE"
    else
        echo -e "  ${DIM}No port forwards configured.${NC}"
        echo -e "  ${DIM}Use 'port forward <ext_port> <ip> [int_port]' to add one.${NC}"
    fi
    _section "Masquerade / NAT (POSTROUTING)"
    iptables -t nat -L POSTROUTING -v -n 2>/dev/null | grep -v "^Chain\|^pkts\|^$" | \
        while read -r L; do echo "  $L"; done || echo -e "  ${DIM}(none)${NC}"
    _section "All PREROUTING rules"
    iptables -t nat -L PREROUTING -v -n 2>/dev/null | grep -v "^Chain\|^pkts\|^$" | \
        while read -r L; do echo -e "  $L"; done || echo -e "  ${DIM}(none)${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════${NC}\n"
}
bandwidth_test() {
    local TARGET="$1"
    local MODE="${2:-client}"
    local PORT="${3:-5201}"
    local DURATION="${4:-10}"
    if [[ "$TARGET" == "server" || "$MODE" == "server" ]]; then
        if ! command -v iperf3 &>/dev/null; then
            log ERROR "iperf3 not installed. Run: apt install iperf3"
            return 1
        fi
        log INFO "Starting iperf3 server on port $PORT (Ctrl+C to stop)..."
        log INFO "On the remote machine run: bandwidth test <this_ip>"
        iperf3 -s -p "$PORT" 2>/dev/null
        return
    fi
    [[ -z "$TARGET" ]] && {
        log ERROR "Usage: bandwidth test <server_ip> [port] [duration_sec]"
        log INFO  "       bandwidth test server    -- start as server"
        log INFO  "  Example: bandwidth test 192.168.1.1"
        log INFO  "           bandwidth test 192.168.1.1 5201 10"
        return 1
    }
    if ! command -v iperf3 &>/dev/null; then
        log ERROR "iperf3 not installed. Run: apt install iperf3"
        return 1
    fi
    validate_ip "$TARGET" || return 1
    validate_port "$PORT"  || return 1
    validate_positive_int "$DURATION" "duration" || return 1
    echo -e "\n${BOLD}${CYAN}══════════ Bandwidth Test ══════════${NC}"
    log CMD "iperf3 -c $TARGET -p $PORT -t $DURATION"
    echo -e "  Target  : ${CYAN}$TARGET:$PORT${NC}"
    echo -e "  Duration: ${BOLD}${DURATION}s${NC}\n"
    echo -e "${BOLD}TCP throughput:${NC}"
    iperf3 -c "$TARGET" -p "$PORT" -t "$DURATION" 2>/dev/null \
        || log ERROR "iperf3 failed — is the server running? Run 'bandwidth test server' on target."
    echo ""
    echo -e "${BOLD}UDP throughput (1Gbps target):${NC}"
    iperf3 -c "$TARGET" -p "$PORT" -t "$DURATION" -u -b 1G 2>/dev/null
    echo -e "${BOLD}${CYAN}════════════════════════════════════${NC}\n"
}
_wg_check() {
    if ! command -v wg &>/dev/null; then
        log ERROR "WireGuard not installed."
        log INFO  "Install: apt install wireguard wireguard-tools"
        return 1
    fi
    return 0
}
wireguard_cmd() {
    local SUB="$1"; shift
    case "$SUB" in
        create)
            local IFACE="${1:-wg0}"
            local PORT="${2:-51820}"
            local ADDR="${3:-10.200.200.1/24}"
            _wg_check || return 1
            validate_port "$PORT" || return 1
            if ip link show "$IFACE" &>/dev/null 2>&1; then
                log WARN "Interface $IFACE already exists."
                return 1
            fi
            local PRIV_KEY PUB_KEY
            PRIV_KEY=$(wg genkey 2>/dev/null)
            PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey 2>/dev/null)
            local CONF_DIR="/etc/wireguard"
            mkdir -p "$CONF_DIR"
            chmod 700 "$CONF_DIR"
            cat > "${CONF_DIR}/${IFACE}.conf" << WGCONF
[Interface]
Address = ${ADDR}
ListenPort = ${PORT}
PrivateKey = ${PRIV_KEY}

# Add peers below using: wg addconf ${IFACE} <peer.conf>
# Or use: wireguard peer add ${IFACE} <peer_pubkey> <allowed_ips> [endpoint]
WGCONF
            chmod 600 "${CONF_DIR}/${IFACE}.conf"
            ip link add dev "$IFACE" type wireguard 2>/dev/null
            wg setconf "$IFACE" "${CONF_DIR}/${IFACE}.conf" 2>/dev/null
            ip addr add "$ADDR" dev "$IFACE" 2>/dev/null
            ip link set "$IFACE" up 2>/dev/null
            echo "${IFACE}|${PORT}|${ADDR}" >> "$WG_FILE"
            log OK "WireGuard interface $IFACE created."
            echo -e "\n  ${BOLD}Public Key (share with peers):${NC}"
            echo -e "  ${CYAN}$PUB_KEY${NC}"
            echo -e "\n  ${BOLD}Listen Port:${NC} $PORT"
            echo -e "  ${BOLD}Address:${NC}     $ADDR"
            echo -e "  ${BOLD}Config:${NC}      ${CONF_DIR}/${IFACE}.conf\n"
            log INFO "Add peers with: wireguard peer add $IFACE <pubkey> <allowed_ips>"
            ;;
        peer)
            local ACTION="$1"; shift
            case "$ACTION" in
                add)
                    local IFACE="$1" PUBKEY="$2" ALLOWED_IPS="$3" ENDPOINT="${4:-}"
                    [[ -z "$IFACE" || -z "$PUBKEY" || -z "$ALLOWED_IPS" ]] && {
                        log ERROR "Usage: wireguard peer add <iface> <pubkey> <allowed_ips> [endpoint:port]"
                        log INFO  "  Example: wireguard peer add wg0 <pubkey> 10.200.200.2/32 1.2.3.4:51820"
                        return 1
                    }
                    _wg_check || return 1
                    local PEER_CONF="${IFACE}_peer_$(echo "$PUBKEY" | cut -c1-8).conf"
                    local PEER_FILE="/tmp/${PEER_CONF}"
                    {
                        echo "[Peer]"
                        echo "PublicKey = $PUBKEY"
                        echo "AllowedIPs = $ALLOWED_IPS"
                        [[ -n "$ENDPOINT" ]] && echo "Endpoint = $ENDPOINT"
                        echo "PersistentKeepalive = 25"
                    } > "$PEER_FILE"
                    wg addconf "$IFACE" "$PEER_FILE" 2>/dev/null \
                        && log OK "Peer added to $IFACE (AllowedIPs: $ALLOWED_IPS)" \
                        || { log ERROR "Failed to add peer. Is $IFACE up?"; return 1; }
                    cat >> "/etc/wireguard/${IFACE}.conf" < "$PEER_FILE" 2>/dev/null
                    rm -f "$PEER_FILE"
                    ;;
                remove)
                    local IFACE="$1" PUBKEY="$2"
                    [[ -z "$IFACE" || -z "$PUBKEY" ]] && {
                        log ERROR "Usage: wireguard peer remove <iface> <pubkey>"
                        return 1
                    }
                    _wg_check || return 1
                    wg set "$IFACE" peer "$PUBKEY" remove 2>/dev/null \
                        && log OK "Peer removed from $IFACE." \
                        || log ERROR "Failed to remove peer."
                    ;;
                *)
                    log ERROR "Usage: wireguard peer add|remove <iface> ..."
                    ;;
            esac
            ;;
        status)
            _wg_check || return 1
            echo -e "\n${BOLD}${CYAN}══════════ WireGuard Status ══════════${NC}"
            if [[ -s "$WG_FILE" ]]; then
                while IFS='|' read -r IFACE PORT ADDR; do
                    [[ -z "$IFACE" ]] && continue
                    local STATE="${RED}DOWN${NC}"
                    ip link show "$IFACE" 2>/dev/null | grep -q "UP" && STATE="${GREEN}UP${NC}"
                    echo -e "\n  Interface : ${CYAN}$IFACE${NC}  [$STATE]"
                    echo    "  Address   : $ADDR"
                    echo    "  Port      : $PORT"
                    echo -e "  ${BOLD}Peers:${NC}"
                    wg show "$IFACE" 2>/dev/null | grep -A4 "^peer:" | \
                        while read -r L; do echo "    $L"; done
                done < "$WG_FILE"
            else
                echo -e "  ${DIM}No WireGuard interfaces configured.${NC}"
                echo -e "  ${DIM}Use 'wireguard create' to set one up.${NC}"
            fi
            echo ""
            wg show all 2>/dev/null | grep -v "^$" | while read -r L; do echo "  $L"; done
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"
            ;;
        remove)
            local IFACE="${1:-wg0}"
            _wg_check || return 1
            ip link set "$IFACE" down 2>/dev/null
            ip link del "$IFACE" 2>/dev/null \
                && log OK "WireGuard interface $IFACE removed." \
                || log WARN "$IFACE not found."
            sed -i "/^${IFACE}|/d" "$WG_FILE" 2>/dev/null
            ;;
        genkey)
            _wg_check || return 1
            local PRIV PUB
            PRIV=$(wg genkey 2>/dev/null)
            PUB=$(echo "$PRIV" | wg pubkey 2>/dev/null)
            echo -e "\n  ${BOLD}Private Key:${NC} ${DIM}$PRIV${NC}"
            echo -e "  ${BOLD}Public Key: ${NC} ${CYAN}$PUB${NC}\n"
            log INFO "Keep the private key secret. Share only the public key."
            ;;
        *)
            echo -e "${BOLD}WireGuard commands:${NC}"
            echo "  wireguard create [iface] [port] [ip/prefix]"
            echo "      -- create interface, generate keys, bring up"
            echo "  wireguard peer add <iface> <pubkey> <allowed_ips> [endpoint:port]"
            echo "  wireguard peer remove <iface> <pubkey>"
            echo "  wireguard status         -- show all WG interfaces and peers"
            echo "  wireguard remove [iface] -- tear down interface"
            echo "  wireguard genkey         -- generate a new key pair"
            ;;
    esac
}
help_linux() {
    echo -e "${BOLD}Modes:${NC}"
    echo "  switch | switch-mls | router | firewall"
    echo -e "${BOLD}Instances:${NC}"
    echo "  instance create|enter|delete|list <n>"
    echo -e "${BOLD}Config / Backup:${NC}"
    echo "  config save|load|list|delete <n>"
    echo "  backup <n>  |  backup list|delete <n>  |  restore <n>"
    echo -e "${BOLD}Aliases / Scheduler:${NC}"
    echo "  alias set|list|delete    schedule <sec> <cmd> | list | cancel"
    echo -e "${BOLD}Interface Settings:${NC}"
    echo "  set mtu <iface> <size>        set speed <iface> <10|100|1000|auto>"
    echo "  set mac <iface> <mac>"
    echo "  ipaddr <iface> <ip/cidr>       (assign an IP directly to a host interface)"
    echo -e "${BOLD}DNS:${NC}"
    echo "  dns lookup <host>             dns set <server_ip>     show dns"
    echo -e "${BOLD}Port Management:${NC}"
    echo "  show open ports"
    echo "  open port <port/name> [tcp|udp|both]"
    echo "  close port <port/name> [tcp|udp|both]"
    echo -e "${BOLD}NAT / Port Forwarding:${NC}"
    echo "  port forward <ext_port> <ip> [int_port] [tcp|udp|both]"
    echo "  port forward remove <ext_port>         show nat"
    echo -e "${BOLD}Security:${NC}"
    echo "  show connections"
    echo "  block ip <ip>  |  unblock ip <ip>  |  show blocked ips"
    echo -e "${BOLD}Tunnels / VPN:${NC}"
    echo "  gre create <n> <local> <remote> [ip/prefix]"
    echo "  gre remove <n>  |  gre show"
    echo "  ipsec status|start|stop|restart|reload|list"
    echo "  ipsec tunnel <n> <local> <remote> <local_net> <remote_net> <psk>"
    echo "  wireguard create [iface] [port] [ip/cidr]"
    echo "  wireguard peer add|remove    wireguard status|remove|genkey"
    echo -e "${BOLD}Diagnostics:${NC}"
    echo "  dns lookup <hostname>         whois <ip|domain>"
    echo "  show traffic <iface>          show connections"
    echo "  bandwidth test <ip>           bandwidth test server"
    echo "  ping <ip>  traceroute <ip>  arp  arp flush [iface]  netstat"
    echo -e "${BOLD}System:${NC}"
    echo "  set timezone <tz>             ntp sync"
    echo "  reboot                        shutdown"
    echo "  log export <file>             show log live"
    echo "  run system <cmd>              show versions"
    echo "  clear"
    echo -e "${BOLD}General:${NC}"
    echo "  status | health | version | log [n] | log search <kw> | dashboard | help | exit"
    echo "  show running-config           (full live state — not just FRR)"
    echo "  show tech-support              (version+health+config+log bundle, saved to a file too)"
    echo "  change password               (changes both the NCOS password and root's Linux/SSH password together)"
    echo "  description <iface> <text>    no description <iface>"
    echo "  lldp enable|disable           show lldp neighbors"
    echo -e "${BOLD}Boot persistence:${NC}"
    echo "  write                         (save current config to survive a reboot)"
    echo "  boot-persist enable|disable|status"
    echo -e "${BOLD}Console (make NCOS the login shell):${NC}"
    echo "  console enable|disable [user]      (default user: whoever ran this)"
    echo "  console autologin enable|disable [tty] [user]   (skip the Linux password — NCOS password only)"
    echo "  console rescue enable|disable [tty]              (guaranteed plain Debian shell, default tty9)"
    echo "  console status"
    echo -e "${BOLD}Web UI:${NC}"
    echo "  web | web stop | web status"
}
help_switch() {
    echo -e "${BOLD}VLANs:${NC}"
    echo "  vlan create <id>        vlan range <start> <end>    vlan delete <id>"
    echo "  access <iface> <vlan>   trunk <iface> <v1,v2,...>"
    echo -e "${BOLD}SVI (VLAN management IP):${NC}"
    echo "  svi create <vlan> [ip/cidr]   svi remove <vlan>   svi show"
    echo "  ipaddr <iface> <ip/cidr>       (management only — no routing here; see switch-mls)"
    echo -e "${BOLD}STP:${NC}"
    echo "  stp | rstp | mstp             (rstp/mstp/portfast need mstpd installed)"
    echo "  bpdu-guard|root-guard|loop-guard <iface> enable"
    echo "  portfast <iface> enable       (real mstpd edge-port; needs rstp/mstp on first)"
    echo "  err-disable recovery <iface> <sec>"
    echo -e "${BOLD}Port:${NC}"
    echo "  port-security <iface> [mac]   (locks the port to one source MAC; needs ebtables)"
    echo "  port-security <iface> disable storm-control <iface> <mbit>"
    echo -e "${BOLD}Interface:${NC}"
    echo "  description <iface> <text>    no description <iface>"
    echo -e "${BOLD}Multicast:${NC}"
    echo "  igmp snooping enable|disable  show igmp"
    echo -e "${BOLD}Neighbor discovery:${NC}"
    echo "  lldp enable|disable           show lldp neighbors"
    echo -e "${BOLD}Advanced L2:${NC}"
    echo "  lacp create <bond> <if1> <if2> [if3...]"
    echo "  lacp show               lacp remove <bond>"
    echo "  vxlan create <vni> <local_ip> <remote_ip> [dstport]"
    echo "  vxlan remove <vni>      vxlan show"
    echo "  mirror create <src> <dst>   mirror remove <src>"
    echo "  pvlan create <id>       pvlan isolated|promiscuous <iface> <id>"
    echo "  qinq <iface> <outer> <inner>"
    echo -e "${BOLD}Show:${NC}"
    echo "  show vlan | show mac | show spanning-tree | show interfaces"
    echo "  capture <iface>         back"
}
help_switch_mls() {
    help_switch
    echo -e "${BOLD}L3 additions (Inter-VLAN Routing):${NC}"
    echo "  svi create <vlan> <ip/cidr>    (give 2+ VLANs an SVI IP -> routes between them)"
    echo "  dhcp <vlan> <start> <end> [gw] [dns]     (IPv4)"
    echo "  dhcp6 <vlan> <prefix/64> [dns6]          (IPv6 RA + SLAAC)"
    echo "  ipaddr <iface> <ip/cidr>       (v4 or v6 — auto-detected from ':')"
    echo "  route <dest/prefix> <via>      (v4 or v6)"
    echo "  show ip route | show ipv6 route"
}
help_router() {
    echo -e "${BOLD}Interfaces:${NC}"
    echo "  subif <iface> <vlan>          ipaddr <iface> <ip/cidr>  (v4 or v6)"
    echo "  description <iface> <text>    no description <iface>"
    echo -e "${BOLD}VRF:${NC}"
    echo "  vrf create <name>             vrf assign <iface> <name>"
    echo "  vrf unassign <iface>          vrf delete <name>          vrf show"
    echo -e "${BOLD}Static Routing:${NC}"
    echo "  route <dest> <via>            (v4 or v6)"
    echo "  show ip route                 show ipv6 route"
    echo -e "${BOLD}OSPF (via FRR):${NC}"
    echo "  ospf enable                   ospf disable"
    echo "  ospf area <id>                ospf network <prefix> area <id>"
    echo "  ospf cost <iface> <cost>      ospf hello <iface> <secs>"
    echo "  ospf redistribute connected|static|bgp"
    echo "  ospf passive <iface>          ospf auth <iface> <key>"
    echo "  show ospf neighbors           show ospf routes"
    echo "  show ospf database            show ospf interface"
    echo -e "${BOLD}BGP (via FRR):${NC}"
    echo "  bgp as <asn>                  bgp disable"
    echo "  bgp neighbor <ip> remote-as <asn>"
    echo "  bgp neighbor <ip> description|password|shutdown|activate"
    echo "  bgp neighbor <ip> prefix-list <n> in|out"
    echo "  bgp neighbor <ip> route-map <n> in|out"
    echo "  bgp network <prefix>          bgp redistribute ospf|connected|static"
    echo "  bgp router-id <ip>"
    echo "  show bgp summary              show bgp routes"
    echo "  show bgp neighbors            show bgp advertised|received <neighbor>"
    echo -e "${BOLD}Route Maps:${NC}"
    echo "  routemap create <n> permit|deny <seq>"
    echo "  routemap match prefix-list <pl>|as-path <regex>"
    echo "  routemap set local-pref|community|metric <val>"
    echo "  routemap show"
    echo -e "${BOLD}Prefix Lists:${NC}"
    echo "  prefix-list create <n> permit|deny <prefix> [le <n>] [ge <n>]"
    echo "  prefix-list show              prefix-list delete <n>"
    echo -e "${BOLD}RPKI:${NC}"
    echo "  rpki enable <validator-ip> <port>    rpki disable    show rpki"
    echo -e "${BOLD}VRRP (HA / Failover):${NC}"
    echo "  vrrp create <vrid> <iface> <vip> priority <n>"
    echo "  vrrp show                     vrrp remove <vrid>"
    echo -e "${BOLD}NAT / DHCP:${NC}"
    echo "  nat enable                    dhcp <iface> <start> <end> [gw] [dns]"
    echo "  dhcp6 <iface> <prefix/64> [dns6]         (IPv6 RA + SLAAC)"
    echo -e "${BOLD}BFD (sub-second failure detection):${NC}"
    echo "  bfd enable                    bfd peer <ip>"
    echo "  bfd ospf <iface>              bfd bgp <peer>     bfd show"
    echo -e "${BOLD}FRR Admin:${NC}"
    echo "  frr status|restart|stop|logs|version|daemons|running-config|install-help"
    echo "  (frr running-config is FRR-only — for the whole system, use 'show running-config')"
    echo -e "${BOLD}QoS / Monitor / Tools:${NC}"
    echo "  qos policy|class|apply|show|remove"
    echo "  monitor add|list|remove"
    echo "  ping <ip>  traceroute <ip>  arp  netstat  bandwidth <iface>  back"
}
help_firewall() {
    echo -e "${BOLD}Setup:${NC}"
    echo "  firewall init"
    echo "  firewall allow vlan <id>   firewall allow wan"
    echo -e "${BOLD}ACL:${NC}"
    echo "  acl deny  <src_if> <dst_if>"
    echo "  acl allow <src_if> <dst_if> <tcp|udp|icmp> <port>"
    echo "  acl matrix"
    echo -e "${BOLD}Rate limiting:${NC}"
    echo "  ratelimit <iface> <src_ip> <kbps>"
    echo -e "${BOLD}Show:${NC}"
    echo "  show firewall    back"
}
WEBUI_PORT=7474
WEBUI_PID_FILE="$BASE_DIR/webui.pid"
WEBUI_TOKEN_FILE="$BASE_DIR/webui_token"
WEBUI_HOST="0.0.0.0"
_lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' \
        || hostname -I 2>/dev/null | awk '{print $1}'
}
launch_webui() {
    local WEBUI_SCRIPT; WEBUI_SCRIPT="$(dirname "$(realpath "$0")")/netcoreos_webui.py"
    if [[ -f "$WEBUI_PID_FILE" ]]; then
        local PID; PID=$(cat "$WEBUI_PID_FILE" 2>/dev/null)
        if kill -0 "$PID" 2>/dev/null; then
            log WARN "Web UI already running (PID $PID)."
            log INFO "  Local:   https://127.0.0.1:${WEBUI_PORT}"
            [[ -n "$(_lan_ip)" ]] && log INFO "  Network: https://$(_lan_ip):${WEBUI_PORT}"
            [[ -f "$WEBUI_TOKEN_FILE" ]] && log INFO "  Token:   $(cat "$WEBUI_TOKEN_FILE")"
            _open_browser; return
        fi
        rm -f "$WEBUI_PID_FILE"
    fi
    if [[ ! -f "$WEBUI_SCRIPT" ]]; then
        log ERROR "netcoreos_webui.py not found at: $WEBUI_SCRIPT"
        return 1
    fi
    local TOKEN
    TOKEN=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ -z "$TOKEN" ]] && TOKEN=$(date +%s%N | sha256sum | head -c 32)
    printf '%s' "$TOKEN" > "$WEBUI_TOKEN_FILE"
    chmod 600 "$WEBUI_TOKEN_FILE"
    SILENTOS_SCRIPT="$(realpath "$0")" \
    NETCOREOS_WEBUI_HOST="$WEBUI_HOST" \
    NETCOREOS_WEBUI_TOKEN_FILE="$WEBUI_TOKEN_FILE" \
    python3 "$WEBUI_SCRIPT" &
    local PID=$!
    echo "$PID" > "$WEBUI_PID_FILE"
    sleep 1
    if kill -0 "$PID" 2>/dev/null; then
        log OK "Web UI started (PID $PID)."
        log INFO "  Local:   https://127.0.0.1:${WEBUI_PORT}"
        [[ -n "$(_lan_ip)" ]] && log INFO "  Network: https://$(_lan_ip):${WEBUI_PORT}"
        log INFO "  Token:   $TOKEN   (enter this in the browser once — required from any device)"
        _open_browser
    else
        log ERROR "Web UI failed to start."
        rm -f "$WEBUI_PID_FILE" "$WEBUI_TOKEN_FILE"
    fi
}
stop_webui() {
    if [[ -f "$WEBUI_PID_FILE" ]]; then
        local PID; PID=$(cat "$WEBUI_PID_FILE" 2>/dev/null)
        if [[ -n "$PID" ]] && kill "$PID" 2>/dev/null; then
            log OK "Web UI (PID $PID) stopped."
        else log WARN "Web UI not running."; fi
        rm -f "$WEBUI_PID_FILE" "$WEBUI_TOKEN_FILE"
    else log WARN "Web UI is not running."; fi
}
_open_browser() {
    local URL="https://127.0.0.1:${WEBUI_PORT}"
    if   command -v xdg-open   &>/dev/null; then xdg-open   "$URL" 2>/dev/null &
    elif command -v gnome-open &>/dev/null; then gnome-open  "$URL" 2>/dev/null &
    elif command -v open       &>/dev/null; then open        "$URL" 2>/dev/null &
    elif command -v wslview    &>/dev/null; then wslview     "$URL" 2>/dev/null &
    else log WARN "Cannot auto-open browser. Go to: $URL"; fi
}
webui_status() {
    if [[ -f "$WEBUI_PID_FILE" ]]; then
        local PID; PID=$(cat "$WEBUI_PID_FILE" 2>/dev/null)
        if kill -0 "$PID" 2>/dev/null; then
            log OK "Web UI running at https://127.0.0.1:${WEBUI_PORT} (PID $PID)"
        else
            log WARN "Web UI PID file exists but process is dead."
            rm -f "$WEBUI_PID_FILE"
        fi
    else log INFO "Web UI is not running. Type 'web' to start it."; fi
}
_dispatch_cmd() {
    local CMD="$1"
    case "$CMD" in
        switch)
            confirm "Switch to L2 switch mode? This will clean up current state." || return 1
            cleanup_switch; MODE="switch"; create_bridge ;;
        switch-mls)
            confirm "Switch to MLS mode? This will clean up current state." || return 1
            cleanup_switch_mls; MODE="switch-mls"; create_bridge; enable_ip_forward ;;
        router)
            confirm "Switch to router mode? This will clean up current state." || return 1
            cleanup_router; MODE="router"; enable_ip_forward ;;
        firewall)
            cleanup_firewall; MODE="firewall" ;;
        back)
            case "$MODE" in
                switch|switch-mls) cleanup_switch ;;
                router)            cleanup_router ;;
                firewall)          cleanup_firewall ;;
            esac
            MODE="ncos"; log INFO "Returned to ncos mode." ;;
        instance\ create*)
            NAME=$(echo "$CMD" | awk '{print $3}')
            require_args "$NAME" 1 "instance create <n>" || return 1
            ip netns add "$NAME" && log OK "Instance '$NAME' created." ;;
        instance\ enter*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(interactive command, not available via web/schedule)"
                return 1
            fi
            NAME=$(echo "$CMD" | awk '{print $3}')
            require_args "$NAME" 1 "instance enter <n>" || return 1
            ip netns list | grep -qw "$NAME" \
                && { log INFO "Entering '$NAME'..."; ip netns exec "$NAME" bash; } \
                || log ERROR "Instance '$NAME' not found." ;;
        instance\ delete*)
            NAME=$(echo "$CMD" | awk '{print $3}')
            require_args "$NAME" 1 "instance delete <n>" || return 1
            confirm "Delete instance '$NAME'?" || return 1
            ip netns del "$NAME" 2>/dev/null && log OK "Instance '$NAME' deleted." \
                || log ERROR "Failed to delete '$NAME'." ;;
        instance\ list)
            ip netns list ;;
        config\ save*)   config_save   "$(echo "$CMD" | awk '{print $3}')" ;;
        config\ list)    config_list ;;
        config\ delete*) config_delete "$(echo "$CMD" | awk '{print $3}')" ;;
        config\ load*)   config_load   "$(echo "$CMD" | awk '{print $3}')" ;;
        alias\ set*)
            ANAME=$(echo "$CMD" | awk '{print $3}')
            ACMD=$(echo "$CMD"  | cut -d' ' -f4-)
            alias_set "$ANAME" "$ACMD" ;;
        alias\ list)   alias_list ;;
        alias\ delete*) alias_delete "$(echo "$CMD" | awk '{print $3}')" ;;
        change\ password)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(not available in web-exec mode)"
                return 1
            fi
            _change_password ;;
        description\ *)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            DTEXT=$(echo "$CMD" | cut -d' ' -f3-)
            validate_iface "$IFACE" || return 1
            require_args "$DTEXT" 1 "description <iface> <text>" || return 1
            grep -v "^${IFACE}|" "$DESC_FILE" > "${DESC_FILE}.tmp" 2>/dev/null
            echo "${IFACE}|${DTEXT}" >> "${DESC_FILE}.tmp"
            mv "${DESC_FILE}.tmp" "$DESC_FILE"
            log OK "$IFACE description set: $DTEXT" ;;
        no\ description\ *)
            IFACE=$(echo "$CMD" | awk '{print $3}')
            validate_iface "$IFACE" || return 1
            grep -v "^${IFACE}|" "$DESC_FILE" > "${DESC_FILE}.tmp" 2>/dev/null \
                && mv "${DESC_FILE}.tmp" "$DESC_FILE"
            log OK "$IFACE description cleared." ;;
        status)            show_status ;;
        health)            do_health ;;
        version)           do_version ;;
        dashboard*)        dashboard "$(echo "$CMD" | awk '{print $2}')" ;;
        log\ search*)     log_search "$(echo "$CMD" | cut -d' ' -f3-)" ;;
        log\ export*)
            log_export "$(echo "$CMD" | awk '{print $3}')" ;;
        log*)              show_log   "$(echo "$CMD" | awk '{print $2}')" ;;
        schedule\ list)   schedule_list ;;
        schedule\ cancel*) schedule_cancel "$(echo "$CMD" | awk '{print $3}')" ;;
        schedule*)
            SDELAY=$(echo "$CMD" | awk '{print $2}')
            SCMD=$(echo "$CMD" | cut -d' ' -f3-)
            schedule_add "$SDELAY" "$SCMD" ;;
        backup\ list)     backup_list ;;
        backup\ delete*)  backup_delete "$(echo "$CMD" | awk '{print $3}')" ;;
        backup*)           backup_create  "$(echo "$CMD" | awk '{print $2}')" ;;
        restore*)          restore_backup "$(echo "$CMD" | awk '{print $2}')" ;;
        write|write\ memory)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(not available in web-exec mode)"; return 1
            fi
            config_save "startup" ;;
        boot-persist\ enable)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(not available in web-exec mode)"; return 1
            fi
            if [[ $EUID -ne 0 ]]; then
                log ERROR "Must be root to install the systemd unit."
                return 1
            fi
            SELF=$(readlink -f "$0")
            cat > /etc/systemd/system/netcoreos-startup.service << EOF
[Unit]
Description=NetCoreOS startup-config replay
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$SELF --apply-startup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload 2>/dev/null
            if systemctl enable netcoreos-startup.service 2>/dev/null; then
                log OK "Boot persistence enabled. Run 'write' to save what should be re-applied at boot."
            else
                log ERROR "Failed to enable the systemd unit."
            fi ;;
        boot-persist\ disable)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(not available in web-exec mode)"; return 1
            fi
            systemctl disable netcoreos-startup.service 2>/dev/null \
                && log OK "Boot persistence disabled (the saved startup config itself was kept — 'boot-persist enable' to turn replay back on)." \
                || log ERROR "Failed to disable (was it enabled?)." ;;
        boot-persist\ status)
            echo -e "${BOLD}--- Boot persistence ---${NC}"
            if systemctl is-enabled netcoreos-startup.service &>/dev/null; then
                echo "  systemd unit : enabled (replays at boot)"
            else
                echo "  systemd unit : not enabled — 'boot-persist enable'"
            fi
            if [[ -f "$CONFIGS_DIR/startup.cfg" ]]; then
                echo "  startup cfg  : saved ($(stat -c %y "$CONFIGS_DIR/startup.cfg" 2>/dev/null | cut -d'.' -f1))"
            else
                echo "  startup cfg  : none — 'write' to save the current config"
            fi ;;
        console\ enable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then
                log ERROR "Must be root to change a user's login shell."
                return 1
            fi
            CUSER=$(echo "$CMD" | awk '{print $3}')
            [[ -z "$CUSER" ]] && CUSER=$(logname 2>/dev/null || echo root)
            if [[ "$CUSER" == "$RESCUE_USER" ]]; then
                log ERROR "'$RESCUE_USER' is reserved as the rescue account (must always stay a normal shell). Use a different user, or 'console rescue disable' first."
                return 1
            fi
            if ! id "$CUSER" &>/dev/null; then
                log ERROR "No such user: $CUSER"
                return 1
            fi
            if [[ "$CUSER" == "root" ]]; then
                confirm "On the standard NCOS image, root is already auto-launched into NCOS via .bash_profile + getty/sshd autologin (a safer mechanism — it always relaunches NCOS even after 'exit'). Changing root's actual shell here would bypass that without removing it. Continue anyway?" \
                    || return 1
            fi
            SELF=$(readlink -f "$0")
            if [[ ! -x "$SELF" ]]; then
                log ERROR "$SELF is not executable (chmod +x it first)."
                return 1
            fi
            grep -qxF "$SELF" /etc/shells 2>/dev/null || echo "$SELF" >> /etc/shells
            CUR_SHELL=$(getent passwd "$CUSER" 2>/dev/null | cut -d: -f7)
            if [[ "$CUR_SHELL" == "$SELF" ]]; then
                log INFO "$CUSER's login shell is already NetCoreOS."
            else
                echo "${CUSER}:${CUR_SHELL}" >> "$CONSOLE_SHELLS_FILE"
                if usermod -s "$SELF" "$CUSER" 2>/dev/null; then
                    log OK "$CUSER's login shell is now NetCoreOS (applies to every TTY and SSH)."
                    log WARN "Test this in a NEW terminal/TTY before closing this one. Undo with: console disable $CUSER"
                else
                    log ERROR "usermod failed."
                    grep -v "^${CUSER}:" "$CONSOLE_SHELLS_FILE" > "${CONSOLE_SHELLS_FILE}.tmp" 2>/dev/null \
                        && mv "${CONSOLE_SHELLS_FILE}.tmp" "$CONSOLE_SHELLS_FILE"
                fi
            fi ;;
        console\ disable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then
                log ERROR "Must be root to change a user's login shell."
                return 1
            fi
            CUSER=$(echo "$CMD" | awk '{print $3}')
            [[ -z "$CUSER" ]] && CUSER=$(logname 2>/dev/null || echo root)
            ORIG=$(grep "^${CUSER}:" "$CONSOLE_SHELLS_FILE" 2>/dev/null | tail -1 | cut -d: -f2-)
            [[ -z "$ORIG" ]] && ORIG="/bin/bash"
            if usermod -s "$ORIG" "$CUSER" 2>/dev/null; then
                grep -v "^${CUSER}:" "$CONSOLE_SHELLS_FILE" > "${CONSOLE_SHELLS_FILE}.tmp" 2>/dev/null \
                    && mv "${CONSOLE_SHELLS_FILE}.tmp" "$CONSOLE_SHELLS_FILE"
                log OK "$CUSER's login shell restored to $ORIG."
            else
                log ERROR "usermod failed."
            fi ;;
        console\ status)
            echo -e "${BOLD}--- Console (TTY/SSH login shell) ---${NC}"
            SELF=$(readlink -f "$0")
            FOUND=0
            while IFS=: read -r _U _P _UID _GID _G _H SH; do
                if [[ "$SH" == "$SELF" ]]; then
                    echo "  $_U -> NetCoreOS ($SELF)"
                    FOUND=1
                fi
            done < <(getent passwd 2>/dev/null)
            (( FOUND == 0 )) && echo "  (no user currently has NetCoreOS as their login shell)"
            if [[ -s "$CONSOLE_SHELLS_FILE" ]]; then
                echo "  saved original shells for: $(cut -d: -f1 "$CONSOLE_SHELLS_FILE" | paste -sd, -)"
            fi
            for D in /etc/systemd/system/getty@*.service.d; do
                [[ -f "$D/override.conf" ]] || continue
                T=$(basename "$D" | sed 's/getty@//; s/\.service\.d//')
                U=$(grep -oP '(?<=--autologin )\S+' "$D/override.conf" 2>/dev/null)
                if [[ "$U" == "$RESCUE_USER" ]]; then
                    echo "  $T -> rescue shell, autologin as $U (no password, physical console only)"
                else
                    echo "  $T -> autologin as $U (Linux login skipped)"
                fi
            done ;;
        console\ autologin\ enable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then log ERROR "Must be root."; return 1; fi
            ATTY=$(echo "$CMD" | awk '{print $4}')
            AUSER=$(echo "$CMD" | awk '{print $5}')
            [[ -z "$ATTY" ]]  && ATTY="tty1"
            [[ -z "$AUSER" ]] && AUSER=$(logname 2>/dev/null || echo root)
            if ! id "$AUSER" &>/dev/null; then
                log ERROR "No such user: $AUSER"; return 1
            fi
            mkdir -p "/etc/systemd/system/getty@${ATTY}.service.d"
            cat > "/etc/systemd/system/getty@${ATTY}.service.d/override.conf" << OVERRIDE_EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${AUSER} --noclear %I \$TERM
OVERRIDE_EOF
            systemctl daemon-reload 2>/dev/null
            systemctl enable --now "getty@${ATTY}.service" 2>/dev/null
            systemctl restart "getty@${ATTY}.service" 2>/dev/null
            log OK "Autologin enabled on $ATTY as $AUSER — Linux login is skipped there, only the NCOS password remains."
            log WARN "Test this on a fresh/unused TTY before relying on it." ;;
        console\ autologin\ disable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then log ERROR "Must be root."; return 1; fi
            ATTY=$(echo "$CMD" | awk '{print $4}')
            [[ -z "$ATTY" ]] && ATTY="tty1"
            rm -rf "/etc/systemd/system/getty@${ATTY}.service.d"
            systemctl daemon-reload 2>/dev/null
            systemctl restart "getty@${ATTY}.service" 2>/dev/null
            log OK "Autologin disabled on $ATTY — normal Linux login prompt restored." ;;
        console\ rescue\ enable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then log ERROR "Must be root."; return 1; fi
            RTTY=$(echo "$CMD" | awk '{print $4}')
            [[ -z "$RTTY" ]] && RTTY="tty9"
            if ! id "$RESCUE_USER" &>/dev/null; then
                useradd -m -s /bin/bash "$RESCUE_USER" 2>/dev/null \
                    && log INFO "Created rescue user '$RESCUE_USER' (shell: /bin/bash)."
                passwd -l "$RESCUE_USER" &>/dev/null
            fi
            CS=$(getent passwd "$RESCUE_USER" 2>/dev/null | cut -d: -f7)
            if [[ "$CS" == "$(readlink -f "$0")" ]]; then
                usermod -s /bin/bash "$RESCUE_USER" 2>/dev/null
                log WARN "$RESCUE_USER's shell had been changed to NCOS — reset to /bin/bash (a rescue account must stay a normal shell)."
            fi
            mkdir -p "/etc/systemd/system/getty@${RTTY}.service.d"
            cat > "/etc/systemd/system/getty@${RTTY}.service.d/override.conf" << OVERRIDE_EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${RESCUE_USER} --noclear %I \$TERM
OVERRIDE_EOF
            systemctl daemon-reload 2>/dev/null
            systemctl enable --now "getty@${RTTY}.service" 2>/dev/null
            systemctl restart "getty@${RTTY}.service" 2>/dev/null
            log OK "Rescue shell ready on $RTTY: a normal Debian bash as '$RESCUE_USER', no password (physical console only — password login is locked on this account, so it's unreachable over SSH)." ;;
        console\ rescue\ disable*)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            if [[ $EUID -ne 0 ]]; then log ERROR "Must be root."; return 1; fi
            RTTY=$(echo "$CMD" | awk '{print $4}')
            [[ -z "$RTTY" ]] && RTTY="tty9"
            rm -rf "/etc/systemd/system/getty@${RTTY}.service.d"
            systemctl daemon-reload 2>/dev/null
            systemctl restart "getty@${RTTY}.service" 2>/dev/null
            log OK "Rescue autologin removed from $RTTY." ;;
        help|\?)
            case "$MODE" in
                ncos)       help_linux ;;
                switch)     help_switch ;;
                switch-mls) help_switch_mls ;;
                router)     help_router ;;
                firewall)   help_firewall ;;
            esac ;;
        exit)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                echo "(not available in web-exec mode)"
                return 1
            fi
            log INFO "User requested exit."
            return 90 ;;
        web|"web ui"|webui)
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            launch_webui ;;
        "web stop"|"webui stop")
            if [[ "$WEBEXEC_MODE" == "1" ]]; then echo "(not available in web-exec mode)"; return 1; fi
            stop_webui ;;
        "web status"|"webui status") webui_status ;;
        vlan\ create*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                VLAN=$(echo "$CMD" | awk '{print $3}')
                validate_vlan "$VLAN" || return 1
                bridge vlan add dev "$BR" vid "$VLAN" self 2>/dev/null \
                    && log OK "VLAN $VLAN created."
            else log ERROR "Not in switch mode."; fi ;;
        vlan\ range*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                V_START=$(echo "$CMD" | awk '{print $3}')
                V_END=$(echo "$CMD" | awk '{print $4}')
                validate_vlan "$V_START" && validate_vlan "$V_END" || return 1
                (( V_START > V_END )) && { log ERROR "Start > end."; return 1; }
                for (( V=V_START; V<=V_END; V++ )); do
                    bridge vlan add dev "$BR" vid "$V" self 2>/dev/null
                done
                log OK "VLANs ${V_START}–${V_END} created."
            else log ERROR "Not in switch mode."; fi ;;
        vlan\ delete*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                VLAN=$(echo "$CMD" | awk '{print $3}')
                validate_vlan "$VLAN" || return 1
                bridge vlan del dev "$BR" vid "$VLAN" self 2>/dev/null \
                    && log OK "VLAN $VLAN deleted."
            else log ERROR "Not in switch mode."; fi ;;
        svi\ create*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                svi_create "$(echo "$CMD" | awk '{print $3}')" \
                           "$(echo "$CMD" | awk '{print $4}')"
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        svi\ remove*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                svi_remove "$(echo "$CMD" | awk '{print $3}')"
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        svi\ show)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                svi_show
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        access*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                IFACE=$(echo "$CMD" | awk '{print $2}')
                VLAN=$(echo "$CMD" | awk '{print $3}')
                validate_iface "$IFACE" && validate_vlan "$VLAN" || return 1
                grep -q "^${IFACE}|" "$BRIDGE_MEMBERS_FILE" 2>/dev/null \
                    || _bridge_snap_iface "$IFACE"
                ip link set "$IFACE" down 2>/dev/null
                ip addr flush dev "$IFACE" 2>/dev/null
                ip link set "$IFACE" master "$BR" 2>/dev/null
                bridge vlan add dev "$IFACE" vid "$VLAN" pvid untagged 2>/dev/null
                ip link set "$IFACE" up 2>/dev/null
                log OK "$IFACE -> access VLAN $VLAN"
            else log ERROR "Not in switch mode."; fi ;;
        trunk*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                IFACE=$(echo "$CMD" | awk '{print $2}')
                VLANS=$(echo "$CMD" | awk '{print $3}')
                validate_iface "$IFACE" || return 1
                grep -q "^${IFACE}|" "$BRIDGE_MEMBERS_FILE" 2>/dev/null \
                    || _bridge_snap_iface "$IFACE"
                ip link set "$IFACE" down 2>/dev/null
                ip addr flush dev "$IFACE" 2>/dev/null
                ip link set "$IFACE" master "$BR" 2>/dev/null
                IFS=',' read -ra LIST <<< "$VLANS"
                for V in "${LIST[@]}"; do
                    validate_vlan "$V" && bridge vlan add dev "$IFACE" vid "$V" 2>/dev/null
                done
                ip link set "$IFACE" up 2>/dev/null
                log OK "$IFACE trunk: $VLANS"
            else log ERROR "Not in switch mode."; fi ;;
        lacp\ create*)
            BOND=$(echo "$CMD" | awk '{print $3}')
            MEMBERS=()
            read -ra _WORDS <<< "$CMD"
            for (( i=3; i<${#_WORDS[@]}; i++ )); do MEMBERS+=("${_WORDS[$i]}"); done
            lacp_create "$BOND" "${MEMBERS[@]}" ;;
        lacp\ show)   lacp_show ;;
        lacp\ remove*) lacp_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        vxlan\ create*)
            vxlan_create \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" \
                "$(echo "$CMD" | awk '{print $5}')" \
                "$(echo "$CMD" | awk '{print $6}')" ;;
        vxlan\ remove*) vxlan_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        vxlan\ show)    vxlan_show ;;
        mirror\ create*)
            mirror_create \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" ;;
        mirror\ remove*) mirror_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        dhcp6\ *)
            if [[ "$MODE" == "switch-mls" || "$MODE" == "router" ]]; then
                ARG2=$(echo "$CMD"   | awk '{print $2}')
                PREFIX=$(echo "$CMD" | awk '{print $3}')
                DNS6=$(echo "$CMD"   | awk '{print $4}')
                validate_cidr6 "$PREFIX" || return 1
                if [[ "$MODE" == "switch-mls" ]]; then
                    validate_vlan "$ARG2" || return 1
                    VLAN_IF="${BR}.${ARG2}"
                    ip link add link "$BR" name "$VLAN_IF" type vlan id "$ARG2" 2>/dev/null
                    ip link set "$VLAN_IF" up 2>/dev/null
                    track_subif "$VLAN_IF"
                    fw_allow_vlan "$VLAN_IF"
                else
                    validate_iface "$ARG2" || return 1
                    VLAN_IF="$ARG2"
                fi
                if ! ip -6 addr show dev "$VLAN_IF" 2>/dev/null | grep -q "${PREFIX%%/*}"; then
                    ip -6 addr add "$PREFIX" dev "$VLAN_IF" 2>/dev/null \
                        && log OK "Assigned $PREFIX to $VLAN_IF (RA prefix / gateway)."
                fi
                start_dhcp6 "$VLAN_IF" "$PREFIX" "$DNS6"
            else log ERROR "dhcp6 only in switch-mls or router mode."; fi ;;
        dhcp*)
            if [[ "$MODE" == "switch-mls" || "$MODE" == "router" ]]; then
                ARG2=$(echo "$CMD" | awk '{print $2}')
                S=$(echo "$CMD"    | awk '{print $3}')
                E=$(echo "$CMD"    | awk '{print $4}')
                GW=$(echo "$CMD"   | awk '{print $5}')
                DNS=$(echo "$CMD"  | awk '{print $6}')
                validate_ip "$S" && validate_ip "$E" || return 1
                if [[ "$MODE" == "switch-mls" ]]; then
                    validate_vlan "$ARG2" || return 1
                    VLAN_IF="${BR}.${ARG2}"
                    ip link add link "$BR" name "$VLAN_IF" type vlan id "$ARG2" 2>/dev/null
                    ip link set "$VLAN_IF" up 2>/dev/null
                    track_subif "$VLAN_IF"
                    fw_allow_vlan "$VLAN_IF"
                    if [[ -n "$GW" ]]; then
                        validate_ip "$GW" || { log ERROR "Invalid gateway IP: $GW"; return 1; }
                        if ! ip -4 addr show dev "$VLAN_IF" | grep -q "$GW/"; then
                            ip addr add "${GW}/24" dev "$VLAN_IF" 2>/dev/null \
                                && log OK "Assigned ${GW}/24 to $VLAN_IF (VLAN gateway)."
                        fi
                    else
                        log WARN "No gateway given — $VLAN_IF has no IP yet, so DHCP replies may not route."
                        log INFO "  Usage: dhcp <vlan> <start> <end> <gateway_ip> [dns_ip]"
                    fi
                else
                    validate_iface "$ARG2" || return 1
                    VLAN_IF="$ARG2"
                    if [[ -n "$GW" ]] && ! ip -4 addr show dev "$VLAN_IF" 2>/dev/null | grep -q "$GW/"; then
                        log WARN "$VLAN_IF has no address matching gateway $GW — set it first with: ipaddr $VLAN_IF ${GW}/24"
                    fi
                fi
                start_dhcp "$VLAN_IF" "$S" "$E" "$GW" "$DNS"
            else log ERROR "DHCP only in switch-mls or router mode."; fi ;;
        ipaddr*)
            if [[ "$MODE" == "ncos" || "$MODE" == "switch" || "$MODE" == "switch-mls" || "$MODE" == "router" ]]; then
                IFACE=$(echo "$CMD" | awk '{print $2}')
                IP=$(echo "$CMD"    | awk '{print $3}')
                validate_iface "$IFACE" || return 1
                if [[ "$IP" == *:* ]]; then
                    validate_cidr6 "$IP" || return 1
                    ip -6 addr add "$IP" dev "$IFACE" 2>/dev/null && log OK "$IP (v6) assigned to $IFACE."
                else
                    validate_cidr "$IP" || return 1
                    ip addr add "$IP" dev "$IFACE" 2>/dev/null && log OK "$IP assigned to $IFACE."
                fi
            else log ERROR "Not available in this mode."; fi ;;
        route\ *)
            if [[ "$MODE" == "switch-mls" || "$MODE" == "router" ]]; then
                DEST=$(echo "$CMD" | awk '{print $2}')
                GW=$(echo "$CMD"   | awk '{print $3}')
                [[ -n "$DEST" && -n "$GW" ]] || { log ERROR "Usage: route <dest/prefix> <via>"; return 1; }
                if [[ "$DEST" == *:* || "$GW" == *:* ]]; then
                    ip -6 route add "$DEST" via "$GW" 2>/dev/null \
                        && track_route "$DEST" via "$GW" && log OK "Route (v6): $DEST via $GW"
                else
                    ip route add "$DEST" via "$GW" 2>/dev/null \
                        && track_route "$DEST" via "$GW" && log OK "Route: $DEST via $GW"
                fi
            else log ERROR "Not in switch-mls or router mode."; fi ;;
        stp)  ip link set "$BR" type bridge stp_state 1; log OK "STP enabled." ;;
        stp\ disable)
            ip link set "$BR" type bridge stp_state 0 2>/dev/null && log OK "STP disabled." ;;
        rstp)
            _mstpd_check || return 1
            if ! systemctl is-active mstpd &>/dev/null; then
                systemctl start mstpd 2>/dev/null
                touch "$BASE_DIR/.mstpd_started_by_netcoreos"
                local _TRIES=0
                while ! systemctl is-active mstpd &>/dev/null && (( _TRIES < 8 )); do
                    sleep 0.5; (( _TRIES++ ))
                done
            fi
            if mstpctl setforcevers "$BR" rstp 2>/dev/null; then
                log OK "RSTP enabled."
            else
                log ERROR "Failed to enable RSTP on $BR — check mstpd is running (systemctl status mstpd)."
            fi ;;
        rstp\ disable)
            mstpctl setforcevers "$BR" stp 2>/dev/null
            ip link set "$BR" type bridge stp_state 0 2>/dev/null
            log OK "RSTP disabled." ;;
        mstp)
            _mstpd_check || return 1
            if ! systemctl is-active mstpd &>/dev/null; then
                systemctl start mstpd 2>/dev/null
                touch "$BASE_DIR/.mstpd_started_by_netcoreos"
                local _TRIES=0
                while ! systemctl is-active mstpd &>/dev/null && (( _TRIES < 8 )); do
                    sleep 0.5; (( _TRIES++ ))
                done
            fi
            if mstpctl setforcevers "$BR" mstp 2>/dev/null; then
                log OK "MSTP enabled."
            else
                log ERROR "Failed to enable MSTP on $BR — check mstpd is running (systemctl status mstpd)."
            fi ;;
        mstp\ disable)
            mstpctl setforcevers "$BR" stp 2>/dev/null
            ip link set "$BR" type bridge stp_state 0 2>/dev/null
            log OK "MSTP disabled." ;;
        igmp\ snooping\ enable)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                ip link set "$BR" type bridge mcast_snooping 1 2>/dev/null \
                    && log OK "IGMP snooping enabled on $BR." \
                    || log ERROR "Failed to enable IGMP snooping on $BR."
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        igmp\ snooping\ disable)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                ip link set "$BR" type bridge mcast_snooping 0 2>/dev/null \
                    && log OK "IGMP snooping disabled on $BR." \
                    || log ERROR "Failed to disable IGMP snooping on $BR."
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        lldp\ enable)
            _lldpd_check || return 1
            if ! systemctl is-active lldpd &>/dev/null; then
                systemctl start lldpd 2>/dev/null && log OK "lldpd started." \
                    || log ERROR "Failed to start lldpd (systemctl status lldpd)."
            else log OK "lldpd already running."; fi ;;
        lldp\ disable)
            systemctl stop lldpd 2>/dev/null && log OK "lldpd stopped." ;;
        port-security\ *\ disable)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _ebtables_check || return 1
            OLDMAC=$(grep "^${IFACE}|" "$PORTSEC_FILE" 2>/dev/null | cut -d'|' -f2)
            [[ -n "$OLDMAC" ]] && ebtables -D FORWARD -i "$IFACE" ! -s "$OLDMAC" -j DROP 2>/dev/null
            grep -v "^${IFACE}|" "$PORTSEC_FILE" > "${PORTSEC_FILE}.tmp" 2>/dev/null \
                && mv "${PORTSEC_FILE}.tmp" "$PORTSEC_FILE"
            log OK "Port security removed from $IFACE." ;;
        port-security*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            MAC=$(echo "$CMD"   | awk '{print $3}')
            validate_iface "$IFACE" || return 1
            _ebtables_check || return 1
            if [[ -z "$MAC" ]]; then
                MAC=$(bridge fdb show dev "$IFACE" 2>/dev/null | awk '{print $1}' \
                      | grep -vi '^33:33\|^01:00:5e\|^01:80:c2' | head -1)
                if [[ -z "$MAC" ]]; then
                    log ERROR "No MAC learned on $IFACE yet. Specify one: port-security $IFACE <mac>, or wait until traffic has passed through the port."
                    return 1
                fi
            fi
            if ! [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                log ERROR "Invalid MAC '$MAC'."; return 1
            fi
            OLDMAC=$(grep "^${IFACE}|" "$PORTSEC_FILE" 2>/dev/null | cut -d'|' -f2)
            [[ -n "$OLDMAC" ]] && ebtables -D FORWARD -i "$IFACE" ! -s "$OLDMAC" -j DROP 2>/dev/null
            grep -v "^${IFACE}|" "$PORTSEC_FILE" > "${PORTSEC_FILE}.tmp" 2>/dev/null \
                && mv "${PORTSEC_FILE}.tmp" "$PORTSEC_FILE"
            if ebtables -A FORWARD -i "$IFACE" ! -s "$MAC" -j DROP 2>/dev/null; then
                echo "${IFACE}|${MAC}" >> "$PORTSEC_FILE"
                log OK "Port security: $IFACE locked to MAC $MAC (frames from any other source MAC are dropped)."
            else
                log ERROR "Failed to apply port security on $IFACE (ebtables error)."
            fi ;;
        bpdu-guard\ *\ disable)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _guard_disable "$IFACE" bpdu ;;
        bpdu-guard*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            bpdu_monitor "$IFACE" bpdu &
            echo "${!}|${IFACE}|bpdu" >> "$GUARDS_PIDS_FILE"
            log OK "BPDU Guard on $IFACE." ;;
        root-guard\ *\ disable)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _guard_disable "$IFACE" root ;;
        root-guard*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            bpdu_monitor "$IFACE" root &
            echo "${!}|${IFACE}|root" >> "$GUARDS_PIDS_FILE"
            log OK "Root Guard on $IFACE." ;;
        loop-guard\ *\ disable)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _guard_disable "$IFACE" loop ;;
        loop-guard*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            bpdu_monitor "$IFACE" loop &
            echo "${!}|${IFACE}|loop" >> "$GUARDS_PIDS_FILE"
            log OK "Loop Guard on $IFACE." ;;
        portfast\ *\ disable)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _mstpd_check || return 1
            if mstpctl setportedge "$BR" "$IFACE" no 2>/dev/null; then
                log OK "PortFast disabled on $IFACE (normal STP timers restored)."
            else
                log ERROR "Failed to disable PortFast on $IFACE — mstpd must be managing $BR first (run 'rstp' or 'mstp')."
            fi ;;
        portfast*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            _mstpd_check || return 1
            if mstpctl setportedge "$BR" "$IFACE" yes 2>/dev/null; then
                log OK "PortFast on $IFACE (edge port — skips STP listening/learning delay)."
            else
                log ERROR "Failed to enable PortFast on $IFACE — mstpd must be managing $BR first (run 'rstp' or 'mstp')."
            fi ;;
        err-disable\ recovery*)
            IFACE=$(echo "$CMD" | awk '{print $3}')
            SEC=$(echo "$CMD"   | awk '{print $4}')
            validate_iface "$IFACE" && validate_positive_int "$SEC" "seconds" || return 1
            ( sleep "$SEC"; ip link set "$IFACE" up; log OK "Err-Disable: $IFACE recovered." ) &
            echo "${!}|${IFACE}|${SEC}" >> "$ERRDIS_PIDS_FILE"
            log INFO "Recovery for $IFACE in ${SEC}s." ;;
        storm-control*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            MBIT=$(echo "$CMD"   | awk '{print $3}')
            validate_iface "$IFACE" && validate_positive_int "$MBIT" "mbit" || return 1
            tc qdisc add dev "$IFACE" root tbf rate "${MBIT}mbit" \
                burst 32kbit latency 400ms 2>/dev/null
            log OK "Storm control on $IFACE at ${MBIT}mbit." ;;
        pvlan\ create*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                VLAN=$(echo "$CMD" | awk '{print $3}')
                validate_vlan "$VLAN" || return 1
                bridge vlan add dev "$BR" vid "$VLAN" self 2>/dev/null \
                    && log OK "PVLAN $VLAN created. Use 'pvlan isolated <iface> $VLAN' or 'pvlan promiscuous <iface> $VLAN' to assign ports."
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        pvlan\ isolated*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                _pvlan_set_port "$(echo "$CMD" | awk '{print $3}')" \
                                "$(echo "$CMD" | awk '{print $4}')" on
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        pvlan\ promiscuous*)
            if [[ "$MODE" == "switch" || "$MODE" == "switch-mls" ]]; then
                _pvlan_set_port "$(echo "$CMD" | awk '{print $3}')" \
                                "$(echo "$CMD" | awk '{print $4}')" off
            else log ERROR "Not in switch or switch-mls mode."; fi ;;
        qinq*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            OUTER=$(echo "$CMD" | awk '{print $3}')
            INNER=$(echo "$CMD" | awk '{print $4}')
            validate_iface "$IFACE" && validate_vlan "$OUTER" && validate_vlan "$INNER" || return 1
            ip link add link "$IFACE" name "${IFACE}.${OUTER}" type vlan id "$OUTER" 2>/dev/null
            ip link add link "${IFACE}.${OUTER}" name "${IFACE}.${OUTER}.${INNER}" \
                type vlan id "$INNER" 2>/dev/null
            ip link set "${IFACE}.${OUTER}" up 2>/dev/null
            ip link set "${IFACE}.${OUTER}.${INNER}" up 2>/dev/null
            log OK "QinQ: $IFACE outer=$OUTER inner=$INNER" ;;
        qos\ policy*)
            qos_policy_create \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" ;;
        qos\ class*)
            qos_class_add \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" \
                "$(echo "$CMD" | awk '{print $5}')" \
                "$(echo "$CMD" | awk '{print $6}')" \
                "$(echo "$CMD" | awk '{print $7}')" ;;
        qos\ apply*)
            qos_apply \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" ;;
        qos\ show*)  qos_show  "$(echo "$CMD" | awk '{print $3}')" ;;
        qos\ remove*) qos_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        monitor\ add*)
            monitor_add \
                "$(echo "$CMD" | awk '{print $3}')" \
                "$(echo "$CMD" | awk '{print $4}')" \
                "$(echo "$CMD" | awk '{print $5}')" \
                "$(echo "$CMD" | cut -d' ' -f6-)" ;;
        monitor\ list)   monitor_list ;;
        monitor\ remove*) monitor_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        show\ vlan)          bridge vlan ;;
        show\ mac)           bridge fdb show ;;
        show\ spanning-tree) mstpctl showbridge "$BR" 2>/dev/null ;;
        show\ interfaces)
            _section "Interfaces"; ip -br link
            _section "Addresses (v4 + v6)";  ip -br addr
            if [[ -s "$DESC_FILE" ]]; then
                _section "Descriptions"
                while IFS='|' read -r DIF DTXT; do
                    [[ -n "$DIF" ]] && printf "  %-14s %s\n" "$DIF" "$DTXT"
                done < "$DESC_FILE"
            fi ;;
        show\ firewall)
            _section "FORWARD chain: $FW_CHAIN"
            iptables -L "$FW_CHAIN" -v -n 2>/dev/null || log WARN "Not initialized."
            _section "NAT chain: ${FW_CHAIN}_NAT"
            iptables -t nat -L "${FW_CHAIN}_NAT" -v -n 2>/dev/null || echo "(none)"
            if [[ -s "$ACLV2_FILE" ]]; then
                _section "ACLs (acl in/out)"
                printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" SEQ DIR IFACE ACTION PROTO SRC DST PORT
                while IFS='|' read -r SEQ DIR AIF ACT PROTO SRC DST PORT; do
                    [[ -n "$SEQ" ]] && printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" \
                        "$SEQ" "$DIR" "$AIF" "$ACT" "$PROTO" "$SRC" "$DST" "${PORT:-any}"
                done < "$ACLV2_FILE"
            fi ;;
        show\ ip\ route)   ip -4 route ;;
        show\ ipv6\ route) ip -6 route ;;
        show\ igmp)
            local _SNOOP="unknown"
            [[ -r "/sys/class/net/$BR/bridge/multicast_snooping" ]] \
                && _SNOOP=$(cat "/sys/class/net/$BR/bridge/multicast_snooping" 2>/dev/null)
            _section "IGMP snooping on $BR"
            [[ "$_SNOOP" == "1" ]] && echo "  enabled" || echo "  disabled"
            _section "Multicast group membership (mdb)"
            bridge mdb show dev "$BR" 2>/dev/null || echo "  (none / bridge not up)" ;;
        show\ lldp\ neighbors)
            _lldpd_check || return 1
            lldpcli show neighbors 2>&1 ;;
        show\ ospf*)
            _show_ospf "$(echo "$CMD" | cut -d' ' -f3-)" ;;
        show\ bgp*)
            _show_bgp "$(echo "$CMD" | cut -d' ' -f3)" "$(echo "$CMD" | cut -d' ' -f4)" ;;
        show\ rpki)          _show_rpki ;;
        show\ vrrp)          _vrrp_cmd show ;;
        show\ frr)           _frr_admin status ;;
        show\ running-config) show_running_config ;;
        show\ tech-support)   show_tech_support ;;
        show\ prefix-list)   _prefixlist_cmd show ;;
        show\ routemap)      _routemap_cmd show ;;
        show\ qos*)
            qos_show "$(echo "$CMD" | awk '{print $3}')" ;;
        capture*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            validate_iface "$IFACE" || return 1
            if [[ "$WEBEXEC_MODE" == "1" ]]; then
                log CMD "tcpdump on $IFACE (10s capture, non-interactive)"
                timeout 10 tcpdump -i "$IFACE" -l 2>&1
                log OK "Capture finished (10s)."
            else
                log CMD "tcpdump on $IFACE (press 'q' or Ctrl+C to stop)"
                tcpdump -i "$IFACE" -l &
                _CAP_PID=$!
                trap "kill $_CAP_PID 2>/dev/null" INT
                while kill -0 "$_CAP_PID" 2>/dev/null; do
                    read -rsn1 -t 0.3 _CAP_KEY
                    if [[ "$_CAP_KEY" == "q" || "$_CAP_KEY" == "Q" ]]; then
                        kill "$_CAP_PID" 2>/dev/null
                        break
                    fi
                done
                wait "$_CAP_PID" 2>/dev/null
                trap _on_exit EXIT TERM
                trap 'echo; continue' INT
                log OK "Capture stopped."
            fi ;;
        subif*)
            IFACE=$(echo "$CMD" | awk '{print $2}')
            VLAN=$(echo "$CMD"  | awk '{print $3}')
            validate_iface "$IFACE" && validate_vlan "$VLAN" || return 1
            SUBIF="${IFACE}.${VLAN}"
            if (( ${#SUBIF} > 15 )); then
                log ERROR "Sub-interface name '$SUBIF' is too long (${#SUBIF} chars, Linux limit is 15)."
                log INFO  "  Parent interface '$IFACE' is too long for a VLAN sub-interface name."
                log INFO  "  Rename the parent link first (e.g. 'ip link set $IFACE name wan0') or use a shorter VLAN id."
                return 1
            fi
            if ip link add link "$IFACE" name "$SUBIF" type vlan id "$VLAN" 2>/tmp/.ncos_subif_err; then
                ip link set "$SUBIF" up 2>/dev/null
                track_subif "$SUBIF"
                log OK "Sub-interface $SUBIF created."
            else
                log ERROR "Failed to create sub-interface $SUBIF: $(cat /tmp/.ncos_subif_err 2>/dev/null)"
            fi
            rm -f /tmp/.ncos_subif_err ;;
        nat\ enable*) fw_allow_wan ;;
        vrf\ create*)
            if [[ "$MODE" == "router" ]]; then
                NAME=$(echo "$CMD" | awk '{print $3}')
                require_args "$NAME" 1 "vrf create <name>" || return 1
                if ip link show "$NAME" &>/dev/null; then
                    log ERROR "'$NAME' already exists."; return 1
                fi
                TABLE=10
                while grep -q "|${TABLE}\$" "$VRFS_FILE" 2>/dev/null; do
                    TABLE=$((TABLE + 1))
                done
                ip link add "$NAME" type vrf table "$TABLE" 2>/dev/null \
                    || { log ERROR "Failed to create VRF '$NAME'."; return 1; }
                ip link set "$NAME" up 2>/dev/null
                echo "${NAME}|${TABLE}" >> "$VRFS_FILE"
                log OK "VRF '$NAME' created (table $TABLE). Use 'vrf assign <iface> $NAME' to add interfaces."
            else log ERROR "Not in router mode."; fi ;;
        vrf\ assign*)
            if [[ "$MODE" == "router" ]]; then
                IFACE=$(echo "$CMD" | awk '{print $3}')
                NAME=$(echo "$CMD"  | awk '{print $4}')
                validate_iface "$IFACE" || return 1
                grep -q "^${NAME}|" "$VRFS_FILE" 2>/dev/null || { log ERROR "VRF '$NAME' does not exist. Create it first: vrf create $NAME"; return 1; }
                ip link set "$IFACE" master "$NAME" 2>/dev/null \
                    && log OK "$IFACE assigned to VRF '$NAME'." \
                    || log ERROR "Failed to assign $IFACE to VRF '$NAME'."
            else log ERROR "Not in router mode."; fi ;;
        vrf\ unassign*)
            if [[ "$MODE" == "router" ]]; then
                IFACE=$(echo "$CMD" | awk '{print $3}')
                validate_iface "$IFACE" || return 1
                ip link set "$IFACE" nomaster 2>/dev/null \
                    && log OK "$IFACE removed from its VRF."
            else log ERROR "Not in router mode."; fi ;;
        vrf\ delete*)
            if [[ "$MODE" == "router" ]]; then
                NAME=$(echo "$CMD" | awk '{print $3}')
                require_args "$NAME" 1 "vrf delete <name>" || return 1
                ip link del "$NAME" 2>/dev/null && log OK "VRF '$NAME' deleted."
                grep -v "^${NAME}|" "$VRFS_FILE" > "${VRFS_FILE}.tmp" 2>/dev/null \
                    && mv "${VRFS_FILE}.tmp" "$VRFS_FILE"
            else log ERROR "Not in router mode."; fi ;;
        vrf\ show)
            if [[ "$MODE" == "router" ]]; then
                echo -e "${BOLD}--- VRFs ---${NC}"
                FOUND=0
                while IFS='|' read -r NAME TABLE; do
                    [[ -n "$NAME" ]] || continue
                    MEMBERS=$(ip -o link show 2>/dev/null \
                        | awk -F': ' -v n="$NAME" '$0 ~ ("master "n" "){print $2}' \
                        | paste -sd, -)
                    printf "  %-14s table %-6s members: %s\n" "$NAME" "$TABLE" "${MEMBERS:-(none)}"
                    FOUND=1
                done < "$VRFS_FILE"
                (( FOUND == 0 )) && echo "  (none)"
            else log ERROR "Not in router mode."; fi ;;
        ospf*)
            read -ra _WEO <<< "$CMD"; _ospf_cmd "${_WEO[@]:1}" ;;
        bgp*)
            read -ra _WEB <<< "$CMD"; _bgp_cmd "${_WEB[@]:1}" ;;
        bfd*)
            read -ra _WEF <<< "$CMD"; _bfd_cmd "${_WEF[@]:1}" ;;
        vrrp*)
            read -ra _WEV <<< "$CMD"; _vrrp_cmd "${_WEV[@]:1}" ;;
        rpki*)
            read -ra _WER <<< "$CMD"; _rpki_cmd "${_WER[@]:1}" ;;
        routemap*)
            read -ra _WEM <<< "$CMD"; _routemap_cmd "${_WEM[@]:1}" ;;
        prefix-list*)
            read -ra _WEP <<< "$CMD"; _prefixlist_cmd "${_WEP[@]:1}" ;;
        frr*)
            read -ra _WEFR <<< "$CMD"; _frr_admin "${_WEFR[@]:1}" ;;
        ping*)
            TARGET=$(echo "$CMD" | awk '{print $2}')
            COUNT=$(echo "$CMD"  | awk '{print $3}')
            require_args "$TARGET" 1 "ping <ip> [count]" || return 1
            do_ping "$TARGET" "${COUNT:-4}" ;;
        traceroute*)
            TARGET=$(echo "$CMD" | awk '{print $2}')
            require_args "$TARGET" 1 "traceroute <ip>" || return 1
            do_traceroute "$TARGET" ;;
        arp\ static\ add*)
            arp_static_add \
                "$(echo "$CMD" | awk '{print $4}')" \
                "$(echo "$CMD" | awk '{print $5}')" \
                "$(echo "$CMD" | awk '{print $6}')" ;;
        arp\ static\ del*)
            arp_static_del \
                "$(echo "$CMD" | awk '{print $4}')" \
                "$(echo "$CMD" | awk '{print $5}')" ;;
        arp)       do_arp ;;
        netstat)   do_netstat ;;
        bandwidth\ test*)
            bandwidth_test "$(echo "$CMD" | awk '{print $3}')" \
                           "$(echo "$CMD" | awk '{print $4}')" \
                           "$(echo "$CMD" | awk '{print $5}')" ;;
        bandwidth*)
            do_bandwidth "$(echo "$CMD" | awk '{print $2}')" ;;
        firewall\ init) fw_init ;;
        firewall\ allow*)
            TYPE=$(echo "$CMD" | awk '{print $3}')
            case "$TYPE" in
                wan)  fw_allow_wan ;;
                vlan)
                    VLAN=$(echo "$CMD" | awk '{print $4}')
                    validate_vlan "$VLAN" || return 1
                    fw_allow_vlan "${BR}.${VLAN}" ;;
                *) log ERROR "Unknown type '$TYPE'. Use: vlan <id> | wan" ;;
            esac ;;
        acl\ deny*)
            SRC=$(echo "$CMD" | awk '{print $3}')
            DST=$(echo "$CMD" | awk '{print $4}')
            [[ -n "$SRC" && -n "$DST" ]] \
                || { log ERROR "Usage: acl deny <src_if> <dst_if>"; return 1; }
            fw_acl_deny "$SRC" "$DST" ;;
        acl\ allow*)
            SRC=$(echo "$CMD"   | awk '{print $3}')
            DST=$(echo "$CMD"   | awk '{print $4}')
            PROTO=$(echo "$CMD" | awk '{print $5}')
            PORT=$(echo "$CMD"  | awk '{print $6}')
            [[ -n "$SRC" && -n "$DST" && -n "$PROTO" && -n "$PORT" ]] \
                || { log ERROR "Usage: acl allow <src_if> <dst_if> <proto> <port>"; return 1; }
            validate_proto "$PROTO" && validate_port "$PORT" || return 1
            fw_acl_allow_port "$SRC" "$DST" "$PROTO" "$PORT" ;;
        acl\ matrix) show_acl_matrix ;;
        acl\ in*|acl\ out*)
            DIR=$(echo "$CMD"    | awk '{print $2}')
            AIFACE=$(echo "$CMD" | awk '{print $3}')
            ACTION=$(echo "$CMD" | awk '{print $4}')
            PROTO=$(echo "$CMD"  | awk '{print $5}')
            SRC=$(echo "$CMD"    | awk '{print $6}')
            DST=$(echo "$CMD"    | awk '{print $7}')
            PORT=$(echo "$CMD"   | awk '{print $8}')
            if [[ -z "$AIFACE" || -z "$ACTION" || -z "$PROTO" || -z "$SRC" || -z "$DST" ]]; then
                log ERROR "Usage: acl <in|out> <iface> <permit|deny> <proto> <src> <dst> [port]"
                return 1
            fi
            _acl2_add "$DIR" "$AIFACE" "$ACTION" "$PROTO" "$SRC" "$DST" "$PORT" ;;
        acl\ show)
            _section "ACLs (acl in/out)"
            if [[ -s "$ACLV2_FILE" ]]; then
                printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" SEQ DIR IFACE ACTION PROTO SRC DST PORT
                while IFS='|' read -r SEQ DIR AIF ACT PROTO SRC DST PORT; do
                    [[ -n "$SEQ" ]] && printf "  %-4s %-4s %-10s %-6s %-6s %-20s %-20s %s\n" \
                        "$SEQ" "$DIR" "$AIF" "$ACT" "$PROTO" "$SRC" "$DST" "${PORT:-any}"
                done < "$ACLV2_FILE"
            else
                echo "  (none)"
            fi ;;
        acl\ remove*) _acl2_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        ratelimit*)
            IFACE=$(echo "$CMD"   | awk '{print $2}')
            SRC_IP=$(echo "$CMD"  | awk '{print $3}')
            KBPS=$(echo "$CMD"    | awk '{print $4}')
            validate_iface "$IFACE" && validate_ip "$SRC_IP" \
                && validate_positive_int "$KBPS" "kbps" || return 1
            fw_ratelimit "$IFACE" "$SRC_IP" "$KBPS" ;;
        show\ versions)      show_versions ;;
        clear)               do_clear ;;
        show\ log\ live)     show_log_live ;;
        arp\ flush*)
            arp_flush "$(echo "$CMD" | awk '{print $3}')" ;;
        dns\ set*)
            dns_set "$(echo "$CMD" | awk '{print $3}')" ;;
        dns\ lookup*)
            dns_lookup "$(echo "$CMD" | awk '{print $3}')" ;;
        show\ dns)           show_dns ;;
        whois*)
            do_whois "$(echo "$CMD" | awk '{print $2}')" ;;
        set\ mtu*)
            set_mtu "$(echo "$CMD" | awk '{print $3}')" "$(echo "$CMD" | awk '{print $4}')" ;;
        set\ speed*)
            set_speed "$(echo "$CMD" | awk '{print $3}')" "$(echo "$CMD" | awk '{print $4}')" ;;
        set\ mac*)
            set_mac "$(echo "$CMD" | awk '{print $3}')" "$(echo "$CMD" | awk '{print $4}')" ;;
        show\ open\ ports)   show_open_ports ;;
        open\ port*)
            open_port "$(echo "$CMD" | awk '{print $3}')" "$(echo "$CMD" | awk '{print $4}')" ;;
        close\ port*)
            close_port "$(echo "$CMD" | awk '{print $3}')" "$(echo "$CMD" | awk '{print $4}')" ;;
        show\ connections)   show_connections ;;
        block\ ip*)
            block_ip "$(echo "$CMD" | awk '{print $3}')" ;;
        unblock\ ip*)
            unblock_ip "$(echo "$CMD" | awk '{print $3}')" ;;
        show\ blocked\ ips)  show_blocked_ips ;;
        gre\ create*)
            gre_create "$(echo "$CMD" | awk '{print $3}')" \
                       "$(echo "$CMD" | awk '{print $4}')" \
                       "$(echo "$CMD" | awk '{print $5}')" \
                       "$(echo "$CMD" | awk '{print $6}')" ;;
        gre\ remove*)
            gre_remove "$(echo "$CMD" | awk '{print $3}')" ;;
        gre\ show)            gre_show ;;
        ipsec*)
            read -ra _WEI <<< "$CMD"; _ipsec_cmd "${_WEI[@]:1}" ;;
        set\ timezone*)
            set_timezone "$(echo "$CMD" | awk '{print $3}')" ;;
        ntp\ sync*)
            ntp_sync "$(echo "$CMD" | awk '{print $3}')" ;;
        reboot)               do_reboot ;;
        shutdown)             do_shutdown ;;
        run\ system*)
            run_system "$(echo "$CMD" | cut -d' ' -f3-)" ;;
        show\ traffic*)
            do_bandwidth "$(echo "$CMD" | awk '{print $3}')" ;;
        port\ forward\ remove*)
            port_forward_remove "$(echo "$CMD" | awk '{print $4}')" ;;
        port\ forward*)
            port_forward "$(echo "$CMD" | awk '{print $3}')" \
                         "$(echo "$CMD" | awk '{print $4}')" \
                         "$(echo "$CMD" | awk '{print $5}')" \
                         "$(echo "$CMD" | awk '{print $6}')" ;;
        show\ nat)           show_nat ;;
        wireguard*)
            wireguard_cmd "$(echo "$CMD" | awk '{print $2}')" \
                          "$(echo "$CMD" | awk '{print $3}')" \
                          "$(echo "$CMD" | awk '{print $4}')" \
                          "$(echo "$CMD" | awk '{print $5}')" \
                          "$(echo "$CMD" | awk '{print $6}')" \
                          "$(echo "$CMD" | cut -d' ' -f7-)" ;;
        *) log ERROR "Unknown command: '$CMD'. Type 'help'." ;;
    esac
    return 0
}
_webexec_run() {
    local CMD="$WEB_CMD"
    [[ -z "${CMD// }" ]] && echo "(empty command)" && return
    local EXPANDED; EXPANDED=$(alias_resolve "$CMD" 2>/dev/null)
    [[ -n "$EXPANDED" ]] && CMD="$EXPANDED"
    log CMD "[WEB:$MODE] $CMD"
    WEBEXEC_MODE=1
    _dispatch_cmd "$CMD"
    WEBEXEC_MODE=0
}
HISTFILE="$HISTORY_FILE"
bind 'set completion-ignore-case on' 2>/dev/null
bind 'set show-all-if-ambiguous on' 2>/dev/null
bind 'TAB:menu-complete' 2>/dev/null
bind '"\e[Z":menu-complete-backward' 2>/dev/null
HISTSIZE=1000
HISTFILESIZE=2000
set -o history 2>/dev/null
_netcoreos_complete() {
    local CMDS_LINUX="switch switch-mls router firewall instance config alias backup restore health version status schedule log web webui help exit bfd frr ospf bgp vrrp rpki routemap prefix-list set dns whois show open close block unblock gre ipsec ntp reboot shutdown run clear ipaddr change description lldp write boot-persist console"
    local CMDS_SWITCH="vlan svi ipaddr access trunk stp rstp mstp port-security bpdu-guard root-guard loop-guard portfast err-disable storm-control lacp vxlan mirror pvlan qinq show capture back help change description igmp lldp"
    local CMDS_MLS="$CMDS_SWITCH dhcp dhcp6 route"
    local CMDS_ROUTER="subif ipaddr route nat dhcp dhcp6 vrf ospf bgp vrrp rpki routemap prefix-list frr qos monitor show ping traceroute arp bandwidth netstat back help version change description lldp"
    local CMDS_FW="firewall acl ratelimit show back help change description"
    case "$MODE" in
        ncos)       COMPREPLY=( $(compgen -W "$CMDS_LINUX"  -- "${COMP_WORDS[COMP_CWORD]}") ) ;;
        switch)     COMPREPLY=( $(compgen -W "$CMDS_SWITCH" -- "${COMP_WORDS[COMP_CWORD]}") ) ;;
        switch-mls) COMPREPLY=( $(compgen -W "$CMDS_MLS"   -- "${COMP_WORDS[COMP_CWORD]}") ) ;;
        router)     COMPREPLY=( $(compgen -W "$CMDS_ROUTER" -- "${COMP_WORDS[COMP_CWORD]}") ) ;;
        firewall)   COMPREPLY=( $(compgen -W "$CMDS_FW"    -- "${COMP_WORDS[COMP_CWORD]}") ) ;;
    esac
}
complete -F _netcoreos_complete netcoreos 2>/dev/null
if [[ "${1}" == "--web-exec" ]]; then
    trap - EXIT INT TERM
    shift
    WEB_CMD="$*"
    _load_web_state
    confirm() { return 0; }
    select_bridge_members() {
        while IFS= read -r LINE; do
            local IF; IF=$(echo "$LINE" | awk '{print $1}')
            [[ "$IF" == lo || "$IF" == "$BR" || "$IF" == "$WAN_IF" ]] && continue
            ip link show "$IF" 2>/dev/null | grep -q master && continue
            [[ "$IF" == *.* ]] && continue
            _bridge_snap_iface "$IF" 2>/dev/null
            ip link set "$IF" down 2>/dev/null
            ip addr flush dev "$IF" 2>/dev/null
            ip link set "$IF" master "$BR" 2>/dev/null
            ip link set "$IF" up 2>/dev/null
        done < <(ip -br link show 2>/dev/null)
    }
    _webexec_run 2>&1
    _save_web_state
    exit 0
fi
if [[ "${1}" == "--apply-startup" ]]; then
    trap - EXIT INT TERM
    WEBEXEC_MODE=1
    if [[ ! -f "$CONFIGS_DIR/startup.cfg" ]]; then
        log INFO "No startup config saved (run 'write' first) — nothing to apply."
        exit 0
    fi
    confirm() { return 0; }
    select_bridge_members() {
        while IFS= read -r LINE; do
            local IF; IF=$(echo "$LINE" | awk '{print $1}')
            [[ "$IF" == lo || "$IF" == "$BR" || "$IF" == "$WAN_IF" ]] && continue
            ip link show "$IF" 2>/dev/null | grep -q master && continue
            [[ "$IF" == *.* ]] && continue
            _bridge_snap_iface "$IF" 2>/dev/null
            ip link set "$IF" down 2>/dev/null
            ip addr flush dev "$IF" 2>/dev/null
            ip link set "$IF" master "$BR" 2>/dev/null
            ip link set "$IF" up 2>/dev/null
        done < <(ip -br link show 2>/dev/null)
    }
    log INFO "Applying startup config..."
    config_load "startup"
    _save_web_state
    exit 0
fi
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  _   _      _    ____                 ___  ____
 | \ | | ___| |_ / ___|___  _ __ ___  / _ \/ ___|
 |  \| |/ _ \ __| |   / _ \| '__/ _ \| | | \___ \
 | |\  |  __/ |_| |__| (_) | | |  __/| |_| |___) |
 |_| \_|\___|\__|\____\___/|_|  \___| \___/|____/
BANNER
echo -e "${NC}"
echo -e " ${BOLD}$VERSION${NC}  ${DIM}by $AUTHOR${NC}"
echo -e " Base: ${DIM}$BASE_DIR${NC}   Log: ${CYAN}$LOG_FILE${NC}"
if [[ "$MODE" != "ncos" ]]; then
    echo -e " ${YELLOW}Resuming previous session — mode: ${BOLD}$MODE${NC}${YELLOW}, bridge: $BR${NC}"
fi
echo -e " Type ${BOLD}help${NC} or ${BOLD}dashboard${NC} to get started.\n"
check_deps
if [[ -z "${SSH_CONNECTION:-}" ]]; then
    _login_gate
fi
_prompt() {
    case "$MODE" in
        ncos)       echo -e "${GREEN}ncos${NC}:${DIM}$(uptime_str)${NC}# " ;;
        switch)     echo -e "${CYAN}switch${NC}:${DIM}$(uptime_str)${NC}# " ;;
        switch-mls) echo -e "${CYAN}mls${NC}:${DIM}$(uptime_str)${NC}# " ;;
        router)     echo -e "${YELLOW}router${NC}:${DIM}$(uptime_str)${NC}# " ;;
        firewall)   echo -e "${RED}firewall${NC}:${DIM}$(uptime_str)${NC}# " ;;
    esac
}
while true; do
    trap 'echo; continue' INT
    read -e -p "$(_prompt)" CMD
    [[ -z "${CMD// }" ]] && continue
    EXPANDED=$(alias_resolve "$CMD")
    [[ -n "$EXPANDED" ]] && CMD="$EXPANDED" && log INFO "Alias expanded: $CMD"
    history -s "$CMD"
    log CMD "[$MODE] $CMD"
    _dispatch_cmd "$CMD"
    [[ $? -eq 90 ]] && break
done
