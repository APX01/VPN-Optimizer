#!/bin/sh
# port-forward.sh v2.1 - TCP+UDP port forwarding with iptables (Ubuntu 22.04, IPv4)
#
# Usage:
#   port-forward.sh IP PORT          add forward  (local PORT -> IP:PORT, tcp+udp)
#   port-forward.sh add IP PORT      same as above
#   port-forward.sh del IP PORT      remove forward (or: del PORT)
#   port-forward.sh list             show configured forwards
#   port-forward.sh status           conntrack usage + per-port flow counts
#   port-forward.sh apply            re-apply saved rules (used by systemd at boot)
#   port-forward.sh install          re-apply + (re)install script and systemd unit (use after an update)
#
# Persistence: rules are stored in /etc/port-forward/rules.conf and re-applied
# at boot by the port-forward.service systemd unit. Only our own chains
# (PF_PRE, PF_POST, PF_FWD, PF_MSS) are touched; other firewall rules are left alone.
#
# Env overrides: MSS_CLAMP=0 (disable TCP MSS clamping)
#
# conntrack (v2.1): tuning of nf_conntrack (max, hash size, timeouts) is owned by
# vpn_network_optimizer (run it first with --role forwarder). This script only
#   - enables net.ipv4.ip_forward (needed for forwarding to work at all),
#   - makes sure the nf_conntrack module is loaded,
#   - warns if conntrack looks untuned.
# This avoids two scripts writing the same sysctl keys.
#
# Notes:
#  - The backend sees ALL users as this server's IP (MASQUERADE).
#  - NAT port space limits each (backend IP, port, proto) to roughly 64k concurrent flows.

set -eu

NAME=port-forward
ROOT=${PF_ROOT:-}                       # testing only; leave empty in production
BIN=$ROOT/usr/local/sbin/$NAME
CONF_DIR=$ROOT/etc/$NAME
CONF=$CONF_DIR/rules.conf
UNIT=$ROOT/etc/systemd/system/$NAME.service
SYSCTL_FILE=$ROOT/etc/sysctl.d/99-$NAME.conf
MODLOAD_FILE=$ROOT/etc/modules-load.d/$NAME.conf
MODPROBE_FILE=$ROOT/etc/modprobe.d/$NAME.conf          # legacy (v2): removed once the optimizer owns conntrack
OPT_CT_FILE=$ROOT/etc/sysctl.d/99-vpn-network-optimizer-ct.conf   # written by vpn_network_optimizer
LOCK=${PF_LOCK:-/run/$NAME.lock}
CT_MIN_OK=262144                        # below this, warn that the optimizer has not been applied

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $0 IP PORT          add forward (tcp+udp): this server:PORT -> IP:PORT
  $0 add IP PORT      same as above
  $0 del IP PORT      remove a forward (also: del PORT)
  $0 list             list forwards
  $0 status           conntrack usage and flows per forwarded port
  $0 apply            re-apply saved rules
  $0 install          re-apply rules AND (re)install this script + systemd unit
                      (use after updating this file on an existing forwarder)
EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

lock() {
    exec 9>"$LOCK"
    flock 9
}

valid_ip() {
    case $1 in
        ''|*[!0-9.]*|.*|*.) return 1 ;;
    esac
    _oifs=$IFS
    IFS=.
    set -- $1
    IFS=$_oifs
    [ $# -eq 4 ] || return 1
    for _o in "$@"; do
        case $_o in
            ''|*[!0-9]*|0?*) return 1 ;;     # empty, non-digit, or leading zero (octal)
        esac
        [ "${#_o}" -le 3 ] && [ "$_o" -le 255 ] || return 1
    done
    case $1 in
        0|127) return 1 ;;                   # 0.x.x.x and 127.x.x.x are not valid targets
    esac
    return 0
}

valid_port() {
    case $1 in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}

ensure_deps() {
    if ! command -v iptables-restore >/dev/null 2>&1; then
        log "installing iptables..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables >/dev/null \
            || die "could not install iptables"
    fi
    for _c in iptables iptables-restore flock sysctl; do
        command -v "$_c" >/dev/null 2>&1 || die "required command not found: $_c"
    done
}

