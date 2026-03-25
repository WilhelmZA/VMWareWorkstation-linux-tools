# VMware Workstation Linux Tools

A collection of small utilities that fix persistent operational problems with VMware Workstation on Linux.

---

## autobridger — automatic bridge adapter selection

### The problem

VMware Workstation's auto-bridge mode (`vmnet0`) scans all network interfaces and picks one to bridge VMs to the host network. On a Linux machine with VPN clients, virtual adapters, and multiple physical interfaces, it frequently picks the wrong one:

- loopback (`lo`)
- Docker bridge (`docker0`)
- Tailscale VPN tunnel (`tailscale0`)
- ZScaler VPN tunnel (`zcctun0`)
- A `vmnet` interface itself

Any of these choices takes the VMs offline silently. The same problem recurs after every network change — plugging in a USB ethernet dongle, switching to Wi-Fi, DHCP renewal, or VPN reconnect.

### The solution

autobridger monitors for network changes and automatically selects the correct physical interface to bridge. It:

- scans a prioritised list of adapter patterns
- prefers wired ethernet over Wi-Fi
- tests each candidate for actual internet connectivity before selecting it
- ignores VPN tunnels, virtual adapters, and loopback unconditionally
- rewrites `/etc/vmware/networking` and restarts VMware networking only when the selection changes
- sends a desktop notification when it makes a switch

### How it works

The repository contains two scripts:

#### `vmwareworkstation-bridge-monitor.sh`

The main remediation script. It works through an ordered list of adapter patterns, highest priority first:

| Priority | Pattern | Example match | Reason |
|----------|---------|---------------|--------|
| 1 | `enx*` | `enx98e743095993` | USB ethernet dongle — most reliable link |
| 2 | `wlp*` | `wlp192s0` | Built-in Wi-Fi — fallback when dongle is unplugged |

For each candidate it:

1. checks the interface is UP (or UNKNOWN — some USB adapters report this while connected)
2. pings `8.8.8.8` via that interface
3. falls back to a curl check against `https://connectivitycheck.gstatic.com/generate_204` if ICMP is blocked by ZScaler

The first interface that passes the connectivity test becomes the bridge. If the chosen interface already matches the current bridge, the script exits without touching anything.

The following interfaces are unconditionally excluded, regardless of their state:

| Interface | Reason |
|-----------|--------|
| `tailscale0` | Tailscale VPN — bridging through it causes routing loops |
| `zcctun0` | ZScaler VPN — same issue |
| `vmnet0/1/8` | VMware virtual adapters — would create a loop |
| `docker0` | Docker bridge — wrong network entirely |
| `lo` | Loopback — never a valid bridge |

The script uses a lock file to prevent concurrent runs during the VMware networking restart.

#### `setup_vmwareworkstation-bridge-monitor.sh`

The installer. It configures two independent triggers so corrections happen both quickly and reliably:

- a **NetworkManager dispatcher hook** — fires immediately on interface up, DHCP lease, or connectivity change events
- a **systemd timer fallback** — runs every 5 minutes for silent link drops that do not produce a dispatcher event

The timer uses a quiet service variant (`--quiet`) to suppress log output during routine checks.

### Why both triggers exist

Not all network transitions produce a NetworkManager dispatcher event. Unplugging a USB dongle, a VPN client resetting its tunnel, or VMware itself restarting can change the correct bridge choice without firing a visible interface event. The 5-minute timer catches these cases.

### Configuration

The script ships with sensible defaults. To override them, edit `/etc/vmwareworkstation-bridge-monitor.conf` (installed by the setup script). The config file is sourced after the built-in defaults, so any value set there takes precedence. It will not be overwritten by re-running the installer.

| Variable | Default | Description |
|----------|---------|-------------|
| `ADAPTERS` | `("enx*" "wlp*")` | Ordered list of adapter name patterns to try, highest priority first. Supports exact names or globs. Customise this to match your interface naming. |
| `EXCLUDED` | see script | Interfaces that must never be selected. Add any additional VPN tunnels or virtual adapters specific to your environment. |
| `PING_HOST` | `1.1.1.1` | IP used for the connectivity test — a plain IP to avoid DNS interception. |
| `CURL_TEST_URL` | connectivitycheck.gstatic.com | Fallback connectivity check URL for environments where ICMP is blocked. |
| `VMNET_INDEX` | `0` | The vmnet device index to manage (`0` = `vmnet0` = Bridged/Auto). |
| `LOG_FILE` | `/var/log/vmwareworkstation-bridge-monitor.log` | Set to `""` to disable logging. |

### Installation

Run the installer as root from the project directory:

```bash
sudo ./vmwareworkstation-bridge-monitor/setup_vmwareworkstation-bridge-monitor.sh
```

That script installs:

- `/usr/local/sbin/vmwareworkstation-bridge-monitor.sh`
- `/etc/vmwareworkstation-bridge-monitor.conf` (only if one does not already exist)
- `/etc/NetworkManager/dispatcher.d/99-vmwareworkstation-bridge-monitor`
- `/etc/systemd/system/vmwareworkstation-bridge-monitor.service`
- `/etc/systemd/system/vmwareworkstation-bridge-monitor-quiet.service`
- `/etc/systemd/system/vmwareworkstation-bridge-monitor.timer`

### Manual run

