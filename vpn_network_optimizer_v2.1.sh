#!/usr/bin/env bash
# VPN Network Optimizer v2.1
#
# Usage:
#   ./vpn_network_optimizer_v2.1.sh [--role xray|forwarder] [--upgrade] [--reboot] [--uninstall]
#
#   --role xray        (default) server that runs Xray/V2Ray itself (Docker nodes included)
#   --role forwarder   iptables port-forward relay (skips xray/x-ui service limits)
#   --upgrade          also run apt update + dist-upgrade (OFF by default)
#   --reboot           reboot at the end, ONLY if the system says a reboot is required (OFF by default)
#   --uninstall        remove files written by this script
#
# By default the script only applies sysctl/limits live: no upgrade, no reboot, no user disconnects.
#
# conntrack (v2.1): this script is the ONLY owner of nf_conntrack tuning, for BOTH roles.
#   - nf_conntrack is loaded now and at every boot (modules-load.d), even on a fresh server
#     where Docker/ufw/iptables are not installed yet, so the limits are in place before they arrive.
#   - nf_conntrack_max is chosen from RAM (override: CT_MAX=1048576 ./script.sh) and never lowered.
#   - hash table size (max/4) is set live and persisted via modprobe.d.
#   port-forward.sh only sets ip_forward and warns if conntrack looks untuned.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="VPN Network Optimizer"
SCRIPT_VERSION="2.1.0"
CONF_FILE="/etc/sysctl.d/99-vpn-network-optimizer.conf"
CT_CONF_FILE="/etc/sysctl.d/99-vpn-network-optimizer-ct.conf"
LIMITS_FILE="/etc/security/limits.d/99-vpn-network-optimizer.conf"
DROPIN_NAME="99-vpn-network-optimizer.conf"
MODLOAD_FILE="/etc/modules-load.d/vpn-network-optimizer.conf"
MODPROBE_FILE="/etc/modprobe.d/vpn-network-optimizer.conf"
BACKUP_BASE="/root/vpn-network-optimizer-backup"
BACKUP_ROOT=""
LOG_FILE="/var/log/vpn-network-optimizer.log"
REBOOT_DELAY=10
CT_MAX_TARGET=0                        # chosen from RAM in detect_memory_profile; override: CT_MAX=1048576 ./script.sh
CT_HASH_TARGET=0
CT_OK=0                                # set to 1 once nf_conntrack is loaded and configured

ROLE="xray"
DO_UPGRADE=0
DO_REBOOT=0
DO_UNINSTALL=0
BUF_MAX=33554432

usage() {
    cat <<EOF
Usage: $0 [--role xray|forwarder] [--upgrade] [--reboot] [--uninstall]

  --role xray        (default) server running Xray/V2Ray (Docker nodes included)
  --role forwarder   iptables port-forward relay server

Env: CT_MAX=<n>  override nf_conntrack_max (only raises, never lowers)
  --upgrade          also run apt dist-upgrade (default: off)
  --reboot           reboot at the end only if required (default: off)
  --uninstall        remove files written by this script
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2
    exit 1
}

cleanup_on_error() {
    local rc=$?
    if (( rc != 0 )); then
        printf '\n[%s] Script stopped with exit code %d. No reboot will be performed.\n' "$(date '+%F %T')" "$rc" | tee -a "$LOG_FILE" >&2
        printf 'Backup directory: %s\nLog file: %s\n' "${BACKUP_ROOT:-none}" "$LOG_FILE" | tee -a "$LOG_FILE" >&2
    fi
    exit "$rc"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --role)
                [[ $# -ge 2 ]] || { echo "--role needs a value" >&2; exit 2; }
                ROLE="$2"; shift 2 ;;
            --role=*)    ROLE="${1#*=}"; shift ;;
            --upgrade)   DO_UPGRADE=1; shift ;;
            --reboot)    DO_REBOOT=1; shift ;;
            --uninstall) DO_UNINSTALL=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
    case "$ROLE" in
        xray|forwarder) ;;
        *) echo "Invalid --role: $ROLE (use xray or forwarder)" >&2; exit 2 ;;
    esac
}

require_root() {
    [[ $EUID -eq 0 ]] || fail "Run this script as root."
}

check_os() {
    [[ -r /etc/os-release ]] || fail "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) fail "Supported: Ubuntu/Debian. Detected: ${ID:-unknown}" ;;
    esac
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]]; then
        log "OS check passed: Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-unknown})"
    else
        warn "Tested on Ubuntu 22.04; detected ${ID:-?} ${VERSION_ID:-?}. Continuing."
    fi
}

