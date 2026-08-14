#!/usr/bin/env bash
#
# hardware-inventory.sh
# Generates a full hardware inventory of the machine (Linux only).
# Meant to be run on every computer (even from a live USB).
#
# Usage:
#   sudo ./hardware-inventory.sh            # full inventory (recommended)
#   ./hardware-inventory.sh -o inventory    # saves text to inventory-<date>-<host>.txt
#   ./hardware-inventory.sh -j              # prints JSON to stdout
#   ./hardware-inventory.sh -s              # also collects SMART disk health
#   ./hardware-inventory.sh -h              # shows help
#
# Run it directly with sudo for the complete info (RAM slots, max capacity,
# BIOS, SMART). Without sudo the output is partial.

set -uo pipefail

if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
  echo "[!] hardware-inventory only supports Linux."
  exit 1
fi

OUTFILE=""
JSON=0
SMART=0
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
FECHA=$(date +"%Y-%m-%d_%H%M%S")
PRIV=0

# --- OS info ---------------------------------------------------------------
OS_NAME=""; OS_VERSION=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME="$PRETTY_NAME"
  OS_VERSION="$VERSION"
fi

# --- Tools -----------------------------------------------------------------
HAVE_LSHW=0;     command -v lshw    >/dev/null 2>&1 && HAVE_LSHW=1
HAVE_LSPCI=0;    command -v lspci   >/dev/null 2>&1 && HAVE_LSPCI=1
HAVE_LSCPU=0;    command -v lscpu   >/dev/null 2>&1 && HAVE_LSCPU=1
HAVE_UNAME=0;    command -v uname   >/dev/null 2>&1 && HAVE_UNAME=1
HAVE_SMARTCTL=0; command -v smartctl >/dev/null 2>&1 && HAVE_SMARTCTL=1
HAVE_LSBLK=0;    command -v lsblk   >/dev/null 2>&1 && HAVE_LSBLK=1
HAVE_IP=0;       command -v ip      >/dev/null 2>&1 && HAVE_IP=1

# dmidecode lives in /sbin or /usr/sbin, which is usually not in the PATH
DMI=""
for p in /usr/sbin/dmidecode /sbin/dmidecode; do
  [ -x "$p" ] && DMI=$p && break
done

# --- Utilities -------------------------------------------------------------
encabezado() { printf '\n%s\n%s\n%s\n' "========================================" "$1" "========================================"; }

detectar_priv() {
  if [ "$(id -u)" -eq 0 ]; then
    PRIV=1
  else
    PRIV=0
  fi
}

sudo_o() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    "$@" 2>/dev/null
  fi
}

# --- JSON helpers -----------------------------------------------------------
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
json_str() { printf '"%s"' "$(esc "$1")"; }
json_val() { if [ -z "$1" ]; then printf 'null'; else json_str "$1"; fi; }
json_num() { if [ -z "$1" ] || ! printf '%s' "$1" | grep -qE '^[0-9]+$'; then printf 'null'; else printf '%s' "$1"; fi; }
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
gpu_class='\[0300\]|\[0302\]|\[0380\]'

dmi_file() {
  local f="/sys/class/dmi/id/$1"
  if [ -r "$f" ]; then
    cat "$f"
  elif [ "$PRIV" -eq 1 ]; then
    sudo_o cat "$f" 2>/dev/null
  fi
}

# --- Byte helpers -----------------------------------------------------------
# Convert bytes to a human readable string (e.g. 240057409536 -> 223.6G)
human_bytes() {
  printf '%s' "$1" | awk '
    {
      if ($1 == "") { print ""; exit }
      b = $1 + 0
      if (b < 0) { print ""; exit }
      units = "B KiB MiB GiB TiB"
      n = split(units, u, " ")
      i = 1
      while (b >= 1024 && i < n) { b = b / 1024; i++ }
      printf "%.1f%s\n", b, u[i]
    }'
}

# Convert a size string to bytes (e.g. "32 GB" -> 34359738368, "223.6G" -> ...)
parse_bytes() {
  local s=$1
  [ -z "$s" ] && { printf '%s' ''; return; }
  printf '%s' "$s" | awk '
    {
      num = $1
      unit = toupper($2)
      mult = 1
      if (unit ~ /K/) mult = 1024
      else if (unit ~ /M/) mult = 1024 * 1024
      else if (unit ~ /G/) mult = 1024 * 1024 * 1024
      else if (unit ~ /T/) mult = 1024 * 1024 * 1024 * 1024
      printf "%.0f\n", num * mult
    }'
}

