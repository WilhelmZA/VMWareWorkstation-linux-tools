#!/usr/bin/env bash
# setup_vmwareworkstation-module-builder.sh
# Interactive wizard that:
#   1. Generates and enrolls a MOK key pair for Secure Boot module signing
#   2. Installs a kernel post-install hook for automatic module rebuilds
#   3. Installs the main build script and config file
#   4. Optionally runs a build for the currently running kernel
#
# USAGE:
#   sudo ./setup_vmwareworkstation-module-builder.sh
# ---------------------------------------------------------------------------

set -e

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vmwareworkstation-module-builder.sh"
CONF_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vmwareworkstation-module-builder.conf"
SCRIPT_DEST="/usr/local/sbin/vmwareworkstation-module-builder.sh"
CONF_DEST="/etc/vmwareworkstation-module-builder.conf"
MOK_DIR="/etc/vmwareworkstation-module-builder"
POSTINST_HOOK="/etc/kernel/postinst.d/vmwareworkstation-module-builder"

MOK_KEY="$MOK_DIR/MOK.priv"
MOK_CERT="$MOK_DIR/MOK.crt"
MOK_DER="$MOK_DIR/MOK.der"

# ── Helpers ──────────────────────────────────────────────────────────────────

hr()  { printf '%0.s─' {1..60}; echo; }
hr2() { printf '%0.s═' {1..60}; echo; }

ask_yn() {
    local prompt="$1" default="${2:-Y}" choices
    [[ "${default^^}" == "Y" ]] && choices="[Y/n]" || choices="[y/N]"
    read -r -p "$prompt $choices " answer
    answer="${answer:-$default}"
    [[ "${answer^^}" == "Y" ]]
}

# ── Pre-flight checks ────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && echo "ERROR: Run as root (sudo)." && exit 1
[[ ! -f "$SCRIPT_SRC" ]] && echo "ERROR: vmwareworkstation-module-builder.sh not found at $SCRIPT_SRC" && exit 1

echo ""
hr2
echo "  VMware Workstation Module Builder — setup"
hr2
echo ""
echo "Checking prerequisites ..."
echo ""

PREFLIGHT_OK=1

check_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        printf "  %-16s OK\n" "$cmd"
    else
        printf "  %-16s MISSING — install: sudo apt install %s\n" "$cmd" "$pkg"
        PREFLIGHT_OK=0
    fi
}

check_cmd vmware vmware
check_cmd openssl openssl
check_cmd make build-essential
check_cmd gcc build-essential

if command -v mokutil &>/dev/null; then
    printf "  %-16s OK\n" "mokutil"
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    printf "  %-16s %s\n" "Secure Boot" "$SB_STATE"
else
    printf "  %-16s not found — Secure Boot status unknown\n" "mokutil"
fi

if [[ ! -f "/etc/vmware/networking" ]]; then
    printf "  %-16s MISSING — start VMware Workstation once to create it\n" "/etc/vmware/networking"
    PREFLIGHT_OK=0
else
    printf "  %-16s OK\n" "/etc/vmware/networking"
fi

