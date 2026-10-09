#!/usr/bin/env bash
#
# pve-vm-provision.sh - provision a Debian/Ubuntu VM from the Proxmox host via
# the QEMU guest agent. It bundles the steps used to fix a pve-microvm guest:
#
#   1) ensure udev / systemd-udevd is installed & running (systemd-networkd
#      refuses to configure a link until udevd marks it "initialized")
#   2) enable root SSH login (PermitRootLogin yes + password and/or key)
#   3) inject the net-config helper and repair microvm-static-net.service
#   4) optionally apply a static IP
#
# Usage (run on the Proxmox host, as root):
#   ./pve-vm-provision.sh <vmid> [options]
#
# Options:
#   --root-password PW|auto|keep  root password (default: auto = generate one;
#                                 'keep' = don't change it, only enable login)
#   --root-pubkey FILE            add this public key to root authorized_keys
#   --net-config PATH             path to net-config script
#                                 (default: alongside this script, then /root)
#   --static-ip IP/PREFIX         apply a static IPv4 address
#   --gateway IP                  static gateway (with --static-ip)
#   --dns IP                      static DNS     (with --static-ip)
#   --no-udev                     skip the udev step
#   --no-ssh                      skip the root SSH step
#   --no-netconfig                do not inject/repair net-config
#   --reboot                      reboot the guest when finished
#   -h, --help                    show this help
#
set -euo pipefail

VMID=""; ROOT_PASSWORD="auto"; ROOT_PUBKEY_FILE=""; NETCONFIG_FILE=""
STATIC_CIDR=""; STATIC_GW=""; STATIC_DNS=""
DO_UDEV=1; DO_SSH=1; DO_NETCONFIG=1; DO_REBOOT=0

usage() {
    printf 'Usage: %s <vmid> [options]\n\n' "$0"
    sed -n '3,28p' "$0" | sed -E 's/^# ?//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root-password) ROOT_PASSWORD="${2:-}"; shift 2 ;;
        --root-pubkey)   ROOT_PUBKEY_FILE="${2:-}"; shift 2 ;;
        --net-config)    NETCONFIG_FILE="${2:-}"; shift 2 ;;
        --static-ip)     STATIC_CIDR="${2:-}"; shift 2 ;;
        --gateway)       STATIC_GW="${2:-}"; shift 2 ;;
        --dns)           STATIC_DNS="${2:-}"; shift 2 ;;
        --no-udev)       DO_UDEV=0; shift ;;
        --no-ssh)        DO_SSH=0; shift ;;
        --no-netconfig)  DO_NETCONFIG=0; shift ;;
        --reboot)        DO_REBOOT=1; shift ;;
        -h|--help)       usage 0 ;;
        -*)              echo "Unknown option: $1" >&2; usage 1 ;;
        *)               if [ -z "$VMID" ]; then VMID="$1"; else echo "Unexpected argument: $1" >&2; usage 1; fi; shift ;;
    esac
done

[ -n "$VMID" ] || usage 1
command -v qm >/dev/null 2>&1 || { echo "qm not found - run this on a Proxmox host." >&2; exit 1; }

# ---- resolve options ---------------------------------------------------------
GEN_PW=0
case "$ROOT_PASSWORD" in
    auto) ROOT_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20); GEN_PW=1 ;;
    keep|"") ROOT_PASSWORD="" ;;
esac

ROOT_PUBKEY=""
if [ -n "$ROOT_PUBKEY_FILE" ]; then
    [ -f "$ROOT_PUBKEY_FILE" ] || { echo "pubkey file not found: $ROOT_PUBKEY_FILE" >&2; exit 1; }
    ROOT_PUBKEY=$(head -n1 "$ROOT_PUBKEY_FILE")
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -z "$NETCONFIG_FILE" ]; then
    for c in "$SCRIPT_DIR/net-config" /root/net-config; do
        [ -f "$c" ] && { NETCONFIG_FILE="$c"; break; }
    done
fi
if [ "$DO_NETCONFIG" = 1 ] && { [ -z "$NETCONFIG_FILE" ] || [ ! -f "$NETCONFIG_FILE" ]; }; then
    echo "warning: net-config not found; skipping (use --net-config or --no-netconfig)" >&2
    DO_NETCONFIG=0
fi