RAM_TOTAL_BYTES=$(awk '/^MemTotal:/{print $2 * 1024}' /proc/meminfo 2>/dev/null)

# --- Text output: System ----------------------------------------------------
info_sistema() {
  encabezado "SYSTEM"
  [ "$HAVE_UNAME" -eq 1 ] && printf 'Kernel: %s\n' "$(uname -srm)"
  if [ -n "$OS_NAME" ]; then
    printf 'OS:     %s %s\n' "$OS_NAME" "$OS_VERSION"
  fi
  printf 'Host:   %s\n' "$HOSTNAME"
  printf 'UUID:   %s\n' "$MACHINE_ID"

  local mfr prod board
  mfr=$(dmi_file sys_vendor)
  prod=$(dmi_file product_name)
  board=$(dmi_file board_name)
  [ -n "$mfr" ]  && printf 'Manufacturer: %s\n' "$mfr"
  [ -n "$prod" ] && printf 'Product:      %s\n' "$prod"
  [ -n "$board" ] && printf 'Board:        %s\n' "$board"

  if [ "$PRIV" -eq 1 ] && [ "$HAVE_LSHW" -eq 1 ]; then
    local sys
    sys=$(sudo_o lshw -class system 2>/dev/null)
    printf '%s\n' "$sys" | awk '
      /\*-/ { exit }
      /^[[:space:]]*(description|product|vendor|version|serial|configuration):/ {
        sub(/^[[:space:]]*/, ""); print
      }
    '
  fi
}

# --- Text output: CPU -------------------------------------------------------
info_cpu() {
  encabezado "PROCESSOR"
  if [ "$HAVE_LSCPU" -eq 1 ]; then
    lscpu | grep -E '^Model name|^Architecture|^CPU\(s\)|^Thread|^Core|^Socket|^Vendor|^CPU MHz|^CPU max|^CPU min|^CPU op-mode|^Virtualization|^Flags' | sed 's/  */ /g'
  else
    grep -E '^model name|^vendor_id|^cpu MHz|^physical id|^siblings|^flags' /proc/cpuinfo | sort -u
  fi
}

# --- Text output: RAM -------------------------------------------------------
info_ram() {
  encabezado "MEMORY RAM"
  printf 'Total RAM:    %s (%s bytes)\n' "$(human_bytes "$RAM_TOTAL_BYTES")" "$RAM_TOTAL_BYTES"
  if [ -n "$DMI" ] && [ "$PRIV" -eq 1 ]; then
    local dmi16 dmi17
    dmi16=$(sudo_o "$DMI" -t 16 2>/dev/null)
    dmi17=$(sudo_o "$DMI" -t 17 2>/dev/null)
    local maxcap
    maxcap=$(echo "$dmi16" | grep -i 'Maximum Capacity' | sed 's/^[[:space:]]*//' | sed 's/Maximum Capacity:[[:space:]]*//')
    printf 'Max capacity: %s (%s bytes)\n' "$maxcap" "$(parse_bytes "$maxcap")"
    printf 'Slots count:  %s\n' "$(echo "$dmi16" | grep -i 'Number Of Devices' | sed 's/^[[:space:]]*//' | sed 's/Number Of Devices:[[:space:]]*//')"
    echo
    printf '%-12s %-12s %-10s %-8s %-8s %-10s\n' "SLOT" "SIZE" "TYPE" "SPEED" "FORM" "MANUFACTURER"
    printf '%-12s %-12s %-10s %-8s %-8s %-10s\n' "----" "------" "----" "----" "-----" "------------"
    echo "$dmi17" | awk '
      /DMI type 17/ {
        if (contado) printf "%-12s %-12s %-10s %-8s %-8s %-10s\n", slot, size, tipo, vel, forma, fab
        slot=""; size=""; tipo=""; vel=""; forma=""; fab=""; contado=1
      }
      /^[[:space:]]*Locator:/ { slot=$NF }
      /^[[:space:]]*Size:/ { size=$2" "$3; if ($0 ~ /No Module/) size="EMPTY" }
      /^[[:space:]]*Type:/ { if ($2 != "Unknown") tipo=$2 }
      /^[[:space:]]*Speed:/ { if ($2 != "Unknown") vel=$2 }
      /^[[:space:]]*Form Factor:/ { forma=$NF; if (forma == "Other") forma="-" }
      /^[[:space:]]*Manufacturer:/ { fab=$NF; if ($0 ~ /No Module Installed/ || fab == "Other") fab="-" }
      END { if (contado) printf "%-12s %-12s %-10s %-8s %-8s %-10s\n", slot, size, tipo, vel, forma, fab }
    '
  else
    printf 'Slot info NOT available without sudo/dmidecode.\n'
  fi
}

