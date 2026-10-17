# OMV NVMe-over-TCP (nvmetcp) Plugin

The **nvmetcp** plugin allows an OpenMediaVault (OMV) system to act as an **NVMe-over-TCP target**, using the Linux kernel's built-in `nvmet` subsystem.
It provides a web UI to configure ports, subsystems, namespaces, and host access, and generates `/etc/nvmet/config.json` automatically via SaltStack. The configuration is loaded by `nvmet.service` (`nvmetcli restore`).

> **Status:** experimental.

---

## ⚡ Quick Start (TL;DR)

1. **Install plugin** via OMV-Extras → Plugins → `openmediavault-nvmetcp`
2. Go to **Services → NVMe/TCP → Settings**
   - ✅ Enable
   - ✅ Leave auto‑associate ON (default)
3. Go to **Ports → Add**
   - Address: `0.0.0.0`
   - TCP port: `4420`
   - Address family: `IPv4`
4. Go to **Subsystems → Create**
   - ✅ Enable
   - NQN: `nqn.2025-10.io.omv:fastssd`
   - ✅ Allow any host (or add host NQNs under **Hosts**)
   - Namespaces → Add → Backing path: `/dev/sdb` (or ZFS zvol, LV, etc.)
5. Click **Apply** in OMV to deploy the configuration
6. On a Linux host:

```bash
sudo modprobe nvme-tcp
sudo nvme discover -t tcp -a <OMV_IP> -s 4420
sudo nvme connect -t tcp -a <OMV_IP> -s 4420 -n nqn.2025-10.io.omv:fastssd
lsblk   # → will show /dev/nvme0n1
```

You're now serving a raw block device over the network at kernel-level speeds. 🚀
For persistent setup, see initiator examples below.

---

## ✅ Requirements

| Requirement | Notes |
|-------------|-------|
| OMV 8+ | Available via `omv-extras` repo |
| `nvmetcli` | Installed as a dependency; provides `nvmet.service` |
| Linux kernel with `nvmet` + `nvmet-tcp` | Included by default in Debian 12+ |
| NVMe-TCP capable initiator | Linux `nvme-cli`, Proxmox, ESXi 8, Windows 11, etc. |

---

## 📌 Plugin UI Overview

| Page | Purpose |
|------|---------|
| **Settings** | Global options: enable/disable, auto-associate, org domain/date for NQNs |
| **Subsystems** | Create subsystems, namespaces, allowed hosts |
| **Ports** | Configure NVMe-TCP listener endpoints |
| **Associations** | Manually link subsystems → ports |

All changes mark the configuration **dirty** and require clicking **Apply** in OMV.

---

## ⚙️ Settings

| Field | Description |
|--------|-------------|
| `Enable` | Master on/off switch for `nvmet.service` |
| `Description` | Free-form note |
| `Auto-associate ports and subsystems` | Link ports without explicit associations to all enabled subsystems |
| `Domain` | Reverse DNS used for generated NQNs (default `io.omv`) |
| `Date` | `YYYY-MM` used in generated NQNs (default `2014-08`) |

The domain and date are only used when a subsystem is created through the RPC without an NQN, e.g. `nqn.2014-08.io.omv:<description>`. The web UI requires an NQN.

---

## 🌐 Ports

Defines TCP listeners where initiators connect.

| Field | Description |
|--------|-------------|
| `Address` | Listening address. `0.0.0.0` (IPv4) or `::` (IPv6) listens on all addresses |
| `TCP port` | Usually `4420`; must be unique across ports |
| `Address family` | `IPv4` or `IPv6` |

✔ Multiple ports supported
✔ Each can bind to a different local address

If the configured address is not assigned to this host (for the selected family), the port falls back to listening on all addresses of that family.

---

## 🗂 Subsystems

A subsystem is similar to an iSCSI target. Only **enabled** subsystems are exported.

| Field | Description |
|--------|-------------|
| `Enable` | Export this subsystem |
| `NQN` | Subsystem NQN (`nqn.…`); must be unique |
| `Model` | Model name reported to initiators (max 40 characters) |
| `Serial` | Serial number reported to initiators (max 20 characters); should be unique per subsystem |
| `Allow any host` | If off, only the listed hosts may connect |
| `Hosts` | Allowed host NQNs (see `/etc/nvme/hostnqn` on the initiator) |

### Namespaces