# ---- preflight ---------------------------------------------------------------
qm status "$VMID" >/dev/null 2>&1 || { echo "VM $VMID not found" >&2; exit 1; }
if [ "$(qm status "$VMID" 2>/dev/null | awk '{print $2}')" != "running" ]; then
    echo "VM $VMID is not running." >&2; exit 1
fi
if ! qm agent "$VMID" ping >/dev/null 2>&1; then
    echo "QEMU guest agent not responding in VM $VMID (is qemu-guest-agent installed/running?)" >&2
    exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---- guest payload -----------------------------------------------------------
cat > "$TMP/guest.sh" <<'MVM_GUEST_EOF'
#!/bin/bash
# pve-vm-provision guest payload. Config is read literally from /tmp/mvm.conf.
set -u
CONF=/tmp/mvm.conf
get() { [ -f "$CONF" ] && grep -m1 "^$1=" "$CONF" | cut -d= -f2- || true; }
log() { echo "[mvm] $*"; }

INSTALL_UDEV=$(get INSTALL_UDEV)
SETUP_SSH=$(get SETUP_SSH)
ROOT_PASSWORD=$(get ROOT_PASSWORD)
ROOT_PUBKEY=$(get ROOT_PUBKEY)
INSTALL_NETCONFIG=$(get INSTALL_NETCONFIG)
APPLY_STATIC=$(get APPLY_STATIC)
STATIC_CIDR=$(get STATIC_CIDR)
STATIC_GW=$(get STATIC_GW)
STATIC_DNS=$(get STATIC_DNS)

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }

detect_iface() {
    local i
    for i in /sys/class/net/*; do
        i=$(basename "$i"); [ "$i" = lo ] && continue
        [ -e "/sys/class/net/$i/device" ] && { echo "$i"; return; }
    done
    ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1
}
IFACE=$(detect_iface)
have_ip() { [ -n "$IFACE" ] && ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; }
ensure_net() {
    have_ip && return 0
    [ -n "$IFACE" ] || return 1
    ip link set "$IFACE" up 2>/dev/null || true
    if command -v dhclient >/dev/null 2>&1; then dhclient "$IFACE" >/dev/null 2>&1 || true
    elif command -v udhcpc >/dev/null 2>&1; then udhcpc -i "$IFACE" -q -n >/dev/null 2>&1 || true
    fi
    sleep 3; have_ip
}

# 1) udev ---------------------------------------------------------------------
if [ "$INSTALL_UDEV" = 1 ]; then
    if [ ! -x /usr/lib/systemd/systemd-udevd ] || ! command -v udevadm >/dev/null 2>&1; then
        log "installing udev..."
        ensure_net || log "warning: no guest connectivity; apt may fail"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq udev || log "warning: udev install failed"
    else
        log "udev already present"
    fi
    systemctl enable systemd-udevd.service >/dev/null 2>&1 || true
    systemctl start  systemd-udevd.service >/dev/null 2>&1 || true
    if command -v udevadm >/dev/null 2>&1; then udevadm trigger >/dev/null 2>&1 || true; sleep 2; fi
fi

# 2) root SSH -----------------------------------------------------------------
if [ "$SETUP_SSH" = 1 ]; then
    log "configuring root SSH login..."
    install -d -m 755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
    if [ -n "$ROOT_PASSWORD" ]; then
        echo "root:$ROOT_PASSWORD" | chpasswd
        passwd -u root >/dev/null 2>&1 || true
    fi
    if [ -n "$ROOT_PUBKEY" ]; then
        install -d -m 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        grep -qxF "$ROOT_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$ROOT_PUBKEY" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    fi
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        else
            log "warning: sshd config test failed"
        fi
    fi
fi

# 3) net-config + boot service repair -----------------------------------------
if [ "$INSTALL_NETCONFIG" = 1 ]; then
    if [ -s /tmp/net-config ]; then
        install -m 755 /tmp/net-config /usr/local/bin/net-config
        log "installed /usr/local/bin/net-config"
    fi
    SVC=/etc/systemd/system/microvm-static-net.service
    if [ -f "$SVC" ]; then
        cat > "$SVC" <<'EOF'
[Unit]
Description=Apply static network config if present
Before=systemd-networkd.service
ConditionPathExists=/etc/microvm-static-net

[Service]
Type=oneshot
ExecStart=/bin/sh -c '. /etc/microvm-static-net && mkdir -p /etc/systemd/network && { echo "[Match]"; echo "Type=ether"; echo; echo "[Network]"; echo "DHCP=no"; echo "Address=$ADDRESS"; echo "Gateway=$GATEWAY"; echo "DNS=${DNS:-1.1.1.1}"; } > /etc/systemd/network/10-static.network && rm -f /etc/systemd/network/20-microvm-dhcp.network'

[Install]
WantedBy=sysinit.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        log "repaired microvm-static-net.service"
    fi
fi

# 4) optional static IP -------------------------------------------------------
if [ "$APPLY_STATIC" = 1 ] && [ -n "$STATIC_CIDR" ] && [ -x /usr/local/bin/net-config ]; then
    log "applying static $STATIC_CIDR gw $STATIC_GW dns $STATIC_DNS"
    IP=${STATIC_CIDR%/*}; PFX=${STATIC_CIDR#*/}
    printf '2\n%s\n%s\n%s\n%s\ny\nq\n' "$IP" "$PFX" "$STATIC_GW" "$STATIC_DNS" > /tmp/nc-ans
    bash /usr/local/bin/net-config < /tmp/nc-ans || log "warning: net-config returned non-zero"
    rm -f /tmp/nc-ans