# Only called from "add" (never at boot: apt without network would stall startup).
ensure_conntrack_tool() {
    if ! command -v conntrack >/dev/null 2>&1; then
        log "installing conntrack tool (needed to cut live flows on del, and for status)..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq conntrack >/dev/null 2>&1 \
            || warn "could not install conntrack (optional)"
    fi
}

ensure_conf() {
    mkdir -p "$CONF_DIR"
    [ -f "$CONF" ] || : > "$CONF"
}

# ---- kernel settings: ip_forward (+ conntrack sanity check) ----------------
# conntrack tuning itself is owned by vpn_network_optimizer (single owner, no duplicate keys).
ensure_system() {
    _cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$_cur" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null || die "cannot set net.ipv4.ip_forward"
        log "net.ipv4.ip_forward: $_cur -> 1"
    else
        log "net.ipv4.ip_forward: already 1"
    fi

    modprobe nf_conntrack 2>/dev/null || true

    # Who owns the conntrack keys?
    _legacy=""
    if [ -f "$OPT_CT_FILE" ]; then
        # optimizer owns them: drop our legacy modprobe option and keys (migration from v2)
        rm -f "$MODPROBE_FILE"
    else
        # optimizer not applied yet: keep whatever older versions of this script persisted,
        # otherwise a reboot would silently revert conntrack to kernel defaults
        if [ -f "$SYSCTL_FILE" ]; then
            _legacy=$(grep '^net\.netfilter\.' "$SYSCTL_FILE" || true)
        fi
    fi

    # persist across reboots
    mkdir -p "$(dirname "$SYSCTL_FILE")" "$(dirname "$MODLOAD_FILE")"
    {
        echo "# managed by $NAME (ip_forward only; conntrack is managed by vpn_network_optimizer)"
        echo "net.ipv4.ip_forward = 1"
        if [ -n "$_legacy" ]; then echo "$_legacy"; fi
    } > "$SYSCTL_FILE"
    echo "nf_conntrack" > "$MODLOAD_FILE"

    # sanity check (warn only, never change conntrack here)
    _ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
    if [ "$_ctmax" -eq 0 ]; then
        warn "net.netfilter.nf_conntrack_max not available (container/VPS restriction?)"
    elif [ ! -f "$OPT_CT_FILE" ]; then
        warn "conntrack tuning not managed yet (nf_conntrack_max=$_ctmax). Run: vpn_network_optimizer_v2.1.sh --role forwarder"
    elif [ "$_ctmax" -lt "$CT_MIN_OK" ]; then
        warn "nf_conntrack_max=$_ctmax is low; re-run vpn_network_optimizer_v2.1.sh --role forwarder"
    fi
}

# ---- iptables rules ---------------------------------------------------------
# Rebuilds our chains atomically from the given conf file.
apply_rules() {
    _src=$1
    _tmp=$(mktemp)
    {
        echo "*nat"
        echo ":PF_PRE - [0:0]"
        echo ":PF_POST - [0:0]"
        echo "-F PF_PRE"
        echo "-F PF_POST"
        while read -r _aip _aport _arest; do
            [ -n "$_aip" ] || continue
            if ! valid_ip "$_aip" || ! valid_port "$_aport"; then
                warn "skipping invalid line: $_aip $_aport"
                continue
            fi
            for _ap in tcp udp; do
                echo "-A PF_PRE -p $_ap --dport $_aport -j DNAT --to-destination $_aip:$_aport"
                echo "-A PF_POST -d $_aip -p $_ap --dport $_aport -j MASQUERADE"
            done
        done < "$_src"
        echo "COMMIT"
        echo "*filter"
        echo ":PF_FWD - [0:0]"
        echo "-F PF_FWD"
        echo "-A PF_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        while read -r _aip _aport _arest; do
            [ -n "$_aip" ] || continue
            valid_ip "$_aip" && valid_port "$_aport" || continue
            for _ap in tcp udp; do
                echo "-A PF_FWD -d $_aip -p $_ap --dport $_aport -j ACCEPT"
            done
        done < "$_src"
        echo "COMMIT"
    } > "$_tmp"

    if ! iptables-restore -w 5 --noflush < "$_tmp" 2>/dev/null &&
       ! iptables-restore --noflush < "$_tmp"; then
        rm -f "$_tmp"
        warn "iptables-restore failed; nothing was changed"
        return 1
    fi
    rm -f "$_tmp"

    # make sure the built-in chains jump to ours (idempotent)
    iptables -w 5 -t nat -C PREROUTING  -j PF_PRE  2>/dev/null || iptables -w 5 -t nat -I PREROUTING  1 -j PF_PRE
    iptables -w 5 -t nat -C POSTROUTING -j PF_POST 2>/dev/null || iptables -w 5 -t nat -I POSTROUTING 1 -j PF_POST
    iptables -w 5       -C FORWARD     -j PF_FWD  2>/dev/null || iptables -w 5       -I FORWARD     1 -j PF_FWD

    apply_mangle "$_src" || true
}