To test the check directly:

```bash
sudo ./vmwareworkstation-bridge-monitor/vmwareworkstation-bridge-monitor.sh
```

To run the installed copy:

```bash
sudo /usr/local/sbin/vmwareworkstation-bridge-monitor.sh
```

To simulate a NetworkManager event:

```bash
sudo /etc/NetworkManager/dispatcher.d/99-vmwareworkstation-bridge-monitor enx98e743095993 up
```

### Verification

Check the timer:

```bash
sudo systemctl status vmwareworkstation-bridge-monitor.timer
```

Check service logs:

```bash
journalctl -u vmwareworkstation-bridge-monitor.service -f
```

Check the script log:

```bash
sudo tail -f /var/log/vmwareworkstation-bridge-monitor.log
```

List active timers:

```bash
systemctl list-timers vmwareworkstation-bridge-monitor.timer
```

### Assumptions

- VMware Workstation is installed and `/etc/vmware/networking` exists
- `vmware-networks` is available on the system path
- NetworkManager is present and active
- `systemd` is the init system
- The host is Linux

### Scope

This tool does not try to be a general VMware network manager. It solves one specific problem: keeping `vmnet0` bridged to a working physical interface after any network change.

---

## module-builder — rebuild kernel modules after a kernel update

### The problem

VMware Workstation ships its `vmmon` and `vmnet` kernel modules as source tarballs that must be compiled against the running kernel's headers. After every kernel update the old `.ko` files no longer match and VMware refuses to start. On systems with Secure Boot enabled, modules also need to be signed with an enrolled MOK key before the kernel will load them.

### The solution

The module builder automates the entire lifecycle using the module sources that VMware Workstation ships itself (`/usr/lib/vmware/modules/source/`):

1. Extracts `vmmon.tar` and `vmnet.tar` from the VMware installation into a temporary build directory
2. Builds `vmmon.ko` and `vmnet.ko` against the target kernel's headers
3. Signs both modules with your MOK key pair (skips gracefully if Secure Boot is not in use)
4. Installs the `.ko` files to `/lib/modules/<kver>/misc/`
5. Runs `depmod`, reloads the modules, and restarts VMware services

A kernel post-install hook fires automatically whenever apt installs a new kernel, so modules are rebuilt before you even reboot.

### Installation

Run the setup wizard once as root:

```bash
sudo ./vmwareworkstation-module-builder/setup_vmwareworkstation-module-builder.sh
```

The wizard will:

1. **MOK key pair** — generate a signing key and certificate in `/etc/vmwareworkstation-module-builder/`, then run `mokutil --import` to queue enrollment. You will need to reboot and approve the MOK in the UEFI MOK Manager screen before signed modules will load.
2. **Post-install hook** — install `/etc/kernel/postinst.d/vmwareworkstation-module-builder` so future kernel updates trigger an automatic rebuild.
3. **Build** — optionally build and install modules for the running kernel immediately.

The wizard installs:

- `/usr/local/sbin/vmwareworkstation-module-builder.sh`
- `/etc/vmwareworkstation-module-builder.conf`
- `/etc/vmwareworkstation-module-builder/MOK.priv` and `MOK.crt`
- `/etc/kernel/postinst.d/vmwareworkstation-module-builder`

### Secure Boot and MOK keys

The private key is stored in `/etc/vmwareworkstation-module-builder/` with root-only access (`chmod 600`). No passphrase is used — this matches how DKMS handles its own signing key, and is necessary for automated post-install builds to sign without user interaction. Access is controlled by filesystem permissions rather than encryption.

After `mokutil --import` you must reboot and complete enrollment in the UEFI MOK Manager before signed modules will be accepted by the kernel. The setup wizard gives you step-by-step instructions and will not run the first build until enrollment is confirmed.

### Manual run

To rebuild for the currently running kernel:

```bash
sudo /usr/local/sbin/vmwareworkstation-module-builder.sh
```

To build for a specific kernel (e.g. before rebooting into it):

```bash
sudo /usr/local/sbin/vmwareworkstation-module-builder.sh --kernel 6.14.0-15-generic
```

### Configuration

All settings are in `/etc/vmwareworkstation-module-builder.conf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MODULES_TARBALLS` | `/usr/lib/vmware/modules/source` | Directory containing `vmmon.tar` and `vmnet.tar` shipped by VMware Workstation. |
| `MOK_KEY` | `/etc/vmwareworkstation-module-builder/MOK.priv` | MOK private key. Leave unset to skip signing. |
| `MOK_CERT` | `/etc/vmwareworkstation-module-builder/MOK.crt` | MOK certificate. |
| `KVER` | `$(uname -r)` | Kernel version to build for. Also overridable via `--kernel` flag. |
| `LOG_FILE` | `/var/log/vmwareworkstation-module-builder.log` | Set to `""` to disable logging. |

### Assumptions

- VMware Workstation is installed (ships module sources in `/usr/lib/vmware/modules/source/`)
- `make`, `gcc` (`build-essential`) are installed
- `linux-headers-<kver>` is available for the target kernel
- For Secure Boot: `openssl` and `mokutil` are installed

---

## Related

[TailScaler](https://github.com/WilhelmZA/TailScaler) — fixes Tailscale and ZScaler firewall rule conflicts on the same Linux host.