# --- Text output: GPU -------------------------------------------------------
info_gpu() {
  encabezado "GRAPHICS CARD"
  if [ "$HAVE_LSPCI" -eq 1 ]; then
    lspci -nnk | grep -E "$gpu_class" -A 3
  else
    echo "lspci not available"
  fi
}

# --- Text output: Disks -----------------------------------------------------
info_discos() {
  encabezado "DISKS"
  if [ "$HAVE_LSBLK" -eq 1 ]; then
    printf '%-8s %-5s %-12s %-12s %-6s %s\n' "DISK" "TYPE" "SIZE" "CONNECTION" "ROT" "MODEL"
    while read -r name rot size_bytes tran type; do
      model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null)
      if [ "$rot" = "0" ]; then
        tipo="SSD"
      elif [ "$rot" = "1" ]; then
        tipo="HDD"
      else
        tipo="$type"
      fi
      case "$tran" in
        sata) tran_txt="SATA" ;;
        usb)  tran_txt="USB" ;;
        nvme) tran_txt="NVMe" ;;
        "")   tran_txt="-" ;;
        *)    tran_txt="$tran" ;;
      esac
      printf '%-8s %-5s %-12s %-12s %-6s %s\n' "/dev/$name" "$tipo" "$(human_bytes "$size_bytes")" "$tran_txt" "$rot" "$model"
    done < <(lsblk -dn -b -o NAME,ROTA,SIZE,TRAN,TYPE 2>/dev/null)
    echo
    echo "Partitions:"
    lsblk -l -o NAME,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null
  fi
  if [ "$HAVE_LSHW" -eq 1 ]; then
    echo
    sudo_o lshw -class disk -class storage 2>/dev/null | grep -E 'description:|product:|vendor:|logical name:|size:|bus info:' | sed 's/^ *//'
  fi
}

# --- Text output: Network ---------------------------------------------------
info_red() {
  encabezado "NETWORK"
  if [ "$HAVE_LSPCI" -eq 1 ]; then
    lspci | grep -Ei 'network|ethernet|wireless'
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo
  fi
}

# --- Text output: BIOS ------------------------------------------------------
info_bios() {
  encabezado "BIOS / FIRMWARE"
  if [ -n "$DMI" ] && [ "$PRIV" -eq 1 ]; then
    sudo_o "$DMI" -t bios 2>/dev/null | grep -E 'Vendor:|Version:|Release Date:' | sed 's/^[[:space:]]*//'
  else
    ls /sys/class/dmi/id/ 2>/dev/null | grep -Ei 'bios|board' | while read -r f; do
      [ -r "/sys/class/dmi/id/$f" ] && printf '%s: %s\n' "$f" "$(cat "/sys/class/dmi/id/$f")"
    done
  fi
}

# --- Text output: SMART health ----------------------------------------------
info_smart() {
  encabezado "DISK HEALTH (SMART)"
  if [ "$HAVE_SMARTCTL" -eq 0 ]; then
    echo "smartctl not installed."
    echo "  Install smartmontools to get disk health:  sudo apt install smartmontools"
    echo "  (Optional: the inventory works without it.)"
    return
  fi
  if [ "$PRIV" -eq 0 ]; then
    echo "SMART data requires root. Re-run with sudo."
    return
  fi
  if [ "$HAVE_LSBLK" -eq 1 ]; then
    while read -r name; do
      [ -b "/dev/$name" ] || continue
      local health temp
      health=$(sudo_o smartctl -H "/dev/$name" 2>/dev/null | grep -i 'overall-health' | sed 's/^[[:space:]]*//; s/.*: //')
      temp=$(sudo_o smartctl -A "/dev/$name" 2>/dev/null | awk '/Temperature_Celsius/{print $10}')
      [ -z "$temp" ] && temp=$(sudo_o smartctl -A "/dev/$name" 2>/dev/null | awk '/Airflow_Temperature_Cel/{print $10}')
      printf '%-10s %-10s %s C\n' "/dev/$name" "${health:-n/a}" "${temp:-n/a}"
    done < <(lsblk -dn -o NAME 2>/dev/null)
  fi
}

