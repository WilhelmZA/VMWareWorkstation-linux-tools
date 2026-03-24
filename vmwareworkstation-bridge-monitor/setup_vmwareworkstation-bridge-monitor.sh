#!/usr/bin/env bash
# setup_vmwareworkstation-bridge-monitor.sh
# Installs two triggers for vmwareworkstation-bridge-monitor.sh:
#   1. NetworkManager dispatcher — fires immediately on interface up/DHCP events
#   2. Systemd timer fallback     — runs every 5 minutes for silent link drops
#
# USAGE:
#   sudo ./setup_vmwareworkstation-bridge-monitor.sh
# ---------------------------------------------------------------------------

set -e

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vmwareworkstation-bridge-monitor.sh"
CONF_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vmwareworkstation-bridge-monitor.conf"
SCRIPT_DEST="/usr/local/sbin/vmwareworkstation-bridge-monitor.sh"
CONF_DEST="/etc/vmwareworkstation-bridge-monitor.conf"
SERVICE_PATH="/etc/systemd/system/vmwareworkstation-bridge-monitor.service"
SERVICE_QUIET_PATH="/etc/systemd/system/vmwareworkstation-bridge-monitor-quiet.service"
TIMER_PATH="/etc/systemd/system/vmwareworkstation-bridge-monitor.timer"
NM_DISPATCHER="/etc/NetworkManager/dispatcher.d/99-vmwareworkstation-bridge-monitor"

[[ $EUID -ne 0 ]] && echo "ERROR: Run as root (sudo)." && exit 1
[[ ! -f "$SCRIPT_SRC" ]] && echo "ERROR: vmwareworkstation-bridge-monitor.sh not found at $SCRIPT_SRC" && exit 1

# ── VMware Workstation pre-flight check ─────────────────────────────────────
if ! command -v vmware-networks &>/dev/null; then
    echo "ERROR: vmware-networks not found — is VMware Workstation installed?"
    exit 1
fi
if [[ ! -f "/etc/vmware/networking" ]]; then
    echo "ERROR: /etc/vmware/networking not found."
    echo "       Start VMware Workstation at least once to initialise its network config."
    exit 1
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

# Print a horizontal rule
hr() { printf '%0.s─' {1..60}; echo; }

# Get the link state of an interface (UP / DOWN / UNKNOWN)
iface_state() {
    ip -br link show "$1" 2>/dev/null | awk '{print $2}'
}

# Classify an interface into: wired / wireless / virtual
iface_type() {
    local iface="$1"
    # Check the kernel uevent for DEVTYPE or SUBSYSTEM
    local devtype subsystem
    devtype=$(cat "/sys/class/net/$iface/uevent" 2>/dev/null | grep ^DEVTYPE= | cut -d= -f2)
    subsystem=$(readlink -f "/sys/class/net/$iface/device/subsystem" 2>/dev/null | xargs basename 2>/dev/null)

    if [[ "$devtype" == "wlan" || -d "/sys/class/net/$iface/wireless" ]]; then
        echo "wireless"
    elif [[ "$subsystem" == "usb" ]]; then
        echo "wired-usb"
    elif [[ "$subsystem" == "pci" || "$subsystem" == "platform" ]]; then
        echo "wired"
    else
        echo "virtual"
    fi
}

# ── Interactive adapter configuration ───────────────────────────────────────