| Field | Description |
|--------|-------------|
| `NSID` | Namespace ID. Optional – the next free ID is assigned if left blank; must be unique within the subsystem |
| `Backing path` | `/dev/sdX`, `/dev/nvme0n1`, `/dev/mapper/vg-lv`, `/dev/zvol/pool/vol`, etc. |
| `UUID` / `NGUID` | Optional namespace identifiers |
| `EUI-64` | Not supported by the kernel target; ignored |

> Namespaces are always exported read-write. The kernel `nvmet` target has no per-namespace read-only setting; restrict access with allowed hosts instead.

---

## 🔗 Associations

Associations explicitly link a port to one or more subsystems.

- A port that has explicit associations exports **only** those subsystems.
- A port without associations exports **all enabled subsystems** when auto-associate is on, and nothing when it is off.
- Deleting a port or subsystem also deletes its associations.

---

## 🧱 Example Generated `/etc/nvmet/config.json`

```json
{
  "hosts": [
    { "nqn": "nqn.2014-08.org.nvmexpress:uuid:1b4e28ba-2fa1-11d2-883f-0016d3cca427" }
  ],
  "ports": [
    {
      "portid": 1,
      "addr": {
        "trtype": "tcp",
        "adrfam": "ipv4",
        "traddr": "192.168.10.100",
        "trsvcid": 4420
      },
      "referrals": [],
      "subsystems": [ "nqn.2025-10.io.omv:fastssd" ]
    }
  ],
  "subsystems": [
    {
      "nqn": "nqn.2025-10.io.omv:fastssd",
      "attr": {
        "allow_any_host": "0",
        "serial": "OMV00000001",
        "model": "OMV NVMe Target",
        "version": "1.0"
      },
      "namespaces": [
        { "nsid": 1, "enable": 1, "device": { "path": "/dev/sdb" } }
      ],
      "allowed_hosts": [
        "nqn.2014-08.org.nvmexpress:uuid:1b4e28ba-2fa1-11d2-883f-0016d3cca427"
      ]
    }
  ]
}
```

---

## 🔌 Connecting from Linux Initiator

```bash
sudo modprobe nvme-tcp
sudo nvme discover -t tcp -a 192.168.10.100 -s 4420
sudo nvme connect -t tcp -a 192.168.10.100 -s 4420 \
    -n nqn.2025-10.io.omv:fastssd
```

Device appears as `/dev/nvme0n1`.

---

## 🛠 Troubleshooting

| Issue | Fix |
|-------|-----|
| `nvmet.service` fails to start | `lsmod \| grep nvmet` to confirm kernel support; `journalctl -u nvmet` |
| No device detected on initiator | Ensure the subsystem is enabled, has a namespace, and is linked to the port (association or auto-associate) |
| `Host not allowed` error | Add the initiator's host NQN to the subsystem, or enable *Allow any host* |
| Windows doesn't see device | Requires 4K block + single namespace |

---

## 👍 Best Practices

✔ Use dedicated NIC / VLAN for NVMe traffic
✔ Prefer ZFS zvols or LVM LV backing devices
✔ Keep NQNs stable (changing breaks initiators)
✔ Give each subsystem a unique serial number
✔ Prefer host allow-lists over *Allow any host*

---

## 📄 License

GPLv3 – same as OpenMediaVault core plugins.

---

## 🗣 Feedback / Issues

Please open issues or PRs in the plugin repo.

---

## 🚀 Initiator Examples

Below are practical examples for common initiators. Replace placeholders like `<TARGET_IP>`, `<PORT>`, and `<SUBSYSTEM_NQN>` with your actual values.

### 1) Linux (nvme-cli) — Quick Test

```bash
# 1) Ensure the kernel initiator is available
sudo modprobe nvme-tcp

# 2) (Optional) Set/verify host NQN (appears on target as an allowed host)
sudo cat /etc/nvme/hostnqn || sudo nvme gen-hostnqn | sudo tee /etc/nvme/hostnqn

# 3) Discover the target
sudo nvme discover -t tcp -a <TARGET_IP> -s <PORT>

# 4) Connect to a specific subsystem
sudo nvme connect -t tcp -a <TARGET_IP> -s <PORT> -n <SUBSYSTEM_NQN>

# 5) Verify block device
lsblk
# -> /dev/nvme0n1 (or similar)
```

**Disconnect when done:**
```bash
sudo nvme disconnect -n <SUBSYSTEM_NQN>
```

---

### 2) Linux — Persistent Connection (systemd service)