# --- JSON output ------------------------------------------------------------
json_emit() {
  local dmi16="" dmi17=""
  if [ -n "$DMI" ] && [ "$PRIV" -eq 1 ]; then
    dmi16=$(sudo_o "$DMI" -t 16 2>/dev/null)
    dmi17=$(sudo_o "$DMI" -t 17 2>/dev/null)
  fi

  # system
  printf '{\n'
  printf '  "tool": "hardware-inventory",\n'
  printf '  "generated_at": %s,\n' "$(json_str "$(date -Is 2>/dev/null || date)")"
  printf '  "host": %s,\n' "$(json_str "$HOSTNAME")"
  printf '  "machine_id": %s,\n' "$(json_val "$MACHINE_ID")"
  printf '  "system": {\n'
  printf '    "os": %s,\n'     "$(json_str "$OS_NAME $OS_VERSION")"
  printf '    "kernel": %s,\n' "$(json_str "$(uname -srm 2>/dev/null)")"
  printf '    "manufacturer": %s,\n' "$(json_str "$(dmi_file sys_vendor)")"
  printf '    "product": %s,\n'      "$(json_str "$(dmi_file product_name)")"
  printf '    "product_version": %s,\n' "$(json_str "$(dmi_file product_version)")"
  printf '    "board": %s,\n'        "$(json_str "$(dmi_file board_name)")"
  printf '    "serial": %s\n'        "$(json_str "$(dmi_file product_serial)")"
  printf '  },\n'

  # cpu
  local cpu_model="" cpu_arch="" cpu_cores="" cpu_threads="" cpu_sockets="" cpu_min="" cpu_max="" cpu_vendor=""
  while IFS= read -r line; do
    case "$line" in
      "Model name:"*)            cpu_model=$(trim "${line#*:}") ;;
      "Architecture:"*)          cpu_arch=$(trim "${line#*:}") ;;
      "CPU(s):"*)                cpu_cores=$(trim "${line#*:}") ;;
      "Thread(s) per core:"*)    cpu_threads=$(trim "${line#*:}") ;;
      "Socket(s):"*)             cpu_sockets=$(trim "${line#*:}") ;;
      "CPU min MHz:"*)           cpu_min=$(trim "${line#*:}") ;;
      "CPU max MHz:"*)           cpu_max=$(trim "${line#*:}") ;;
      "Vendor ID:"*)             cpu_vendor=$(trim "${line#*:}") ;;
    esac
  done < <(lscpu 2>/dev/null)
  printf '  "cpu": {\n'
  printf '    "vendor": %s,\n'    "$(json_str "$cpu_vendor")"
  printf '    "model": %s,\n'     "$(json_str "$cpu_model")"
  printf '    "architecture": %s,\n' "$(json_str "$cpu_arch")"
  printf '    "cores": %s,\n'     "$(json_str "$cpu_cores")"
  printf '    "threads_per_core": %s,\n' "$(json_str "$cpu_threads")"
  printf '    "sockets": %s,\n'   "$(json_str "$cpu_sockets")"
  printf '    "min_mhz": %s,\n'   "$(json_str "$cpu_min")"
  printf '    "max_mhz": %s\n'    "$(json_str "$cpu_max")"
  printf '  },\n'

  # memory
  local maxcap
  maxcap=$(echo "$dmi16" | grep -i 'Maximum Capacity' | sed 's/^[[:space:]]*//' | sed 's/Maximum Capacity:[[:space:]]*//')
  printf '  "memory": {\n'
  printf '    "total": %s,\n' "$(json_str "$(human_bytes "$RAM_TOTAL_BYTES")")"
  printf '    "total_bytes": %s,\n' "$RAM_TOTAL_BYTES"
  printf '    "max_capacity": %s,\n' "$(json_val "$maxcap")"
  printf '    "max_capacity_bytes": %s,\n' "$(json_num "$(parse_bytes "$maxcap")")"
  printf '    "slots_count": %s,\n'  "$(json_val "$(echo "$dmi16" | grep -i 'Number Of Devices' | sed 's/^[[:space:]]*//' | sed 's/Number Of Devices:[[:space:]]*//')")"
  printf '    "modules": [\n'
  local first=1 slot size tipo vel forma fab
  while IFS='|' read -r slot size tipo vel forma fab; do
    [ -z "$slot" ] && continue
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '      {\n'
    printf '        "slot": %s,\n' "$(json_str "$slot")"
    printf '        "size": %s,\n' "$(json_val "$size")"
    printf '        "size_bytes": %s,\n' "$(json_num "$(parse_bytes "$size")")"
    printf '        "type": %s,\n' "$(json_val "$tipo")"
    printf '        "speed": %s,\n' "$(json_val "$vel")"
    printf '        "form_factor": %s,\n' "$(json_val "$forma")"
    printf '        "manufacturer": %s\n' "$(json_val "$fab")"
    printf '      }'
  done < <(echo "$dmi17" | awk '
    /DMI type 17/ {
      if (c) printf "%s|%s|%s|%s|%s|%s\n", slot, size, tipo, vel, forma, fab
      slot=""; size=""; tipo=""; vel=""; forma=""; fab=""; c=1
    }
    /^[[:space:]]*Locator:/ { slot=$NF }
    /^[[:space:]]*Size:/ { size=$2" "$3; if ($0 ~ /No Module/) size="" }
    /^[[:space:]]*Type:/ { if ($2 != "Unknown") tipo=$2 }
    /^[[:space:]]*Speed:/ { if ($2 != "Unknown") vel=$2 }
    /^[[:space:]]*Form Factor:/ { forma=$NF; if (forma == "Other") forma="" }
    /^[[:space:]]*Manufacturer:/ { fab=$NF; if ($0 ~ /No Module Installed/ || fab == "Other") fab="" }
    END { if (c) printf "%s|%s|%s|%s|%s|%s\n", slot, size, tipo, vel, forma, fab }
  ')
  printf '\n    ]\n'
  printf '  },\n'

  # gpu
  printf '  "gpu": [\n'
  local first=1 dev driver
  while IFS='|' read -r dev driver; do
    [ -z "$dev" ] && continue
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    {"device": %s, "driver": %s}' "$(json_str "$dev")" "$(json_val "$driver")"
  done < <(lspci -nnk 2>/dev/null | awk -v re="$gpu_class" '
    function flush() { if (dev != "" && active) print dev "|" driver }
    /^[[:space:]]/ {
      if (active && /Kernel driver in use:/) driver=$5
      next
    }
    {
      flush()
      dev=$0; driver=""
      active = ($0 ~ re)
    }
    END { flush() }
  ')
  printf '\n  ],\n'

  # disks
  printf '  "disks": [\n'
  local first=1 name rot size_bytes tran type model tipo tran_txt
  while read -r name rot size_bytes tran type; do
    model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null)
    if [ "$rot" = "0" ]; then
      tipo="SSD"
    elif [ "$rot" = "1" ]; then
      tipo="HDD"
    else
      tipo="$type"
    fi
    case "$tran" in
      sata) tran_txt="SATA" ;;
      usb)  tran_txt="USB" ;;
      nvme) tran_txt="NVMe" ;;
      "")   tran_txt="" ;;
      *)    tran_txt="$tran" ;;
    esac
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    {"name": %s, "type": %s, "size": %s, "size_bytes": %s, "connection": %s, "rotational": %s, "model": %s}' \
      "$(json_str "/dev/$name")" "$(json_str "$tipo")" "$(json_str "$(human_bytes "$size_bytes")")" \
      "$size_bytes" "$(json_str "$tran_txt")" "$rot" "$(json_str "$model")"
  done < <(lsblk -dn -b -o NAME,ROTA,SIZE,TRAN,TYPE 2>/dev/null)
  printf '\n  ],\n'

  # partitions
  printf '  "partitions": [\n'
  local first=1
  while read -r pname psize_bytes pfstype pmount; do
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    {"name": %s, "size": %s, "size_bytes": %s, "fstype": %s, "mountpoint": %s}' \
      "$(json_str "$pname")" "$(json_str "$(human_bytes "$psize_bytes")")" \
      "$psize_bytes" "$(json_val "$pfstype")" "$(json_val "$pmount")"
  done < <(lsblk -n -l -b -o NAME,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null)
  printf '\n  ],\n'

  # network
  printf '  "network": [\n'
  local first=1 iface
  while read -r iface; do
    [ -z "$iface" ] && continue
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    %s' "$(json_str "$iface")"
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$')
  printf '\n  ],\n'

  # bios
  printf '  "bios": {\n'
  printf '    "vendor": %s,\n' "$(json_str "$(dmi_file bios_vendor)")"
  printf '    "version": %s,\n' "$(json_str "$(dmi_file bios_version)")"
  printf '    "release_date": %s\n' "$(json_str "$(dmi_file bios_date)")"
  printf '  },\n'

  # smart (only when enabled with -s)
  printf '  "smart": [\n'
  local first=1
  if [ "$SMART" -eq 1 ] && [ "$HAVE_SMARTCTL" -eq 1 ] && [ "$PRIV" -eq 1 ] && [ "$HAVE_LSBLK" -eq 1 ]; then
    while read -r name; do
      [ -b "/dev/$name" ] || continue
      local health temp
      health=$(sudo_o smartctl -H "/dev/$name" 2>/dev/null | grep -i 'overall-health' | sed 's/^[[:space:]]*//; s/.*: //')
      temp=$(sudo_o smartctl -A "/dev/$name" 2>/dev/null | awk '/Temperature_Celsius/{print $10}')
      [ -z "$temp" ] && temp=$(sudo_o smartctl -A "/dev/$name" 2>/dev/null | awk '/Airflow_Temperature_Cel/{print $10}')
      if [ "$first" -eq 0 ]; then printf ',\n'; fi
      first=0
      printf '    {"device": %s, "health": %s, "temperature": %s}' \
        "$(json_str "/dev/$name")" "$(json_val "$health")" "$(json_val "$temp")"
    done < <(lsblk -dn -o NAME 2>/dev/null)
  fi
  printf '\n  ]\n'

  printf '}\n'
}

