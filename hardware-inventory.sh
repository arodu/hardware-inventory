#!/usr/bin/env bash
#
# hardware-inventory.sh
# Generates a full hardware inventory of the machine.
# Meant to be run on every computer (even from a live USB).
#
# Usage:
#   ./hardware-inventory.sh                 # prints to screen
#   ./hardware-inventory.sh -o inventory    # saves text to inventory-<date>-<host>.txt
#   ./hardware-inventory.sh -j              # also saves JSON to <base>-<date>-<host>.json
#   ./hardware-inventory.sh -h              # shows help
#
# Recommended to run with sudo to see all the info (RAM slots, disks, etc.)

set -u

OUTFILE=""
JSON=0
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
HAVE_LSHW=0;  command -v lshw    >/dev/null 2>&1 && HAVE_LSHW=1
HAVE_LSPCI=0; command -v lspci   >/dev/null 2>&1 && HAVE_LSPCI=1
HAVE_LSCPU=0; command -v lscpu   >/dev/null 2>&1 && HAVE_LSCPU=1
HAVE_UNAME=0; command -v uname   >/dev/null 2>&1 && HAVE_UNAME=1

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
  elif [ -n "$DMI" ] && sudo -n true >/dev/null 2>&1; then
    PRIV=1
  else
    PRIV=0
  fi
}

sudo_o() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

# --- JSON helpers -----------------------------------------------------------
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
json_str() { printf '"%s"' "$(esc "$1")"; }
json_val() { if [ -z "$1" ]; then printf 'null'; else json_str "$1"; fi; }
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
gpu_class='\[0300\]|\[0302\]|\[0380\]'

dmi_file() { [ -r "/sys/class/dmi/id/$1" ] && cat "/sys/class/dmi/id/$1"; }