configure_adapters() {
    echo ""
    hr
    echo "  VMware Workstation Bridge Monitor — adapter configuration"
    hr
    echo ""
    echo "Scanning network interfaces on this system ..."
    echo ""

    local wired=() wireless=() virtual=()

    for iface in $(ls /sys/class/net/ 2>/dev/null | sort); do
        local state type
        state=$(iface_state "$iface")
        type=$(iface_type "$iface")
        case "$type" in
            wired*)   wired+=("$iface|$state|$type") ;;
            wireless) wireless+=("$iface|$state") ;;
            *)        virtual+=("$iface|$state") ;;
        esac
    done

    # Print wired
    if [[ ${#wired[@]} -gt 0 ]]; then
        echo "  WIRED"
        for entry in "${wired[@]}"; do
            IFS='|' read -r iface state type <<< "$entry"
            local label=""
            [[ "$type" == "wired-usb" ]] && label="  (USB dongle)"
            printf "    %-24s %s%s\n" "$iface" "$state" "$label"
        done
        echo ""
    fi

    # Print wireless
    if [[ ${#wireless[@]} -gt 0 ]]; then
        echo "  WIRELESS"
        for entry in "${wireless[@]}"; do
            IFS='|' read -r iface state <<< "$entry"
            printf "    %-24s %s\n" "$iface" "$state"
        done
        echo ""
    fi

    # Print virtual/VPN
    if [[ ${#virtual[@]} -gt 0 ]]; then
        echo "  VIRTUAL / VPN  (these should generally be excluded)"
        for entry in "${virtual[@]}"; do
            IFS='|' read -r iface state <<< "$entry"
            printf "    %-24s %s\n" "$iface" "$state"
        done
        echo ""
    fi

    hr
    echo ""
    echo "PREFERRED ADAPTERS  (ordered, highest priority first)"
    echo ""
    echo "  VMware will bridge through the first adapter in this list that has"
    echo "  internet connectivity. Use wildcards to match whole families of"
    echo "  interfaces so the config survives renames and replug events:"
    echo ""
    echo "    enx*   matches any USB ethernet dongle  (enxAABBCCDDEEFF, …)"
    echo "    wlp*   matches any PCI Wi-Fi adapter    (wlp2s0, wlp3s0, …)"
    echo "    enp*   matches any PCI ethernet port    (enp2s0, enp0s31f6, …)"
    echo "    wlan*  matches older Wi-Fi naming       (wlan0, wlan1, …)"
    echo ""
    echo "  Enter one pattern per line. Press Enter on an empty line when done."
    echo "  Default: enx* then wlp*"
    echo ""

    local adapters=()
    local i=1
    while true; do
        read -r -p "    Pattern $i: " pat
        [[ -z "$pat" ]] && break
        adapters+=("$pat")
        (( i++ ))
    done

    if [[ ${#adapters[@]} -eq 0 ]]; then
        echo ""
        echo "  No patterns entered — keeping defaults (enx* wlp*)."
        adapters=("enx*" "wlp*")
    fi

    echo ""
    hr
    echo ""
    echo "EXCLUDED INTERFACES"
    echo ""
    echo "  These will never be selected as a bridge regardless of connectivity."
    echo "  VPN tunnels and virtual adapters must be excluded — routing through"
    echo "  them causes loops and breaks VM networking."
    echo ""
    echo "  Current virtual/VPN interfaces detected:"
    for entry in "${virtual[@]}"; do
        IFS='|' read -r iface state <<< "$entry"
        echo "    $iface"
    done
    echo ""
    echo "  Add any extra patterns to exclude (exact names or wildcards)."
    echo "  Press Enter on an empty line when done. The built-in defaults"
    echo "  (tailscale0, zcctun0, vmnet*, docker0, lo) are always excluded"
    echo "  by the script and do not need to be listed here."
    echo ""

    local extra_excluded=()
    local j=1
    while true; do
        read -r -p "    Extra exclude pattern $j (or Enter to finish): " pat
        [[ -z "$pat" ]] && break
        extra_excluded+=("$pat")
        (( j++ ))
    done

    # Build the combined excluded list: defaults + user additions
    local all_excluded=("tailscale0" "zcctun0" "vmnet0" "vmnet1" "vmnet8" "docker0" "lo")
    all_excluded+=("${extra_excluded[@]}")

    echo ""
    echo "Writing config to $CONF_DEST ..."

    # Build ADAPTERS array string
    local adapters_str=""
    for p in "${adapters[@]}"; do
        adapters_str+="    \"$p\"\n"
    done

    # Build EXCLUDED array string
    local excluded_str=""
    for p in "${all_excluded[@]}"; do
        excluded_str+="    \"$p\"\n"
    done

    cat > "$CONF_DEST" << EOF
# vmwareworkstation-bridge-monitor.conf
# Generated by setup_vmwareworkstation-bridge-monitor.sh
# Edit this file to change adapter preferences without re-running setup.
# ---------------------------------------------------------------------------

# Ordered list of adapter patterns to try, highest priority first.
# Supports exact names or globs (e.g. "enx*" matches all USB ethernet dongles).
ADAPTERS=(
$(printf "%b" "$adapters_str"))

# Interfaces that must never be selected as a bridge.
EXCLUDED=(
$(printf "%b" "$excluded_str"))
EOF

    echo ""
    echo "Config written. To change adapter preferences later, edit $CONF_DEST"
    echo "directly — no need to re-run this installer."
    echo ""
}

# ── Run adapter configuration ────────────────────────────────────────────────

if [[ -f "$CONF_DEST" ]]; then
    echo ""
    echo "A config file already exists at $CONF_DEST."
    read -r -p "Reconfigure adapter preferences now? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        configure_adapters
    else
        echo "Keeping existing config."
    fi
else
    configure_adapters
fi

# ── Install main script to system path ─────────────────────────────────────
echo "Installing $SCRIPT_DEST ..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

# ── NetworkManager dispatcher ───────────────────────────────────────────────
# Fires on: interface up, DHCP lease obtained, connectivity change.
# NM passes two args: $1 = interface name, $2 = event type.
echo "Installing NetworkManager dispatcher at $NM_DISPATCHER ..."
cat > "$NM_DISPATCHER" << 'EOF'
#!/usr/bin/env bash
# NetworkManager dispatcher: trigger VMware bridge monitor on relevant network events.
IFACE="$1"
EVENT="$2"

case "$EVENT" in
    up|dhcp4-change|dhcp6-change|connectivity-change)
        logger -t vmwareworkstation-bridge-monitor "NM event: $EVENT on $IFACE — triggering bridge check"
        /usr/local/sbin/vmwareworkstation-bridge-monitor.sh
        ;;
esac
EOF
chmod +x "$NM_DISPATCHER"

# ── Systemd service (used by NM dispatcher, logs enabled) ──────────────────
echo "Writing $SERVICE_PATH ..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=VMware Workstation bridge monitor
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DEST
EOF

# ── Systemd service for timer (quiet — no log output) ──────────────────────
echo "Writing $SERVICE_QUIET_PATH ..."
cat > "$SERVICE_QUIET_PATH" << EOF
[Unit]
Description=VMware Workstation bridge monitor (quiet timer run)
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DEST --quiet
EOF

# ── Systemd timer fallback (every 5 minutes, uses quiet service) ───────────
echo "Writing $TIMER_PATH ..."
cat > "$TIMER_PATH" << EOF
[Unit]
Description=Periodic fallback check for VMware Workstation bridge adapter (every 5 min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=10sec
Unit=vmwareworkstation-bridge-monitor-quiet.service

[Install]
WantedBy=timers.target
EOF

# ── Enable everything ───────────────────────────────────────────────────────
echo "Enabling and starting timer ..."
systemctl daemon-reload
systemctl enable --now vmwareworkstation-bridge-monitor.timer

# ── Find the currently active bridge candidate for the test hint ────────────
# Source the installed config to get ADAPTERS/EXCLUDED, then find the first
# UP interface that matches — this gives a realistic example in the hint.
_hint_iface=""
if [[ -f "$CONF_DEST" ]]; then
    # Load arrays from config into a subshell to avoid polluting this scope
    _hint_iface=$(
        # shellcheck source=/dev/null
        source "$CONF_DEST" 2>/dev/null
        for pattern in "${ADAPTERS[@]}"; do
            for iface in $(ls /sys/class/net/ 2>/dev/null); do
                # shellcheck disable=SC2254
                case "$iface" in
                    $pattern)
                        excluded=0
                        for ex in "${EXCLUDED[@]}"; do
                            # shellcheck disable=SC2254
                            case "$iface" in
                                $ex) excluded=1; break ;;
                            esac
                        done
                        [[ $excluded -eq 1 ]] && continue
                        ip link show "$iface" 2>/dev/null \
                            | grep -qE "state (UP|UNKNOWN)" || continue
                        echo "$iface"
                        exit 0
                        ;;
                esac
            done
        done
    )
fi
_hint_iface="${_hint_iface:-<interface>}"

echo ""
echo "Setup complete."
echo ""
echo "Timer status:"
systemctl status vmwareworkstation-bridge-monitor.timer --no-pager
echo ""
echo "NM dispatcher installed at: $NM_DISPATCHER"
echo "To test dispatcher manually: sudo $NM_DISPATCHER $_hint_iface up"