check_commands() {
    local missing=()
    local cmd
    for cmd in awk cp date grep mkdir modprobe sysctl tee uname tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || fail "Missing required commands: ${missing[*]}"
    if (( DO_UPGRADE )); then
        command -v apt-get >/dev/null 2>&1 || fail "apt-get not found (needed for --upgrade)"
    fi
}

backup_file() {
    local file="$1"
    if [[ -e "$file" ]]; then
        cp -a -- "$file" "$BACKUP_ROOT/${file//\//_}.bak"
        log "Backed up $file"
    fi
}

create_backup() {
    BACKUP_ROOT="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_ROOT"
    backup_file /etc/sysctl.conf
    backup_file "$CONF_FILE"
    backup_file "$CT_CONF_FILE"
    backup_file "$LIMITS_FILE"
    backup_file "$MODLOAD_FILE"
    backup_file "$MODPROBE_FILE"
    if [[ -d /etc/sysctl.d ]]; then
        tar -C /etc -czf "$BACKUP_ROOT/sysctl.d.tar.gz" sysctl.d 2>/dev/null || warn "Could not archive /etc/sysctl.d; continuing."
    fi
    if [[ -d /etc/security/limits.d ]]; then
        tar -C /etc/security -czf "$BACKUP_ROOT/limits.d.tar.gz" limits.d 2>/dev/null || warn "Could not archive limits.d; continuing."
    fi
    log "Backup created at $BACKUP_ROOT"
}

update_system() {
    # needrestart is suspended so services (xray) are NOT restarted behind your back.
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
    local opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    log "Updating package lists..."
    apt-get update
    log "Upgrading packages (dist-upgrade)..."
    apt-get "${opts[@]}" dist-upgrade
    log "Removing unused packages..."
    apt-get -y autoremove
    log "Package upgrade completed."
}

detect_memory_profile() {
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    if (( mem_kb < 1900000 )); then
        BUF_MAX=16777216
    else
        BUF_MAX=33554432
    fi
    log "RAM: $((mem_kb / 1024)) MB -> max TCP buffer $((BUF_MAX / 1048576)) MB"

    if [[ -n "${CT_MAX:-}" ]]; then
        [[ "$CT_MAX" =~ ^[0-9]+$ ]] && (( CT_MAX >= 65536 )) || fail "CT_MAX must be a number >= 65536 (got: $CT_MAX)"
        CT_MAX_TARGET="$CT_MAX"
    elif (( mem_kb < 3000000 )); then
        CT_MAX_TARGET=262144          # < 3 GB
    elif (( mem_kb < 7000000 )); then
        CT_MAX_TARGET=524288          # ~4-6 GB
    elif (( mem_kb < 14000000 )); then
        CT_MAX_TARGET=1048576         # ~8-12 GB
    else
        CT_MAX_TARGET=2097152         # 16 GB and up
    fi
    log "conntrack target: nf_conntrack_max=$CT_MAX_TARGET"
}

