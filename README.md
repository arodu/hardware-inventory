# hardware-inventory

A Bash script to generate a **full hardware inventory** of a computer.
Made to run on every PC at home (even from a **live USB**) and save the
result to a text file, so you can check later without having to boot each
machine again.

## What information it provides

| Section | Details |
|---|---|
| **System** | OS, kernel, manufacturer, model, serial number |
| **Processor** | Model, architecture, cores/threads, speed, flags |
| **Memory RAM** | Number of slots, occupied/empty slots, max capacity, type (DDR3/DDR4…), speed, manufacturer |
| **GPU** | Model, chipset, kernel driver |
| **Disks** | Disk, type (SSD/HDD), size, connection (SATA/USB/NVMe), model, partitions |
| **Network** | Network cards (Ethernet/WiFi) and interfaces |
| **BIOS** | Manufacturer, version, release date |

## Requirements

- Bash (present in any Linux / live USB)
- Tools: `lscpu`, `lspci`, `lsblk`, `free`, `lshw` (optional), `dmidecode` (optional)
  > Typical install on Debian/Ubuntu:
  > `sudo apt install lshw dmidecode pciutils`
- **sudo**: recommended to run with root permissions to get the complete
  information (RAM slots, max capacity, BIOS, disk model). Without sudo the
  output is partial.

## Installation

Download the script and give it execution permission:

```bash
wget https://raw.githubusercontent.com/arodu/hardware-inventory/main/hardware-inventory.sh
chmod +x hardware-inventory.sh
```

## Usage

```bash
./hardware-inventory.sh                        # prints the inventory to screen
sudo ./hardware-inventory.sh                   # with full permissions (recommended)
sudo ./hardware-inventory.sh -o pc             # saves to pc-<date>-<host>.txt
sudo ./hardware-inventory.sh -o pc -j          # also generates pc-<date>-<host>.json
./hardware-inventory.sh -h                     # shows help
```

### JSON output

With the `-j` flag the script also generates a JSON file (same base name as the
text file) so you can feed it to your own application:

```bash
sudo ./hardware-inventory.sh -o living-room -j
cat living-room-*.json
```

JSON structure:

```json
{
  "tool": "hardware-inventory",
  "generated_at": "2026-08-14T09:00:00-04:00",
  "host": "my-pc",
  "system": { "os": "...", "kernel": "...", "manufacturer": "HP", "product": "...", "board": "...", "serial": "..." },
  "cpu": { "vendor": "...", "model": "...", "architecture": "...", "cores": "4", "threads_per_core": "1", "sockets": "1", "min_mhz": "...", "max_mhz": "..." },
  "memory": {
    "total": "7.6Gi",
    "max_capacity": "32 GB",
    "slots_count": "2",
    "modules": [
      { "slot": "DIMM1", "size": "8 GB", "type": "DDR4", "speed": "2133", "form_factor": "DIMM", "manufacturer": "Micron" },
      { "slot": "DIMM3", "size": null, "type": null, "speed": null, "form_factor": "DIMM", "manufacturer": null }
    ]
  },
  "gpu": [ { "device": "...", "driver": "i915" } ],
  "disks": [ { "name": "/dev/sda", "type": "HDD", "size": "223.6G", "connection": "USB", "rotational": 1, "model": "..." } ],
  "partitions": [ { "name": "sda1", "size": "512M", "fstype": "vfat", "mountpoint": "/boot/efi" } ],
  "network": [ "eno1", "wlp2s0" ],
  "bios": { "vendor": "HP", "version": "...", "release_date": "..." }
}
```

> Note: empty slots use `null` for the values the computer reports as "no
> module installed". Without `sudo`, `max_capacity`, `slots_count` and
> `modules` will be empty/null.

### Example: inventory a computer from a live USB

```bash
wget https://raw.githubusercontent.com/arodu/hardware-inventory/main/hardware-inventory.sh
chmod +x hardware-inventory.sh
sudo ./hardware-inventory.sh -o machine -j
cat machine-*.txt
cat machine-*.json
```

### Example output (RAM)

```
========================================
MEMORY RAM
========================================
Max capacity: Maximum Capacity: 32 GB
Slots count:  Number Of Devices: 2
Total RAM:    7.6Gi

SLOT        SIZE         TYPE       SPEED    FORM     MANUFACTURER
----        ------       ----       ----     -----    ------------
DIMM1       8 GB         DDR4       2133     DIMM     Micron
DIMM3       EMPTY        -          -        DIMM     -
```

## Notes

- The output file uses the format `name-YYYYMMDD_HHMMSS-hostname.txt`.
- `lshw` and `dmidecode` are not available on all systems by default;
  without them the script still works but with reduced information.
