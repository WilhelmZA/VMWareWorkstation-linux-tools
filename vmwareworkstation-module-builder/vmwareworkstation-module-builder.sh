#!/usr/bin/env bash
# vmwareworkstation-module-builder.sh
# Extracts the vmmon and vmnet module sources that VMware Workstation ships,
# builds them against the target kernel's headers, optionally signs the
# resulting .ko files for Secure Boot, installs them, and restarts VMware.
#
# Run this after every kernel update, or let it run automatically via the
# kernel post-install hook installed by setup_vmwareworkstation-module-builder.sh.
#
# USAGE:
#   sudo ./vmwareworkstation-module-builder.sh [--kernel <kver>] [--quiet]
#
# FLAGS:
#   --kernel <kver>   Build for the specified kernel version instead of uname -r.
#                     Used by the kernel postinst.d hook.
#   --quiet           Suppress all log output.
#
# REQUIREMENTS:
#   - VMware Workstation installed (ships module sources in /usr/lib/vmware/modules/source/)
#   - build-essential (make, gcc)
#   - linux-headers for the target kernel
#   - For Secure Boot: an enrolled MOK key pair
# ---------------------------------------------------------------------------

# ── Argument parsing (before config so --kernel can override KVER) ──────────

_ARG_KVER=""
_ARG_QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel) _ARG_KVER="$2"; shift 2 ;;
        --quiet)  _ARG_QUIET=1;   shift   ;;
        *)        shift ;;
    esac
done

# ── Defaults ────────────────────────────────────────────────────────────────
# Override any of these in /etc/vmwareworkstation-module-builder.conf

# Directory where VMware Workstation installs its module source tarballs.
MODULES_TARBALLS="/usr/lib/vmware/modules/source"

# Secure Boot signing key and certificate.
# Both files must exist for signing to occur.
# Leave paths unset (or pointing at non-existent files) to skip signing —
# safe on machines where Secure Boot is disabled.
MOK_KEY="/etc/vmwareworkstation-module-builder/MOK.priv"
MOK_CERT="/etc/vmwareworkstation-module-builder/MOK.crt"

# Kernel version to build for. Overridden by --kernel flag.
KVER="$(uname -r)"

# Log file — set to "" to silence
LOG_FILE="/var/log/vmwareworkstation-module-builder.log"

# ── User config (overrides defaults above) ──────────────────────────────────
CONFIG_FILE="/etc/vmwareworkstation-module-builder.conf"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Apply CLI overrides ──────────────────────────────────────────────────────
[[ -n "$_ARG_KVER" ]]   && KVER="$_ARG_KVER"
[[ $_ARG_QUIET -eq 1 ]] && LOG_FILE=""

# ── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

# ── Pre-flight checks ────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && die "This script must be run as root (sudo)."

[[ ! -d "$MODULES_TARBALLS" ]] && \
    die "VMware module sources not found at $MODULES_TARBALLS — is VMware Workstation installed?"

shopt -s nullglob
_tars=( "$MODULES_TARBALLS"/*.tar )
shopt -u nullglob
[[ ${#_tars[@]} -eq 0 ]] && \
    die "No .tar files found in $MODULES_TARBALLS — VMware module sources missing."

[[ ! -d "/usr/src/linux-headers-${KVER}" ]] && \
    die "Kernel headers not found at /usr/src/linux-headers-${KVER}
       Install them first: sudo apt install linux-headers-${KVER}"

# Determine whether to sign
SIGN=0
if [[ -n "$MOK_KEY" && -n "$MOK_CERT" && -f "$MOK_KEY" && -f "$MOK_CERT" ]]; then
    SIGN=1
else
    log "WARNING: MOK key/cert not found — skipping module signing."
    log "         If Secure Boot is active, unsigned modules will be refused at load time."
    log "         Run setup_vmwareworkstation-module-builder.sh to generate and enroll a MOK key."
fi

SIGN_TOOL="/usr/src/linux-headers-${KVER}/scripts/sign-file"
if [[ $SIGN -eq 1 && ! -x "$SIGN_TOOL" ]]; then
    die "sign-file not found at $SIGN_TOOL — cannot sign modules."
fi

# ── Build ────────────────────────────────────────────────────────────────────

log "=== VMware module build: kernel ${KVER} ==="
log "Source tarballs : $MODULES_TARBALLS"
[[ $SIGN -eq 1 ]] && log "Secure Boot signing: enabled" || log "Secure Boot signing: disabled"

BUILD_DIR="$(mktemp -d -t "vmware-modules-${KVER}-XXXXXXXX")"
cleanup() { [[ -d "${BUILD_DIR:-}" ]] && rm -rf --one-file-system "$BUILD_DIR"; }
trap cleanup EXIT

log "Extracting module sources ..."
for tar_file in "${_tars[@]}"; do
    log "  $(basename "$tar_file")"
    tar -xf "$tar_file" -C "$BUILD_DIR"
done

for mod in vmmon vmnet; do
    build_dir="$BUILD_DIR/${mod}-only"
    [[ ! -d "$build_dir" ]] && die "${mod}-only not found after extraction — unexpected tarball layout."

    log "--- ${mod} ---"
    log "Building ${mod}.ko ..."
    if ! make -C "$build_dir" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
        die "Build failed for ${mod}."
    fi

    ko_path="$build_dir/${mod}.ko"
    [[ ! -f "$ko_path" ]] && die "${mod}.ko not produced — build may have failed silently."

    if [[ $SIGN -eq 1 ]]; then
        log "Signing ${mod}.ko ..."
        "$SIGN_TOOL" sha256 "$MOK_KEY" "$MOK_CERT" "$ko_path" || \
            die "Signing failed for ${mod}.ko"
    fi

    log "Installing ${mod}.ko to /lib/modules/${KVER}/misc/ ..."
    install -D -m 644 "$ko_path" "/lib/modules/${KVER}/misc/${mod}.ko"
done

# ── Finalise ─────────────────────────────────────────────────────────────────

log "Updating module dependencies ..."
depmod -a "$KVER"

if [[ "$KVER" == "$(uname -r)" ]]; then
    log "Reloading modules ..."
    modprobe -r vmnet vmmon 2>/dev/null || true
    modprobe vmmon || die "Failed to load vmmon — check dmesg for details."
    modprobe vmnet || die "Failed to load vmnet — check dmesg for details."

    log "Restarting VMware services ..."
    if systemctl restart vmware 2>/dev/null; then
        log "VMware services restarted."
    else
        log "WARNING: 'systemctl restart vmware' failed or service not found."
        log "         You may need to start VMware Workstation manually."
    fi
else
    log "Built for kernel ${KVER} (not running) — skipping module reload and service restart."
    log "Modules will be active after rebooting into ${KVER}."
fi

log "=== Build complete. Modules installed for kernel ${KVER}. ==="
