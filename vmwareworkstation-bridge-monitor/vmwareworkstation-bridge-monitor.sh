#!/usr/bin/env bash
# vmwareworkstation-bridge-monitor.sh
# Checks a prioritized list of network adapters for internet connectivity,
# then switches VMware Workstation's bridged network (vmnet0) to the first
# working adapter.
#
# USAGE:
#   sudo ./vmwareworkstation-bridge-monitor.sh
#   Run automatically via systemd timer (see setup_vmwareworkstation-bridge-monitor.sh)
#
# REQUIREMENTS:
#   - VMware Workstation on Linux (uses vmware-networks and /etc/vmware/)
#   - Run as root (vmware-networks requires it)
# ---------------------------------------------------------------------------

# ── Defaults ───────────────────────────────────────────────────────────────
# These can all be overridden in /etc/vmwareworkstation-bridge-monitor.conf.

# Ordered list of adapters to try, highest priority first.
# Supports exact names OR glob patterns (e.g. "enx*" matches any USB ethernet).
# Globs are resolved at runtime so renaming after replug is handled automatically.
ADAPTERS=(
    "enx*"       # USB Ethernet dongle(s) — e.g. enx98e743095993. Highest priority.
    "wlp*"       # Wi-Fi — e.g. wlp192s0. Fallback if USB dongle is unplugged.
)

# Interfaces that should NEVER be selected as a bridge, even if they pass
# the connectivity test. Tailscale and Zscaler VPN tunnels must be excluded —
# bridging through them causes routing loops and broken VM networking.
EXCLUDED=(
    "tailscale0"
    "zcctun0"
    "vmnet0"
    "vmnet1"
    "vmnet8"
    "docker0"
    "lo"
)

# Host/IP used for the connectivity test.
# Plain IP — no DNS lookup needed, not intercepted by Zscaler's DNS proxy.
PING_HOST="1.1.1.1"
PING_COUNT=2
PING_TIMEOUT=2   # seconds per ping attempt

# Fallback curl test if ICMP ping is blocked by Zscaler.
# 204 = "No Content" — lightweight, no data sent back.
CURL_TEST_URL="https://connectivitycheck.gstatic.com/generate_204"
CURL_TIMEOUT=4

# VMware bridged network device index to manage (0 = vmnet0 = "Bridged/Auto")
VMNET_INDEX=0

# VMware network config file (bridge mappings live here, not in netmap.conf)
VMWARE_NETWORKING="/etc/vmware/networking"

# Log file — set to "" or /dev/null to silence
LOG_FILE="/var/log/vmwareworkstation-bridge-monitor.log"

# Lock file — prevents concurrent runs during vmware-networks restart
LOCK_FILE="/var/run/vmwareworkstation-bridge-monitor.lock"

# ── User config (overrides defaults above) ─────────────────────────────────
CONFIG_FILE="/etc/vmwareworkstation-bridge-monitor.conf"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Helpers ────────────────────────────────────────────────────────────────

notify_user() {
    local msg="$1"
    local icon="${2:-network-wired}"
    local user uid dbus
    user=$(who | awk 'NR==1{print $1}')
    uid=$(id -u "$user" 2>/dev/null) || return
    dbus="/run/user/$uid/bus"
    [[ -S "$dbus" ]] || return
    sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=$dbus" \
        notify-send -t 5000 -i "$icon" "VMware Bridge" "$msg" 2>/dev/null || true
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    return 0
}

log_action() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
    return 0
}

die() {
    log "ERROR: $*"
    exit 1
}

# Expand a pattern (exact name or glob like "enx*") to actual UP interfaces.
# Prints one interface name per line; nothing if none match.
resolve_pattern() {
    local pattern="$1"
    for iface in $(ls /sys/class/net/); do
        # shellcheck disable=SC2254
        case "$iface" in
            $pattern)
                # Skip excluded interfaces (patterns supported)
                local excluded=0
                for ex in "${EXCLUDED[@]}"; do
                    # shellcheck disable=SC2254
                    case "$iface" in
                        $ex) excluded=1; break ;;
                    esac
                done
                [[ $excluded -eq 1 ]] && continue

                # Skip if not UP (also accepts UNKNOWN — some USB adapters report this)
                ip link show "$iface" 2>/dev/null | grep -qE "state (UP|UNKNOWN)" || continue

                echo "$iface"
                ;;
        esac
    done
}

