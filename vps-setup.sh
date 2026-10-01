#!/usr/bin/env bash
# node-setup.sh - minimal, non-interactive prep for fresh proxy-node servers
# Debian / Ubuntu only. Safe to re-run (idempotent).
#
# Does:
#   1. apt update + upgrade (no prompts) + a few base packages
#   2. BBR + fq (checked against the running kernel)
#   3. conservative sysctl tuning in /etc/sysctl.d/99-vpn-tuning.conf
#   4. higher default NOFILE limit for systemd services
#   5. time-sync check
#
# Does NOT touch: SSH config, GRUB, DNS, /etc/hosts, apt sources,
#                 /etc/sysctl.conf, /etc/security/limits.conf
#
# Usage: sudo bash node-setup.sh [--reboot]

set -uo pipefail

DO_REBOOT=0
LOG_FILE="/var/log/node-setup.log"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-tuning.conf"

usage() {
  cat <<'EOF'
Usage: sudo bash node-setup.sh [options]

  --reboot      reboot automatically when finished
  -h, --help    show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --reboot) DO_REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo)."; exit 1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
fail() { printf '[x] %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- checks
. /etc/os-release 2>/dev/null || fail "Cannot read /etc/os-release"
case "${ID:-}:${ID_LIKE:-}" in
  debian:*|ubuntu:*|*:*debian*|*:*ubuntu*) ;;
  *) fail "Only Debian/Ubuntu are supported (found: ${ID:-unknown})" ;;
esac

VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
case "$VIRT" in
  openvz|lxc|lxc-libvirt)
    warn "Virtualization '$VIRT': kernel settings are controlled by the host; some sysctl/BBR changes may not apply." ;;
esac

RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
log "Starting on ${PRETTY_NAME:-$ID} | kernel $(uname -r) | RAM ${RAM_MB}MB | virt: $VIRT"

# ---------------------------------------------------------------- 1. apt
log "apt update / upgrade"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT=(apt-get -y -o DPkg::Lock::Timeout=300
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

"${APT[@]}" update              || fail "apt update failed"
"${APT[@]}" upgrade             || fail "apt upgrade failed"
"${APT[@]}" install ca-certificates curl iproute2 || fail "base package install failed"
"${APT[@]}" autoremove          || warn "autoremove failed (ignored)"
"${APT[@]}" clean               || true

# ---------------------------------------------------------------- 2. BBR
log "Checking BBR support"
modprobe tcp_bbr 2>/dev/null || true
BBR_OK=0
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  BBR_OK=1
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  echo "BBR is available."
else
  warn "BBR is NOT available in this kernel. Skipping congestion-control change."
fi

# ---------------------------------------------------------------- 3. sysctl
log "Writing $SYSCTL_FILE"
{
  echo "# Managed by node-setup.sh - safe to delete; re-run script to recreate"
  echo
  if [ "$BBR_OK" -eq 1 ]; then
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
    echo
  fi
  cat <<'EOF'
# Connection queues
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_syncookies = 1

# Socket buffer ceilings (autotuned per socket; only the maximum is raised).
# tcp_mem / udp_mem are intentionally NOT set: the kernel sizes them from RAM.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216

# Long-lived proxy connections / lossy mobile clients
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Many outbound connections from the node
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_tw_buckets = 262144

# Detect dead peers sooner (default 7200s is far too long)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

fs.file-max = 2097152
EOF
} > "$SYSCTL_FILE"

if sysctl -p "$SYSCTL_FILE" >/tmp/node-setup-sysctl.out 2>&1; then
  echo "sysctl applied."
else
  warn "Some sysctl keys could not be applied (normal on OpenVZ/LXC):"
  grep -iE 'error|cannot|unknown|permission' /tmp/node-setup-sysctl.out || cat /tmp/node-setup-sysctl.out
fi
rm -f /tmp/node-setup-sysctl.out

# Apply fq to the live interface when it is safe (single-queue fq_codel/pfifo_fast).
# mq (multi-queue NICs) is left alone: its queues pick up fq after reboot.
if [ "$BBR_OK" -eq 1 ]; then
  IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ -n "${IFACE:-}" ]; then
    CUR_QDISC="$(tc qdisc show dev "$IFACE" root 2>/dev/null | awk 'NR==1{print $2}')"
    case "$CUR_QDISC" in
      fq_codel|pfifo_fast|pfifo)
        tc qdisc replace dev "$IFACE" root fq && echo "Interface $IFACE: qdisc $CUR_QDISC -> fq" ;;
      fq) echo "Interface $IFACE already uses fq." ;;
      *)  echo "Interface $IFACE uses '${CUR_QDISC:-unknown}'; fq will apply after reboot." ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 4. NOFILE
log "Setting default NOFILE limit for systemd services"
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/90-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1024:1048576
EOF
echo "Takes effect for services started after the next reboot."

# ---------------------------------------------------------------- 5. time
log "Time sync"
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
  timedatectl set-ntp true 2>/dev/null || true
  warn "Clock is not yet reported as synchronized. Check 'timedatectl' in a minute (some protocols break with clock drift)."
else
  echo "Clock is synchronized."
fi

# ---------------------------------------------------------------- summary
log "Summary"
echo "congestion control : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "default qdisc      : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "log file           : $LOG_FILE"

if [ -f /var/run/reboot-required ] || [ "$DO_REBOOT" -eq 1 ]; then
  echo
  echo "A reboot is recommended (kernel / systemd limits)."
fi

if [ "$DO_REBOOT" -eq 1 ]; then
  echo "Rebooting in 5 seconds..."
  sleep 5
  systemctl reboot
fi
