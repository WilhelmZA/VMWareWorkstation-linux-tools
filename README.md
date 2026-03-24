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

## Related

[TailScaler](https://github.com/WilhelmZA/TailScaler) — fixes Tailscale and ZScaler firewall rule conflicts on the same Linux host.
