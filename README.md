# hardware-inventory

A Bash script to generate a **full hardware inventory** of a computer (Linux only).
Made to run on every PC at home (even from a **live USB**) and save the
result to a text file, so you can check later without having to boot each
machine again.

## What information it provides

| Section | Details |
|---|---|
| **System** | OS, kernel, manufacturer, model, **machine UUID** |
| **Processor** | Model, architecture, cores/threads, speed, flags |
| **Memory RAM** | Number of slots, occupied/empty slots, max capacity, type (DDR3/DDR4…), speed, manufacturer, sizes in bytes |
| **GPU** | Model, chipset, kernel driver |
| **Disks** | Disk, type (SSD/HDD), size (in bytes), connection (SATA/USB/NVMe), model, partitions |
| **Disk health (SMART)** | Health status and temperature per disk (optional tool) |
| **Network** | Network cards (Ethernet/WiFi) and interfaces |
| **BIOS** | Manufacturer, version, release date |

## Requirements

- Bash (present in any Linux / live USB)
- **sudo**: run the script directly with `sudo` to get the complete info.
  Without sudo the output is partial (RAM slots, max capacity, BIOS details
  and SMART are skipped).
- Tools (optional, the script detects them and warns which are missing):
  - `lscpu`, `lspci`, `lsblk` — basic info
  - `lshw` — extra system/disk details
  - `dmidecode` — RAM slots and max capacity
  - `smartctl` (smartmontools) — disk health and temperature
  > Typical install on Debian/Ubuntu:
  > `sudo apt install smartmontools lshw dmidecode pciutils`

## Installation

Download the script and give it execution permission:

```bash
wget https://raw.githubusercontent.com/arodu/hardware-inventory/main/hardware-inventory.sh
chmod +x hardware-inventory.sh
```

## Usage

```bash
sudo ./hardware-inventory.sh                   # full inventory (recommended)
sudo ./hardware-inventory.sh -o pc             # saves text to pc-<date>-<host>.txt
sudo ./hardware-inventory.sh -j > pc.json      # saves the JSON to a file (Linux pipe)
sudo ./hardware-inventory.sh -j | jq .         # pretty-print the JSON with jq
sudo ./hardware-inventory.sh -s                # also collects SMART disk health (slower)
./hardware-inventory.sh                        # partial info without sudo
./hardware-inventory.sh -h                     # shows help
```

> Run it **directly with sudo** to get the complete info (RAM slots, max
> capacity, BIOS details, SMART). The output goes to the console, so there is
> no need for a cached-credentials mechanism. Without sudo you get a partial
> inventory and the script tells you to run it with sudo.
>
> SMART (`-s`) is **off by default** so the run is quick. Enable it only when
> you want the disk health section.

### JSON output

With `-j` the script prints the inventory as JSON directly to the screen
(stdout). It does **not** create a file; to save it use a Linux pipe:

```bash
sudo ./hardware-inventory.sh -j > living-room.json
sudo ./hardware-inventory.sh -j | jq .          # pretty-print with jq
```

> The JSON is the only thing printed to stdout, so it is safe to pipe it.
> Messages like the tools check go to stderr.

JSON structure:

JSON structure:

```json
{
  "tool": "hardware-inventory",
  "generated_at": "2026-08-14T09:00:00-04:00",
  "host": "my-pc",
  "machine_id": "4c4c4544-0058-3510-8048-c7c04f4a5732",
  "system": { "os": "...", "kernel": "...", "manufacturer": "HP", "product": "...", "board": "...", "serial": "..." },
  "cpu": { "vendor": "...", "model": "...", "architecture": "...", "cores": "4", "threads_per_core": "1", "sockets": "1", "min_mhz": "...", "max_mhz": "..." },
  "memory": {
    "total": "7.6GiB",
    "total_bytes": 8196661248,
    "max_capacity": "32 GB",
    "max_capacity_bytes": 34359738368,
    "slots_count": "2",
    "modules": [
      { "slot": "DIMM1", "size": "8 GB", "size_bytes": 8589934592, "type": "DDR4", "speed": "2133", "form_factor": "DIMM", "manufacturer": "Micron" },
      { "slot": "DIMM3", "size": null, "size_bytes": null, "type": null, "speed": null, "form_factor": "DIMM", "manufacturer": null }
    ]
  },
  "gpu": [ { "device": "...", "driver": "i915" } ],
  "disks": [ { "name": "/dev/sda", "type": "HDD", "size": "223.6GiB", "size_bytes": 240057409536, "connection": "USB", "rotational": 1, "model": "..." } ],
  "partitions": [ { "name": "sda1", "size": "512MiB", "size_bytes": 536870912, "fstype": "vfat", "mountpoint": "/boot/efi" } ],
  "network": [ "eno1", "wlp2s0" ],
  "bios": { "vendor": "HP", "version": "...", "release_date": "..." },
  "smart": [ { "device": "/dev/sda", "health": "PASSED", "temperature": "41" } ]
}
```

> Notes:
> - `machine_id` is the machine UUID (from DMI) — a stable ID you can use in
>   your organizer to track each machine and detect hardware changes over time.
> - Every size appears twice: human-readable (`"size": "223.6GiB"`) and in
>   bytes (`"size_bytes": 240057409536`) so your app can compare them
>   numerically without parsing strings.
> - Empty slots use `null` for the values the computer reports as "no module
>   installed". Without `sudo`, `machine_id`, `max_capacity`, `slots_count`,
>   `modules` and `smart` will be `null`/empty.

### Example: inventory a computer from a live USB

```bash
wget https://raw.githubusercontent.com/arodu/hardware-inventory/main/hardware-inventory.sh
chmod +x hardware-inventory.sh
sudo ./hardware-inventory.sh -o machine          # text inventory
sudo ./hardware-inventory.sh -j > machine.json   # JSON inventory (pipe)
```

### Example output (RAM)

```
========================================
MEMORY RAM
========================================
Max capacity: 32 GB (34359738368 bytes)
Slots count:  2
Total RAM:    7.6GiB (8196661248 bytes)

SLOT        SIZE         TYPE       SPEED    FORM     MANUFACTURER
----        ------       ----       ----     -----    ------------
DIMM1       8 GB         DDR4       2133     SODIMM   Micron
DIMM3       EMPTY        -          -        -        -
```

## Notes

- The text output file uses the format `name-YYYYMMDD_HHMMSS-hostname.txt`.
  The JSON is printed to stdout with `-j`; pipe it to a file to save it.
- SMART disk health only runs with `-s` (off by default for speed).
- Linux only.
- `lshw`, `dmidecode` and `smartctl` are not available on all systems by
  default; without them the script still works but with reduced information.
  The script warns at startup which optional tools are missing and how to
  install them.