# --- Text output: System ----------------------------------------------------
info_sistema() {
  encabezado "SYSTEM"
  [ "$HAVE_UNAME" -eq 1 ] && printf 'Kernel: %s\n' "$(uname -srm)"
  if [ -n "$OS_NAME" ]; then
    printf 'OS:     %s %s\n' "$OS_NAME" "$OS_VERSION"
  fi
  printf 'Host:   %s\n' "$HOSTNAME"

  if [ "$HAVE_LSHW" -eq 1 ]; then
    local sys
    sys=$(sudo_o lshw -class system 2>/dev/null)
    printf '%s\n' "$sys" | grep -E 'description:|product:|vendor:|version:|serial:|configuration:' | sed 's/^ *//'
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
  if [ -n "$DMI" ] && [ "$PRIV" -eq 1 ]; then
    local dmi16 dmi17
    dmi16=$(sudo_o "$DMI" -t 16 2>/dev/null)
    dmi17=$(sudo_o "$DMI" -t 17 2>/dev/null)
    printf 'Max capacity: %s\n' "$(echo "$dmi16" | grep -i 'Maximum Capacity' | sed 's/^[[:space:]]*//')"
    printf 'Slots count:  %s\n' "$(echo "$dmi16" | grep -i 'Number Of Devices' | sed 's/^[[:space:]]*//')"
    printf 'Total RAM:    %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
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
      /^[[:space:]]*Form Factor:/ { forma=$NF }
      /^[[:space:]]*Manufacturer:/ { fab=$NF; if ($0 ~ /No Module Installed/) fab="-" }
      END { if (contado) printf "%-12s %-12s %-10s %-8s %-8s %-10s\n", slot, size, tipo, vel, forma, fab }
    '
  else
    printf 'Total RAM: %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
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
  if command -v lsblk >/dev/null 2>&1; then
    printf '%-6s %-5s %-10s %-12s %-6s %s\n' "DISK" "TYPE" "SIZE" "CONNECTION" "ROT" "MODEL"
    while read -r name rot size tran type; do
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
      printf '%-6s %-5s %-10s %-12s %-6s %s\n' "/dev/$name" "$tipo" "$size" "$tran_txt" "$rot" "$model"
    done < <(lsblk -dn -o NAME,ROTA,SIZE,TRAN,TYPE 2>/dev/null)
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
  printf '  "system": {\n'
  printf '    "os": %s,\n'     "$(json_str "$OS_NAME $OS_VERSION")"
  printf '    "kernel": %s,\n' "$(json_str "$(uname -srm 2>/dev/null)")"
  printf '    "manufacturer": %s,\n' "$(json_str "$(dmi_file system_vendor)")"
  printf '    "product": %s,\n'      "$(json_str "$(dmi_file product_name)")"
  printf '    "product_version": %s,\n' "$(json_str "$(dmi_file product_version)")"
  printf '    "board": %s,\n'        "$(json_str "$(dmi_file board_name)")"
  printf '    "serial": %s\n'        "$(json_str "$(dmi_file system_serial)")"
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
  printf '  "memory": {\n'
  printf '    "total": %s,\n' "$(json_str "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')")"
  printf '    "max_capacity": %s,\n' "$(json_str "$(echo "$dmi16" | grep -i 'Maximum Capacity' | sed 's/^[[:space:]]*//' | sed 's/Maximum Capacity://')")"
  printf '    "slots_count": %s,\n'  "$(json_str "$(echo "$dmi16" | grep -i 'Number Of Devices' | sed 's/^[[:space:]]*//' | sed 's/Number Of Devices://')")"
  printf '    "modules": [\n'
  local first=1 slot size tipo vel forma fab
  while IFS=$'\t' read -r slot size tipo vel forma fab; do
    [ -z "$slot" ] && continue
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '      {\n'
    printf '        "slot": %s,\n' "$(json_str "$slot")"
    printf '        "size": %s,\n' "$(json_val "$size")"
    printf '        "type": %s,\n' "$(json_val "$tipo")"
    printf '        "speed": %s,\n' "$(json_val "$vel")"
    printf '        "form_factor": %s,\n' "$(json_str "$forma")"
    printf '        "manufacturer": %s\n' "$(json_val "$fab")"
    printf '      }'
  done < <(echo "$dmi17" | awk '
    /DMI type 17/ {
      if (c) printf "%s\t%s\t%s\t%s\t%s\t%s\n", slot, size, tipo, vel, forma, fab
      slot=""; size=""; tipo=""; vel=""; forma=""; fab=""; c=1
    }
    /^[[:space:]]*Locator:/ { slot=$NF }
    /^[[:space:]]*Size:/ { size=$2" "$3; if ($0 ~ /No Module/) size="" }
    /^[[:space:]]*Type:/ { if ($2 != "Unknown") tipo=$2 }
    /^[[:space:]]*Speed:/ { if ($2 != "Unknown") vel=$2 }
    /^[[:space:]]*Form Factor:/ { forma=$NF }
    /^[[:space:]]*Manufacturer:/ { fab=$NF; if ($0 ~ /No Module Installed/) fab="" }
    END { if (c) printf "%s\t%s\t%s\t%s\t%s\t%s\n", slot, size, tipo, vel, forma, fab }
  ')
  printf '\n    ]\n'
  printf '  },\n'

  # gpu
  printf '  "gpu": [\n'
  local first=1 dev driver
  while IFS=$'\t' read -r dev driver; do
    [ -z "$dev" ] && continue
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    {"device": %s, "driver": %s}' "$(json_str "$dev")" "$(json_val "$driver")"
  done < <(lspci -nnk 2>/dev/null | awk -v re="$gpu_class" '
    function flush() { if (dev != "" && active) print dev "\t" driver }
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
  local first=1 name rot size tran type model tipo tran_txt
  while read -r name rot size tran type; do
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
    printf '    {"name": %s, "type": %s, "size": %s, "connection": %s, "rotational": %s, "model": %s}' \
      "$(json_str "/dev/$name")" "$(json_str "$tipo")" "$(json_str "$size")" \
      "$(json_str "$tran_txt")" "$rot" "$(json_str "$model")"
  done < <(lsblk -dn -o NAME,ROTA,SIZE,TRAN,TYPE 2>/dev/null)
  printf '\n  ],\n'

  # partitions
  printf '  "partitions": [\n'
  local first=1
  while read -r pname psize pfstype pmount; do
    if [ "$first" -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '    {"name": %s, "size": %s, "fstype": %s, "mountpoint": %s}' \
      "$(json_str "$pname")" "$(json_str "$psize")" \
      "$(json_val "$pfstype")" "$(json_val "$pmount")"
  done < <(lsblk -n -l -o NAME,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null)
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
  printf '  }\n'

  printf '}\n'
}

# --- Main -------------------------------------------------------------------
uso() {
  cat <<'EOF'
Usage: hardware-inventory.sh [-o file] [-j] [-h]

  -o file   Saves the text inventory to "file-<date>-<host>.txt"
            instead of printing to screen
  -j        Also generates a JSON file "<base>-<date>-<host>.json"
            where <base> is the -o value or "hardware-inventory"
  -h        Shows this help

Recommendation: run with sudo to get the full info (RAM slots,
max capacity, disk model, BIOS...). Without sudo the output is partial.
EOF
}

while getopts "o:jh" opt; do
  case "$opt" in
    o) OUTFILE=$OPTARG ;;
    j) JSON=1 ;;
    h) uso; exit 0 ;;
    *) uso; exit 1 ;;
  esac
done

detectar_priv
if [ "$PRIV" -eq 0 ]; then
  echo "[!] No root permissions: RAM slots, BIOS and disk details will be incomplete."
  echo "    Re-run with: sudo $0 $*"
  echo
fi

if [ -n "$OUTFILE" ]; then
  OUT="$OUTFILE-$FECHA-$HOSTNAME.txt"
else
  OUT=""
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
fi

if [ "$JSON" -eq 1 ]; then
  if [ -n "$OUTFILE" ]; then
    JSON_FILE="$OUTFILE-$FECHA-$HOSTNAME.json"
  else
    JSON_FILE="hardware-inventory-$FECHA-$HOSTNAME.json"
  fi
  json_emit > "$JSON_FILE"
  echo
  echo "JSON saved to: $JSON_FILE"
fi