# Test internet reachability through a specific interface
has_internet() {
    local iface="$1"

    # Try ICMP ping bound to this interface
    if ping -I "$iface" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_HOST" &>/dev/null; then
        return 0
    fi

    # Fallback: curl bound to the interface's own IP.
    # Works even when Zscaler intercepts ICMP.
    if [[ -n "$CURL_TEST_URL" ]]; then
        local iface_ip
        iface_ip=$(ip -4 addr show "$iface" 2>/dev/null \
                   | awk '/inet /{print $2}' \
                   | cut -d/ -f1 \
                   | grep -v '^169\.254\.' \
                   | head -1)
        if [[ -n "$iface_ip" ]]; then
            local http_code
            http_code=$(curl -s \
                --interface "$iface" \
                --max-time "$CURL_TIMEOUT" \
                -o /dev/null \
                -w "%{http_code}" \
                "$CURL_TEST_URL" 2>/dev/null)
            [[ "$http_code" == "204" ]] && return 0
        fi
    fi

    return 1
}

# Read which physical adapter is currently bridged to vmnet$VMNET_INDEX.
# Format in /etc/vmware/networking: "add_bridge_mapping <iface> <index>"
get_current_bridge() {
    awk -v idx="$VMNET_INDEX" \
        '$1 == "add_bridge_mapping" && $3 == idx { print $2 }' \
        "$VMWARE_NETWORKING" 2>/dev/null
}

# Write the new adapter into /etc/vmware/networking and restart VMware networking.
# Replaces any existing add_bridge_mapping line for this vmnet index,
# or appends one if none exists.
set_bridge() {
    local new_iface="$1"

    cp "$VMWARE_NETWORKING" "${VMWARE_NETWORKING}.bak" 2>/dev/null

    if grep -qE "^add_bridge_mapping .+ ${VMNET_INDEX}$" "$VMWARE_NETWORKING" 2>/dev/null; then
        sed -i \
            "s|^add_bridge_mapping .* ${VMNET_INDEX}$|add_bridge_mapping ${new_iface} ${VMNET_INDEX}|" \
            "$VMWARE_NETWORKING"
    else
        echo "add_bridge_mapping ${new_iface} ${VMNET_INDEX}" >> "$VMWARE_NETWORKING"
    fi

    log_action "Restarting VMware networking ..."
    if (exec 9>&-; vmware-networks --stop &>/dev/null && vmware-networks --start &>/dev/null); then
        log_action "VMware networking restarted successfully."
    else
        log_action "WARNING: vmware-networks restart had issues."
        log_action "  Try manually: sudo vmware-networks --stop && sudo vmware-networks --start"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    # --quiet suppresses all logging (used by timer runs to avoid noise)
    [[ "${1:-}" == "--quiet" ]] && LOG_FILE=""

    [[ $EUID -ne 0 ]] && die "This script must be run as root (sudo)."
    [[ ! -f "$VMWARE_NETWORKING" ]] && die "VMware networking config not found at $VMWARE_NETWORKING"

    # Prevent concurrent runs
    exec 9>"$LOCK_FILE"
    flock -n 9 || { log "Another instance is running. Exiting."; exit 0; }

    log "=== VMware bridge adapter check ==="

    local current_bridge
    current_bridge=$(get_current_bridge)
    log "Current bridge: ${current_bridge:-<unset>}"

    local chosen=""

    for pattern in "${ADAPTERS[@]}"; do
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            log "Checking $iface (matched '$pattern') ..."

            if has_internet "$iface"; then
                log "  → $iface has internet connectivity."
                chosen="$iface"
                break 2
            else
                log "  → $iface is up but no internet detected."
            fi
        done < <(resolve_pattern "$pattern")
    done

    if [[ -z "$chosen" ]]; then
        log "No working adapter found. Bridge unchanged."
        log "Tip: run 'ip link show' and verify interface names match ADAPTERS patterns."
        exit 1
    fi

    if [[ "$chosen" == "$current_bridge" ]]; then
        log "Already bridged to $chosen — no change needed."
        exit 0
    fi

    log_action "Switching bridge: '${current_bridge:-<unset>}' → '$chosen'"
    set_bridge "$chosen"
    log_action "Done. vmnet0 is now bridged to: $chosen"
    notify_user "Bridge switched: ${current_bridge:-unset} → $chosen"
}

main "$@"