# TCP MSS clamping on forwarded SYNs: avoids stalls on paths with a smaller MTU.
# Separate restore so a missing xt_TCPMSS module never breaks the forwarding itself.
apply_mangle() {
    [ "${MSS_CLAMP:-1}" = "1" ] || return 0
    _msrc=$1
    _have=0
    while read -r _mip _mport _mrest; do
        [ -n "$_mip" ] || continue
        if valid_ip "$_mip" && valid_port "$_mport"; then _have=1; break; fi
    done < "$_msrc"

    _mtmp=$(mktemp)
    {
        echo "*mangle"
        echo ":PF_MSS - [0:0]"
        echo "-F PF_MSS"
        if [ "$_have" -eq 1 ]; then
            echo "-A PF_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        fi
        echo "COMMIT"
    } > "$_mtmp"

    if iptables-restore -w 5 --noflush < "$_mtmp" 2>/dev/null ||
       iptables-restore --noflush < "$_mtmp" 2>/dev/null; then
        iptables -w 5 -t mangle -C FORWARD -j PF_MSS 2>/dev/null \
            || iptables -w 5 -t mangle -I FORWARD 1 -j PF_MSS \
            || warn "could not hook PF_MSS into mangle FORWARD"
    else
        warn "MSS clamp not applied (xt_TCPMSS unavailable?); forwarding still works"
    fi
    rm -f "$_mtmp"
}