if [[ ! -d "/usr/lib/vmware/modules/source" ]] || \
   ! ls /usr/lib/vmware/modules/source/*.tar &>/dev/null; then
    printf "  %-16s MISSING — VMware module sources not found\n" "module sources"
    PREFLIGHT_OK=0
else
    _tarcount=$(ls /usr/lib/vmware/modules/source/*.tar 2>/dev/null | wc -l)
    printf "  %-16s OK  (%d tarballs in /usr/lib/vmware/modules/source/)\n" "module sources" "$_tarcount"
fi

echo ""
if [[ $PREFLIGHT_OK -eq 0 ]]; then
    echo "ERROR: Prerequisites missing. Install them and re-run this script."
    exit 1
fi

# ── Section 1: MOK key pair ──────────────────────────────────────────────────

echo ""
hr
echo "  SECTION 1 — Secure Boot MOK signing key"
hr
echo ""
echo "  VMware kernel modules must be signed with an enrolled MOK key to load"
echo "  under Secure Boot. The private key is stored in $MOK_DIR"
echo "  with root-only access (600). No passphrase is used so that automated"
echo "  post-kernel-update builds can sign without user interaction."
echo ""

mkdir -p "$MOK_DIR"
chmod 700 "$MOK_DIR"
chown root:root "$MOK_DIR"

GENERATE_KEY=1

if [[ -f "$MOK_KEY" && -f "$MOK_CERT" ]]; then
    echo "  Existing key found at $MOK_DIR:"
    echo ""
    openssl x509 -in "$MOK_CERT" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
    echo ""

    if command -v mokutil &>/dev/null; then
        if mokutil --list-enrolled 2>/dev/null | grep -q "VMware Workstation Modules"; then
            echo "  Enrollment status: ENROLLED"
        else
            echo "  Enrollment status: NOT ENROLLED"
        fi
        echo ""
    fi

    if ask_yn "  Reuse existing key pair?" Y; then
        GENERATE_KEY=0
        echo "  Using existing key pair."
    else
        echo "  Generating new key pair (existing files will be replaced) ..."
    fi
fi

if [[ $GENERATE_KEY -eq 1 ]]; then
    echo ""
    echo "  Generating 2048-bit RSA key pair (valid 100 years) ..."
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$MOK_KEY" \
        -out    "$MOK_CERT" \
        -days   36500 \
        -nodes \
        -subj   "/CN=VMware Workstation Modules $(hostname)/" \
        2>/dev/null

    chmod 600 "$MOK_KEY"
    chmod 644 "$MOK_CERT"
    chown root:root "$MOK_KEY" "$MOK_CERT"

    openssl x509 -in "$MOK_CERT" -outform DER -out "$MOK_DER" 2>/dev/null
    chmod 644 "$MOK_DER"
    chown root:root "$MOK_DER"

    echo ""
    echo "  Key pair generated:"
    openssl x509 -in "$MOK_CERT" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
fi

# Check and handle enrollment
echo ""
ENROLLED=0
if command -v mokutil &>/dev/null; then
    if mokutil --list-enrolled 2>/dev/null | grep -q "VMware Workstation Modules"; then
        ENROLLED=1
        echo "  Certificate is already enrolled in the UEFI MOK database."
    fi
fi

if [[ $ENROLLED -eq 0 ]]; then
    echo "  The certificate has NOT been enrolled yet."
    echo ""
    [[ ! -f "$MOK_DER" ]] && \
        openssl x509 -in "$MOK_CERT" -outform DER -out "$MOK_DER" 2>/dev/null && \
        chmod 644 "$MOK_DER"

    if command -v mokutil &>/dev/null; then
        echo "  Running: mokutil --import $MOK_DER"
        echo "  You will be asked to set a one-time enrollment password."
        echo "  Remember it — you will need it on the next reboot."
        echo ""
        mokutil --import "$MOK_DER" || {
            echo ""
            echo "  WARNING: mokutil import failed. Enroll manually:"
            echo "    sudo mokutil --import $MOK_DER"
        }
    else
        echo "  mokutil is not installed. Enroll manually:"
        echo "    sudo apt install mokutil"
        echo "    sudo mokutil --import $MOK_DER"
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  IMPORTANT — complete enrollment before building        │"
    echo "  │                                                         │"
    echo "  │  1. Reboot the machine                                  │"
    echo "  │  2. At the UEFI / MOK Manager screen: Enroll MOK        │"
    echo "  │  3. Enter the password you just set                     │"
    echo "  │  4. Continue boot — the certificate is now enrolled     │"
    echo "  │                                                         │"
    echo "  │  Only then will signed modules load under Secure Boot.  │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
fi

# ── Section 2: kernel post-install hook ─────────────────────────────────────

echo ""
hr
echo "  SECTION 2 — kernel post-install hook"
hr
echo ""
echo "  A hook in /etc/kernel/postinst.d/ fires automatically when apt installs"
echo "  a new kernel package. It rebuilds and signs the VMware modules for the"
echo "  new kernel before you reboot — so they are ready immediately."
echo ""

cat > "$POSTINST_HOOK" << 'EOF'
#!/usr/bin/env bash
# /etc/kernel/postinst.d/vmwareworkstation-module-builder
# Rebuilds VMware Workstation kernel modules when a new kernel is installed.
# Receives the new kernel version as $1.
KVER="$1"
[[ -z "$KVER" ]] && exit 0
[[ ! -x "/usr/local/sbin/vmwareworkstation-module-builder.sh" ]] && exit 0
logger -t vmwareworkstation-module-builder "New kernel ${KVER} detected — rebuilding VMware modules"
/usr/local/sbin/vmwareworkstation-module-builder.sh --kernel "$KVER" --quiet
EOF
chmod +x "$POSTINST_HOOK"
echo "  Hook installed at: $POSTINST_HOOK"

# ── Section 3: install main script and config ────────────────────────────────

echo ""
hr
echo "  SECTION 3 — installing script and configuration"
hr
echo ""

echo "  Installing $SCRIPT_DEST ..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

if [[ -f "$CONF_DEST" ]]; then
    echo "  Config already exists at $CONF_DEST."
    if ask_yn "  Overwrite with fresh defaults?" N; then
        cp "$CONF_SRC" "$CONF_DEST"
        echo "  Config reset to defaults."
    else
        echo "  Keeping existing config."
    fi
else
    cp "$CONF_SRC" "$CONF_DEST"
    echo "  Config installed at $CONF_DEST."
fi

# ── Section 4: optional immediate build ─────────────────────────────────────

echo ""
hr
echo "  SECTION 4 — build for current kernel"
hr
echo ""

KVER_NOW="$(uname -r)"

if [[ $ENROLLED -eq 0 ]]; then
    echo "  Skipping build — MOK certificate is not yet enrolled."
    echo "  Complete the enrollment reboot first, then run:"
    echo "    sudo $SCRIPT_DEST"
else
    echo "  Current kernel: $KVER_NOW"
    echo ""
    if ask_yn "  Build and install modules for the running kernel now?" Y; then
        echo ""
        "$SCRIPT_DEST" --kernel "$KVER_NOW"
    else
        echo ""
        echo "  Skipped. Run manually when ready:"
        echo "    sudo $SCRIPT_DEST"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
hr2
echo "  Setup complete."
hr2
echo ""
echo "  MOK key pair    : $MOK_DIR/"
echo "  Module sources  : /usr/lib/vmware/modules/source/"
echo "  Post-install    : $POSTINST_HOOK"
echo "  Config          : $CONF_DEST"
echo "  Build script    : $SCRIPT_DEST"
echo ""
echo "  Future kernel updates will trigger an automatic rebuild."
echo ""
echo "  To rebuild manually for the running kernel:"
echo "    sudo $SCRIPT_DEST"
echo ""