write_sysctl_config() {
    mkdir -p /etc/sysctl.d
    cat > "$CONF_FILE" <<SYSCTL
# VPN Network Optimizer v${SCRIPT_VERSION} (role: ${ROLE})
# Does NOT enable ip_forward and does NOT touch firewall rules.
# Note: TCP buffers / congestion control only affect sockets terminated on THIS host.
# On a pure iptables forwarder they matter little; conntrack matters (see the -ct.conf file,
# written for BOTH roles by this script).

# Congestion control + queueing (BBR needs fq)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Backlogs
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 32768

# Socket memory ceilings (autotuning grows buffers up to the max)
net.core.rmem_max = ${BUF_MAX}
net.core.wmem_max = ${BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 ${BUF_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${BUF_MAX}

# Connection handling
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_retries2 = 12

# Keepalive (dead-peer detection for long-lived connections)
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 7

# Compatibility with heterogeneous client networks
net.ipv4.tcp_ecn = 0

# Loose reverse-path filtering (friendlier to asymmetric routing)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2

# Neighbor/ARP cache sizing
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60

# Fragmentation cache bounds
net.ipv4.ipfrag_high_thresh = 16777216
net.ipv4.ipfrag_low_thresh = 12582912
net.ipv4.ipfrag_time = 30

# File descriptors
fs.file-max = 67108864
SYSCTL
    log "Wrote $CONF_FILE"
}

# conntrack tuning, for BOTH roles. This script is the single owner of these keys.
# nf_conntrack is loaded here (and at every boot via modules-load.d) so the settings exist
# even on a fresh server where Docker / ufw / iptables are not installed yet.
write_ct_config() {
    local cur want hash hs hcur
    want="$CT_MAX_TARGET"
    hash=$(( want / 4 ))

    # The module only reads modprobe.d options when it is LOADED, so write them first.
    mkdir -p /etc/modprobe.d
    printf '# VPN Network Optimizer: conntrack hash table size (~max/4)\noptions nf_conntrack hashsize=%s\n' "$hash" > "$MODPROBE_FILE"

    if [[ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        modprobe nf_conntrack 2>/dev/null || true
    fi
    if [[ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        rm -f "$CT_CONF_FILE" "$MODPROBE_FILE"
        CT_OK=0
        warn "nf_conntrack cannot be loaded here (container / restricted kernel?); conntrack tuning skipped."
        return 0
    fi

    # never lower a value that is already higher (e.g. set earlier by an older script)
    cur="$(sysctl -n net.netfilter.nf_conntrack_max)"
    if (( cur > want )); then
        want="$cur"
        hash=$(( want / 4 ))
        printf '# VPN Network Optimizer: conntrack hash table size (~max/4)\noptions nf_conntrack hashsize=%s\n' "$hash" > "$MODPROBE_FILE"
    fi
    CT_MAX_TARGET="$want"
    CT_HASH_TARGET="$hash"

    cat > "$CT_CONF_FILE" <<CT
# VPN Network Optimizer - conntrack (both roles; single owner of these keys)
net.netfilter.nf_conntrack_max = ${want}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
CT
    log "Wrote $CT_CONF_FILE (nf_conntrack_max=$want)"
    log "Wrote $MODPROBE_FILE (hashsize=$hash)"

    # resize the hash table live (grow only); a no-op if the module was just loaded with the new size
    hs=/sys/module/nf_conntrack/parameters/hashsize
    if [[ -w "$hs" ]]; then
        hcur="$(<"$hs")"
        if (( hcur < hash )); then
            if echo "$hash" > "$hs" 2>/dev/null; then
                log "nf_conntrack hashsize: $hcur -> $hash"
            else
                warn "could not resize nf_conntrack hash table live (it will apply at next boot)"
            fi
        fi
    fi
    CT_OK=1
}

write_limits_config() {
    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_FILE" <<'LIMITS'
# VPN Network Optimizer - applies to PAM login sessions only (NOT to systemd services)
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
    log "Wrote $LIMITS_FILE"
}

# limits.d does not apply to systemd services, so add a drop-in for xray / x-ui.
# The service is NOT restarted; restart it yourself at a quiet time.
write_service_limits() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit dir changed=0
    for unit in xray x-ui; do
        if systemctl cat "${unit}.service" >/dev/null 2>&1; then
            dir="/etc/systemd/system/${unit}.service.d"
            mkdir -p "$dir"
            printf '[Service]\nLimitNOFILE=1048576\n' > "$dir/$DROPIN_NAME"
            log "Wrote systemd drop-in for ${unit}.service (LimitNOFILE=1048576). Restart it to apply: systemctl restart ${unit}"
            changed=1
        fi
    done
    if (( changed )); then
        systemctl daemon-reload || warn "systemctl daemon-reload failed"
    fi
}

ensure_modules() {
    if ! grep -q '^tcp_bbr ' /proc/modules 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null || warn "Could not load tcp_bbr (kernel without BBR, or container?)"
    fi
    # load at boot too: nf_conntrack must be present BEFORE systemd-sysctl applies the conntrack keys
    mkdir -p /etc/modules-load.d
    {
        echo "tcp_bbr"
        if (( CT_OK )); then echo "nf_conntrack"; fi
    } > "$MODLOAD_FILE"
}

apply_sysctl() {
    log "Loading sysctl configuration..."
    if ! sysctl --system 2>&1 | tee -a "$LOG_FILE" >/dev/null; then
        warn "sysctl --system reported errors (some keys may be unsupported on this kernel/VPS). See log."
    fi
}

# Compare what we wrote with what the kernel actually has (catches overrides by other conf files).
verify_settings() {
    local f line key val got bad=0
    for f in "$CONF_FILE" "$CT_CONF_FILE"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
            key="${line%%=*}"
            val="${line#*=}"
            key="${key//[[:space:]]/}"
            val="$(awk '{$1=$1}1' <<<"$val")"
            got="$(sysctl -n "$key" 2>/dev/null | awk '{$1=$1}1' || true)"
            if [[ "$got" != "$val" ]]; then
                warn "MISMATCH $key: wanted '$val', kernel has '${got:-<unsupported>}'"
                bad=$((bad + 1))
            fi
        done < "$f"
    done
    if (( bad == 0 )); then
        log "Verified: all settings match the running kernel."
    else
        warn "$bad setting(s) differ. Check other files: grep -rn KEY /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d"
    fi
    if (( CT_OK )) && [[ -r /sys/module/nf_conntrack/parameters/hashsize ]]; then
        local hcur
        hcur="$(</sys/module/nf_conntrack/parameters/hashsize)"
        if (( hcur < CT_HASH_TARGET )); then
            warn "conntrack hashsize is $hcur (wanted $CT_HASH_TARGET); it will apply at next boot."
        fi
    fi
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
    if [[ "$cc" != "bbr" ]]; then
        warn "BBR is NOT active (current: $cc). Your kernel/VPS may not support it."
    fi
}

show_summary() {
    printf '\n'
    printf '%s\n' '==============================================='
    printf '%s\n' " $SCRIPT_NAME v$SCRIPT_VERSION (role: $ROLE)"
    printf '%s\n' '==============================================='
    printf 'Kernel:             %s\n' "$(uname -r)"
    printf 'Qdisc:              %s\n' "$(sysctl -n net.core.default_qdisc)"
    printf 'Congestion control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control)"
    printf 'TCP buffer max:     %s MB\n' "$((BUF_MAX / 1048576))"
    printf 'IP forwarding:      %s (not changed by this script)\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    if (( CT_OK )); then
        printf 'Conntrack max:      %s (hash buckets: %s)\n' "$(sysctl -n net.netfilter.nf_conntrack_max)" "$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo '?')"
    else
        printf 'Conntrack:          not configured (module unavailable)\n'
    fi
    printf 'Config:             %s\n' "$CONF_FILE"
    printf 'Backup:             %s\n' "$BACKUP_ROOT"
    printf 'Log:                %s\n' "$LOG_FILE"
    printf '%s\n' '==============================================='
    printf '\n'
}

do_uninstall() {
    log "Uninstalling..."
    rm -f "$CONF_FILE" "$CT_CONF_FILE" "$LIMITS_FILE" "$MODLOAD_FILE" "$MODPROBE_FILE"
    local unit
    for unit in xray x-ui; do
        rm -f "/etc/systemd/system/${unit}.service.d/$DROPIN_NAME"
        rmdir "/etc/systemd/system/${unit}.service.d" 2>/dev/null || true
    done
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    sysctl --system >/dev/null 2>&1 || true
    log "Removed. Running kernel values stay until the next reboot (or set them manually)."
    warn "conntrack tuning is removed too: on a forwarder / Docker node, re-run this script to restore it."
}

finish_reboot() {
    if [[ -f /var/run/reboot-required ]]; then
        if (( DO_REBOOT )); then
            log "Reboot is required and --reboot was given. Rebooting in ${REBOOT_DELAY} seconds (Ctrl+C to cancel)."
            trap - EXIT
            sleep "$REBOOT_DELAY"
            exec /sbin/reboot
        else
            warn "A reboot is required (kernel/libs updated). Do it at a quiet time: reboot"
        fi
    else
        log "No reboot required. Settings are already active."
    fi
}

main() {
    parse_args "$@"
    require_root
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    trap cleanup_on_error EXIT
    log "Starting $SCRIPT_NAME v$SCRIPT_VERSION (role=$ROLE upgrade=$DO_UPGRADE reboot=$DO_REBOOT)"
    check_os
    check_commands

    if (( DO_UNINSTALL )); then
        do_uninstall
        return 0
    fi

    create_backup
    if (( DO_UPGRADE )); then
        update_system
    else
        log "Skipping apt upgrade (use --upgrade to enable)."
    fi
    detect_memory_profile
    write_sysctl_config
    write_ct_config
    ensure_modules
    write_limits_config
    if [[ "$ROLE" == "xray" ]]; then
        write_service_limits
    fi
    apply_sysctl
    verify_settings
    show_summary
    finish_reboot
}

main "$@"