# ---- install: copy script + systemd unit for boot persistence ---------------
install_self() {
    _self=$(readlink -f "$0" 2>/dev/null || echo "")
    [ -f "$_self" ] || die "run the script from a file (not via a pipe) so it can be installed"
    mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")"
    if [ "$_self" != "$BIN" ] && ! cmp -s "$_self" "$BIN" 2>/dev/null; then
        cp "$_self" "$BIN"
        chmod 0755 "$BIN"
        log "installed $BIN"
    fi

    _newunit=$(mktemp)
    cat > "$_newunit" <<EOF
[Unit]
Description=Port forwarding rules (iptables)
Wants=network-pre.target
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/$NAME apply

[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$_newunit" "$UNIT" 2>/dev/null; then
        cp "$_newunit" "$UNIT"
        chmod 0644 "$UNIT"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
            systemctl enable "$NAME.service" >/dev/null 2>&1 \
                && log "enabled $NAME.service (rules survive reboot)" \
                || warn "could not enable $NAME.service"
        fi
    fi
    rm -f "$_newunit"
}

# ---- commands ---------------------------------------------------------------
cmd_add() {
    [ $# -eq 2 ] || { usage; exit 1; }
    _ip=$1
    _port=$2
    valid_ip "$_ip"     || die "invalid IP: $_ip"
    valid_port "$_port" || die "invalid port: $_port (1-65535)"

    require_root
    lock
    ensure_deps
    ensure_conf
    ensure_conntrack_tool

    if grep -qxF "$_ip $_port" "$CONF"; then
        log "forward already exists: $_port -> $_ip:$_port (re-applying)"
        ensure_system
        apply_rules "$CONF"
        install_self
        return 0
    fi

    _other=$(awk -v p="$_port" '$2==p {print $1; exit}' "$CONF")
    [ -z "$_other" ] || die "port $_port already forwarded to $_other; remove it first: $0 del $_port"

    # a forward on a port this server listens on would hijack that service (e.g. SSH)
    if command -v ss >/dev/null 2>&1 &&
       ss -H -lntu 2>/dev/null | awk -v p=":$_port" \
           '{ n=$5; if (length(n) >= length(p) && substr(n, length(n)-length(p)+1) == p) f=1 } END { exit !f }'
    then
        die "port $_port is used by a local service on this server; forwarding it would break that service"
    fi

    ensure_system

    _new=$(mktemp -p "$CONF_DIR")
    cp "$CONF" "$_new"
    echo "$_ip $_port" >> "$_new"
    if ! apply_rules "$_new"; then
        rm -f "$_new"
        exit 1
    fi
    chmod 0644 "$_new"
    mv "$_new" "$CONF"
    install_self
    log "OK: $_port (tcp+udp) -> $_ip:$_port"
}

cmd_del() {
    [ $# -eq 1 ] || [ $# -eq 2 ] || { usage; exit 1; }
    if [ $# -eq 2 ]; then _ip=$1; _port=$2; else _ip=""; _port=$1; fi
    if [ -n "$_ip" ]; then valid_ip "$_ip" || die "invalid IP: $_ip"; fi
    valid_port "$_port" || die "invalid port: $_port"

    require_root
    lock
    ensure_deps
    ensure_conf

    awk -v i="$_ip" -v p="$_port" '$2==p && (i=="" || $1==i) {f=1} END{exit !f}' "$CONF" \
        || die "no such forward in $CONF"

    _new=$(mktemp -p "$CONF_DIR")
    awk -v i="$_ip" -v p="$_port" '!($2==p && (i=="" || $1==i))' "$CONF" > "$_new"
    if ! apply_rules "$_new"; then
        rm -f "$_new"
        exit 1
    fi
    chmod 0644 "$_new"
    mv "$_new" "$CONF"

    # Drop already-established flows, otherwise old connections keep working
    # (PF_FWD accepts ESTABLISHED and conntrack keeps the NAT mapping).
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -D -p tcp --orig-port-dst "$_port" >/dev/null 2>&1 || true
        conntrack -D -p udp --orig-port-dst "$_port" >/dev/null 2>&1 || true
        log "flushed live flows for port $_port"
    else
        warn "conntrack tool not installed: existing connections on port $_port stay alive until they end"
    fi
    log "removed forward for port $_port"
}

cmd_list() {
    if [ ! -s "$CONF" ]; then
        echo "no forwards configured"
        return 0
    fi
    echo "LOCAL PORT  ->  TARGET (tcp+udp)"
    while read -r _ip _port _rest; do
        [ -n "$_ip" ] || continue
        echo "$_port  ->  $_ip:$_port"
    done < "$CONF"
}

cmd_status() {
    require_root
    _cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    _max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    echo "ip_forward:  $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)"
    echo "conntrack:   $_cnt / $_max"
    if [ ! -s "$CONF" ]; then
        echo "no forwards configured"
        return 0
    fi
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "(install the 'conntrack' package for per-port flow counts)"
        return 0
    fi
    echo "PORT  ->  TARGET   flows"
    while read -r _ip _port _rest; do
        [ -n "$_ip" ] || continue
        _t=$(conntrack -L -p tcp --orig-port-dst "$_port" 2>/dev/null | wc -l)
        _u=$(conntrack -L -p udp --orig-port-dst "$_port" 2>/dev/null | wc -l)
        echo "$_port  ->  $_ip:$_port   tcp=$_t udp=$_u"
        if [ "$_t" -gt 50000 ]; then
            warn "port $_port is near the ~64k NAT flow ceiling for a single backend IP:port"
        fi
    done < "$CONF"
}

cmd_apply() {
    require_root
    lock
    ensure_deps
    ensure_conf
    if [ -s "$CONF" ]; then
        ensure_system
    fi
    apply_rules "$CONF"
    log "rules applied"
}

cmd_install() {
    cmd_apply
    install_self
}

case ${1:-} in
    add)                    shift; cmd_add "$@" ;;
    del|delete|remove|rm)   shift; cmd_del "$@" ;;
    list|ls)                cmd_list ;;
    status)                 cmd_status ;;
    apply)                  cmd_apply ;;
    install)                cmd_install ;;
    ''|-h|--help|help)      usage ;;
    *)                      cmd_add "$@" ;;
esac