fi

# summary ---------------------------------------------------------------------
log "----- summary -----"
log "interface : ${IFACE:-none}"
ip -4 -br addr 2>/dev/null || true
log "root login: $(/usr/sbin/sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
log "udevd     : $(systemctl is-active systemd-udevd.service 2>/dev/null)"
log "done."
MVM_GUEST_EOF

# ---- config file passed to the guest -----------------------------------------
cat > "$TMP/mvm.conf" <<CONF_EOF
INSTALL_UDEV=$DO_UDEV
SETUP_SSH=$DO_SSH
ROOT_PASSWORD=$ROOT_PASSWORD
ROOT_PUBKEY=$ROOT_PUBKEY
INSTALL_NETCONFIG=$DO_NETCONFIG
APPLY_STATIC=$([ -n "$STATIC_CIDR" ] && echo 1 || echo 0)
STATIC_CIDR=$STATIC_CIDR
STATIC_GW=$STATIC_GW
STATIC_DNS=$STATIC_DNS
CONF_EOF

B_GUEST=$(base64 -w0 < "$TMP/guest.sh")
B_CONF=$(base64 -w0 < "$TMP/mvm.conf")
B_NC=""
[ "$DO_NETCONFIG" = 1 ] && B_NC=$(base64 -w0 < "$NETCONFIG_FILE")

GUEST_CMD="echo $B_GUEST | base64 -d > /tmp/mvm-setup.sh
echo $B_CONF | base64 -d > /tmp/mvm.conf"
if [ "$DO_NETCONFIG" = 1 ]; then
    GUEST_CMD+=$'\n'"echo $B_NC | base64 -d > /tmp/net-config"
fi
GUEST_CMD+=$'\n'"chmod +x /tmp/mvm-setup.sh
exec /bin/bash /tmp/mvm-setup.sh"

# ---- run inside the guest, handling the async/timeout case -------------------
run_guest() {
    local json pid st
    json=$(qm guest exec "$VMID" --timeout 1800 -- /bin/sh -c "$1" 2>/dev/null || true)
    if printf '%s' "$json" | grep -q '"pid"'; then
        pid=$(printf '%s' "$json" | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{"pid"}' 2>/dev/null || true)
        if [ -n "$pid" ]; then
            while :; do
                st=$(qm guest exec-status "$VMID" "$pid" 2>/dev/null || true)
                printf '%s' "$st" | grep -q '"exited"' && { json="$st"; break; }
                sleep 2
            done
        fi
    fi
    printf '%s' "$json" | perl -MJSON::PP -0777 -ne '
        my $d = eval { decode_json($_) } or do { print; exit 0 };
        print $d->{"out-data"} // "";
        print STDERR $d->{"err-data"} // "";
        exit($d->{"exitcode"} // 0);'
}

echo ">>> provisioning VM $VMID ..."
if run_guest "$GUEST_CMD"; then
    echo ">>> provisioning finished OK"
else
    echo ">>> guest command returned non-zero (see above)" >&2
fi

if [ "$DO_REBOOT" = 1 ]; then
    echo ">>> rebooting VM $VMID"
    qm reboot "$VMID"
fi

if [ "$GEN_PW" = 1 ]; then
    echo
    echo "Generated root password for VM $VMID: $ROOT_PASSWORD"
    echo "(change it after first login with: passwd)"
fi