# --- Main -------------------------------------------------------------------
uso() {
  cat <<'EOF'
Usage: sudo ./hardware-inventory.sh [-o file] [-j] [-s] [-h]

  -o file    Saves the text inventory to "file-<date>-<host>.txt"
             instead of printing to screen
  -j         Prints the inventory as JSON to the screen. To save it
             to a file, pipe it:  ./hardware-inventory.sh -j > out.json
  -s         Enables the SMART disk health section (slower). Off by
             default for a quick run
  -h         Shows this help

Run it with sudo to get the complete info (RAM slots, max capacity,
disk model, BIOS, SMART). Without sudo the output is partial.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUTFILE=$2; shift 2 ;;
    -j) JSON=1; shift ;;
    -s) SMART=1; shift ;;
    -h) uso; exit 0 ;;
    *) uso; exit 1 ;;
  esac
done

# --- Tools check ------------------------------------------------------------
check_tools() {
  echo "=== Tools check ==="
  printf '%-14s %s\n' "lscpu"      "$([ "$HAVE_LSCPU" -eq 1 ] && echo OK || echo "missing")"
  printf '%-14s %s\n' "lspci"      "$([ "$HAVE_LSPCI" -eq 1 ] && echo OK || echo "missing")"
  printf '%-14s %s\n' "lsblk"      "$([ "$HAVE_LSBLK" -eq 1 ] && echo OK || echo "missing")"
  printf '%-14s %s\n' "lshw"       "$([ "$HAVE_LSHW" -eq 1 ] && echo "OK (optional)" || echo "missing (optional)")"
  printf '%-14s %s\n' "dmidecode"  "$([ -n "$DMI" ] && echo "OK (optional)" || echo "missing (optional)")"
  printf '%-14s %s\n' "smartctl"   "$([ "$HAVE_SMARTCTL" -eq 1 ] && echo "OK (optional)" || echo "missing (optional)")"
  echo
  echo "  For the complete info install the missing tools:"
  echo "    sudo apt install smartmontools lshw dmidecode pciutils"
  echo
}

detectar_priv
if [ "$PRIV" -eq 0 ]; then
  {
    echo "[!] Not running as root: RAM slots, max capacity, BIOS and SMART will be incomplete."
    echo "    Run with: sudo $0 $*"
    echo
  } >&2
fi

# Machine UUID: stable ID for the organizer to track each machine.
MACHINE_ID=$(dmi_file product_uuid)

if [ "$JSON" -eq 0 ]; then
  check_tools
fi

if [ -n "$OUTFILE" ]; then
  OUT="$OUTFILE-$FECHA-$HOSTNAME.txt"
else
  OUT=""
fi

if [ "$JSON" -eq 1 ]; then
  json_emit
  exit 0
fi

if [ -n "$OUT" ]; then
  {
    info_sistema
    info_cpu
    info_ram
    info_gpu
    info_discos
    info_red
    info_bios
    [ "$SMART" -eq 1 ] && info_smart
  } | tee "$OUT"
  echo
  echo "Inventory saved to: $OUT"
else
  info_sistema
  info_cpu
  info_ram
  info_gpu
  info_discos
  info_red
  info_bios
  [ "$SMART" -eq 1 ] && info_smart
fi