Create a per-subsystem systemd unit so it reconnects on boot.

`/etc/systemd/system/nvme-connect@.service`
```ini
[Unit]
Description=NVMe/TCP Connect to %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvme connect -t tcp -a <TARGET_IP> -s <PORT> -n %i
ExecStop=/usr/bin/nvme disconnect -n %i

[Install]
WantedBy=multi-user.target
```

Enable for a given NQN:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nvme-connect@<SUBSYSTEM_NQN>.service
```

---

### 3) Linux — Using **STAS** (Storage Appliance Services) for auto-discovery

`nvme-stas` provides **stafd** (finder) and **stacd** (connector) for NVMe/TCP. Configure a **Central or Direct Discovery Controller (CDC/DDC)** and let the client auto-(re)connect.

`/etc/stas/stas.conf` (minimal static discovery example)
```toml
# stacd: connect I/O controllers discovered from a Discovery Controller
[stacd]
# Add one or more discovery entries (IP + TCP port)
discovery-controller = [
  { transport = "tcp", traddr = "<TARGET_IP>", trsvcid = "<PORT>", adrfam = "ipv4" }
]
# Optional: set host NQN explicitly
# hostnqn = "/etc/nvme/hostnqn"
```

Activate:
```bash
sudo systemctl enable --now stafd.service stacd.service
journalctl -u stacd -u stafd -f
```

---

### 4) Proxmox VE

Proxmox uses the Linux initiator — steps are the same as Section 1. Recommended specifics:

```bash
# Load initiator at boot
echo nvme-tcp | sudo tee /etc/modules-load.d/nvme-tcp.conf

# Optional: increase queue depth or tune sysctls as needed

# Discover & connect (as root on the PVE host)
nvme discover -t tcp -a <TARGET_IP> -s <PORT>
nvme connect  -t tcp -a <TARGET_IP> -s <PORT> -n <SUBSYSTEM_NQN>

# Verify new device and add as a PV/LVM or ZFS member if appropriate
lsblk
```

> For persistent connections across reboots, use the **systemd unit** method or **STAS**.

---

### 5) VMware ESXi 8.x (CLI)

On ESXi 8.x, NVMe-over-TCP is supported. Use `esxcli`:

```bash
# 1) Discover
esxcli nvme discover -t tcp -a <TARGET_IP> -s <PORT>

# 2) Add the controller (bind to subsystem NQN)
esxcli nvme controller add -t tcp -a <TARGET_IP> -s <PORT> -n <SUBSYSTEM_NQN>

# 3) Verify
esxcli nvme controller list
esxcli storage core adapter list
esxcli storage core device list
```

To remove:
```bash
esxcli nvme controller remove -A <ControllerID>
```

> In vSphere Client, you can also add an **NVMe/TCP adapter**, then set up Discovery and Controllers via the UI.

---

### 6) Windows 11 / Windows Server 2022

Windows includes an NVMe/TCP initiator in recent builds. Administrative steps generally involve:

1. Ensure your NIC and OS build support NVMe/TCP.
2. Add a **Discovery Controller** and then **Connect to Subsystem** (via OS UI or vendor-provided tools).
3. Use a 4K block-size namespace (Windows is picky about sector size).
4. Single namespace per subsystem is the most compatible configuration.

> **Note:** Windows tooling and UI can vary by build and vendor. If you use a vendor-provided NVMe/TCP utility, follow its “Add Discovery Controller” → “Connect Subsystem” workflow with:
> - Transport: **TCP**
> - TrAddr: `<TARGET_IP>`
> - TrSvcId (Port): `<PORT>` (default 4420)
> - NQN: `<SUBSYSTEM_NQN>`

---

### 7) Multipath (Linux)

For HA targets (multiple ports or paths), enable device-mapper multipathing:

```bash
sudo apt-get install multipath-tools
sudo systemctl enable --now multipathd
sudo multipath -ll
```

Ensure you connect to multiple **target IP:port** paths for the same **NQN**. The kernel will expose a single multipath device (e.g., `/dev/mapper/nvmeXnY`) if eligible.

---

### 8) Useful Commands (Initiators)

```bash
# List current NVMe connections / controllers / namespaces
nvme list
nvme list-subsys
nvme list-ctrl

# Show logs
dmesg | grep -i nvme
journalctl -k | grep -i nvme

# Disconnect all controllers for a specific subsystem
nvme disconnect -n <SUBSYSTEM_NQN>
```
