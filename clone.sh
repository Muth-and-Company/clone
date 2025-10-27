#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

# Function to display usage
usage() {
  cat <<EOF
Usage: $0 [options] <source_drive> <destination_drive> [main_partition_size_in_GB]

Positional arguments:
  source_drive                 Drive to clone (e.g. /dev/sda)
  destination_drive            Drive to write clone to (e.g. /dev/sdb)
  main_partition_size_in_GB    (optional) Size in GB to resize main partition to

Options:
  --calc-only                  Calculate the optimal main partition size (GB) and print it, then exit
  --auto                       Calculate optimal size and use it for the resize (overrides provided size)
  -h, --help                   Show this help message

Examples:
  # Calculate optimal size and print it
  sudo $0 --calc-only /dev/sda /dev/sdb

  # Calculate and use optimal size for resize
  sudo $0 --auto /dev/sda /dev/sdb

  # Use an explicit size
  sudo $0 /dev/sda /dev/sdb 100
EOF
  exit 1
}

# Parse options and arguments
CALC_ONLY=false
AUTO=false
SOURCE_DRIVE=""
DEST_DRIVE=""
PARTITION_SIZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calc-only)
      CALC_ONLY=true; shift;;
    --auto)
      AUTO=true; shift;;
    -h|--help)
      usage;;
    --) shift; break;;
    -*)
      echo "Unknown option: $1"; usage;;
    *)
      if [[ -z "$SOURCE_DRIVE" ]]; then
        SOURCE_DRIVE=$1
      elif [[ -z "$DEST_DRIVE" ]]; then
        DEST_DRIVE=$1
      elif [[ -z "$PARTITION_SIZE" ]]; then
        PARTITION_SIZE=$1
      else
        echo "Too many arguments."; usage
      fi
      shift;;
  esac
done

if [[ -z "$SOURCE_DRIVE" || -z "$DEST_DRIVE" ]]; then
  usage
fi

# Helper to get partition path suffix (handles nvme/mmcblk naming)
get_part() {
  # get partition 1 of a drive in a safe way
  local drive="$1"
  if [[ "$drive" =~ nvme ]] || [[ "$drive" =~ mmcblk ]]; then
    echo "${drive}p1"
  else
    echo "${drive}1"
  fi
}

# Build a partition path for a drive and partition number
build_part() {
  local drive="$1"
  local num="$2"
  if [[ "$drive" =~ nvme ]] || [[ "$drive" =~ mmcblk ]]; then
    echo "${drive}p${num}"
  else
    echo "${drive}${num}"
  fi
}

# Calculate optimal size (GB) for main NTFS partition on source drive
calculate_optimal_gb() {
  local src_part
  # If SOURCE_DRIVE already points to a partition (e.g. /dev/nvme0n1p2 or /dev/sda1), use it
  if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
    src_part=$SOURCE_DRIVE
  else
    # Try to auto-detect an NTFS partition on the source drive using lsblk
    if command -v lsblk >/dev/null 2>&1; then
      detected=$(lsblk -nr -o NAME,FSTYPE "$SOURCE_DRIVE" 2>/dev/null | awk '$2 ~ /ntfs/ {print "/dev/" $1; exit}')
      if [[ -n "$detected" ]]; then
        src_part=$detected
      else
        # fallback to partition 1
        src_part=$(get_part "$SOURCE_DRIVE")
      fi
    else
      src_part=$(get_part "$SOURCE_DRIVE")
    fi
  fi

  if ! command -v ntfsresize >/dev/null 2>&1; then
    echo "ntfsresize is required to calculate optimal size but was not found." >&2
    return 1
  fi

  echo "Calculating optimal size for $src_part..." >&2
  # Try ntfsresize info output first
  local info
  info=$(ntfsresize --info -f "$src_part" 2>&1 || true)

  # Try to extract a byte count specifically (look for 'bytes')
  local bytes=""
  local line parsed num unit ss largest
  line=$(echo "$info" | grep -iE 'bytes' | head -n1 || true)
  if [[ -n "$line" ]]; then
    # use greedy .* to capture the large byte value (avoid non-greedy '?')
    parsed=$(echo "$line" | sed -nE 's/.*([0-9]+) ?bytes.*/\1/p' || true)
    if [[ -n "$parsed" ]]; then
      bytes=$parsed
    fi
  fi

  # If we didn't get a 'bytes' token, try to capture an explicit MB/GB token on the min line
  if [[ -z "$bytes" ]]; then
    line=$(echo "$info" | grep -iE 'minimum|estimated minimum|you might' | head -n1 || true)
    if [[ -n "$line" ]]; then
      parsed=$(echo "$line" | sed -nE 's/.*([0-9]+) ?([A-Za-z]+).*/\1 \2/p' || true)
      num=$(echo "$parsed" | awk '{print $1}' 2>/dev/null || echo "")
      unit=$(echo "$parsed" | awk '{print $2}' 2>/dev/null || echo "")
      unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')
      if [[ -n "$num" ]]; then
        case "$unit" in
          sector*|sectors)
            ss=$(blockdev --getss "$src_part" 2>/dev/null || blockdev --getss "${SOURCE_DRIVE}" 2>/dev/null || echo 512)
            bytes=$(awk "BEGIN{printf \"%d\", $num * $ss}")
            ;;
          byte*|bytes|b)
            bytes=$num
            ;;
          kb|k|kbyte|kbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024}")
            ;;
          mb|m|mbyte|mbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024 * 1024}")
            ;;
          gb|g|gbyte|gbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024 * 1024 * 1024}")
            ;;
          *)
            bytes=$num
            ;;
        esac
      fi
    fi
  fi

  # fallback: pick the largest numeric token from ntfsresize output
  if [[ -z "$bytes" || "$bytes" -lt 1073741824 ]]; then
    largest=$(echo "$info" | grep -oE '[0-9]+' | awk '{ if($1>m) m=$1 } END{print m+0}' )
    if [[ -n "$largest" && "$largest" -gt 0 ]]; then
      # If largest looks small (likely sectors), try to convert using sector size
      if [[ "$largest" -lt 1000000 ]]; then
        ss=$(blockdev --getss "$src_part" 2>/dev/null || blockdev --getss "${SOURCE_DRIVE}" 2>/dev/null || echo 512)
        bytes=$(awk "BEGIN{printf \"%d\", $largest * $ss}")
      else
        bytes=$largest
      fi
    fi
  fi

  if [[ -n "$bytes" && "$bytes" -gt 0 ]]; then
    # expose bytes globally so caller can compute sector-aligned partition end
    CALC_BYTES=$bytes
    # Convert bytes -> GB (float), add margin (5% or 1 GB min), ceil to integer
    local min_gb margin_gb optimal_gb
    min_gb=$(awk "BEGIN{printf \"%f\", $bytes/1024/1024/1024}")
    margin_gb=$(awk "BEGIN{m=$min_gb*0.05; if(m<1) m=1; printf \"%f\", m}")
    optimal_gb=$(awk "BEGIN{printf \"%d\", int($min_gb + $margin_gb + 0.999999)}")
    echo "$optimal_gb"
    return 0
  fi

  # Last-resort: mount read-only and measure used bytes (may fail if in use)
  local tmp used_bytes min_gb2 margin_gb2 opt2
  tmp=$(mktemp -d)
  if mount -o ro "$src_part" "$tmp" 2>/dev/null; then
    used_bytes=$(du -s --block-size=1 "$tmp" 2>/dev/null | awk '{print $1}')
    umount "$tmp" >/dev/null 2>&1 || true
    rmdir "$tmp" >/dev/null 2>&1 || true
    if [[ -n "$used_bytes" && "$used_bytes" -gt 0 ]]; then
      min_gb2=$(awk "BEGIN{printf \"%f\", $used_bytes/1024/1024/1024}")
      margin_gb2=$(awk "BEGIN{m=$min_gb2*0.05; if(m<1) m=1; printf \"%f\", m}")
      opt2=$(awk "BEGIN{printf \"%d\", int($min_gb2 + $margin_gb2 + 0.999999)}")
      echo "$opt2"
      return 0
    fi
  else
    rmdir "$tmp" >/dev/null 2>&1 || true
  fi

  echo "Unable to calculate optimal size for $src_part." >&2
  return 1
}

# If requested, calculate and print size, or calculate and use it
if [[ "$CALC_ONLY" == true ]]; then
  if optimal=$(calculate_optimal_gb); then
    echo "$optimal"
    exit 0
  else
    echo "Failed to calculate optimal size." >&2
    exit 2
  fi
fi

if [[ "$AUTO" == true ]]; then
  optimal=$(calculate_optimal_gb) || { echo "Failed to calculate optimal size." >&2; exit 2; }
  PARTITION_SIZE=$optimal
  echo "Using calculated partition size: ${PARTITION_SIZE}GB"
fi

if [[ -z "$PARTITION_SIZE" ]]; then
  echo "Main partition size (GB) not provided. Use --calc-only, --auto, or pass a size." >&2
  usage
fi

# Confirm the drives
echo "Source Drive: $SOURCE_DRIVE"
echo "Destination Drive: $DEST_DRIVE"
echo "Main Partition Size: ${PARTITION_SIZE}GB"
read -p "Are these details correct? (y/n): " CONFIRM
if [[ $CONFIRM != "y" ]]; then
  echo "Aborting."
  exit 1
fi

# Clone the partition table using dd
echo "Cloning partition table from $SOURCE_DRIVE to $DEST_DRIVE..."
dd if=$SOURCE_DRIVE of=$DEST_DRIVE bs=512 count=1 conv=notrunc

# Use ntfsclone to clone the NTFS partition
echo "Cloning NTFS partition..."
# Determine partition number and construct matching partition paths
PART_NUM=""
if [[ "$SOURCE_DRIVE" =~ ([0-9]+)$ ]]; then
  PART_NUM="${BASH_REMATCH[1]}"
fi

if [[ -n "$PART_NUM" && -b "$SOURCE_DRIVE" ]]; then
  # user passed a partition path (e.g. /dev/nvme0n1p2 or /dev/sda2)
  SOURCE_PARTITION="$SOURCE_DRIVE"
else
  # default to partition 1 or try to detect NTFS partition
  if command -v lsblk >/dev/null 2>&1; then
    detected=$(lsblk -nr -o NAME,FSTYPE "$SOURCE_DRIVE" 2>/dev/null | awk '$2 ~ /ntfs/ {print "/dev/" $1; exit}')
    if [[ -n "$detected" ]]; then
      SOURCE_PARTITION=$detected
      if [[ "$detected" =~ ([0-9]+)$ ]]; then PART_NUM="${BASH_REMATCH[1]}"; fi
    else
      PART_NUM=1
      SOURCE_PARTITION=$(build_part "$SOURCE_DRIVE" "$PART_NUM")
    fi
  else
    PART_NUM=1
    SOURCE_PARTITION=$(build_part "$SOURCE_DRIVE" "$PART_NUM")
  fi
fi

# Build destination partition path using same partition number
DEST_PARTITION=$(build_part "$DEST_DRIVE" "$PART_NUM")

# Confirm the drives
echo "Source Drive: $SOURCE_DRIVE"
echo "Source Partition: $SOURCE_PARTITION"
echo "Destination Drive: $DEST_DRIVE"
echo "Destination Partition: $DEST_PARTITION"
echo "Main Partition Size: ${PARTITION_SIZE}GB"
read -p "Are these details correct? (y/n): " CONFIRM
if [[ $CONFIRM != "y" ]]; then
  echo "Aborting."
  exit 1
fi

# Clone the partition table using dd
echo "Cloning partition table from $SOURCE_DRIVE to $DEST_DRIVE..."
dd if=$SOURCE_DRIVE of=$DEST_DRIVE bs=512 count=1 conv=notrunc

# Use ntfsclone to clone the NTFS partition
echo "Cloning NTFS partition..."
ntfsclone --overwrite "$DEST_PARTITION" "$SOURCE_PARTITION"


# Resize the destination partition
echo "Resizing the destination partition to ${PARTITION_SIZE}GB..."
# If we have a precise byte count from ntfsresize parsing, compute an end sector
if [[ -n "$CALC_BYTES" && "$CALC_BYTES" -gt 0 ]]; then
  echo "Using precise byte count from ntfsresize: $CALC_BYTES bytes" >&2
  # Add margin: 5% or minimum 1 GiB
  margin_bytes=$(awk "BEGIN{m=$CALC_BYTES*0.05; if(m<1073741824) m=1073741824; printf \"%d\", m}")
  total_bytes=$(awk "BEGIN{printf \"%d\", $CALC_BYTES + $margin_bytes}")

  # sector size (bytes)
  sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)

  # start sector of the partition on destination drive (use PART_NUM)
  part_line=$((PART_NUM + 1))
  start_sector=$(parted -ms "$DEST_DRIVE" unit s print | awk -F: -v ln="$part_line" 'NR==ln{print $2}')
  if [[ -z "$start_sector" ]]; then
    echo "Failed to determine start sector for ${DEST_DRIVE} - falling back to GB-based resize" >&2
    parted "$DEST_DRIVE" resizepart 1 ${PARTITION_SIZE}GB
  else
    # compute needed sectors and end sector
    needed_sectors=$(awk "BEGIN{printf \"%d\", int( ($total_bytes + $sector_size - 1) / $sector_size )}")
    end_sector=$(awk "BEGIN{printf \"%d\", $start_sector + $needed_sectors - 1}")
    echo "Resizing partition 1 to end at sector $end_sector (unit: sectors)" >&2
    parted -s "$DEST_DRIVE" unit s resizepart 1 $end_sector || {
      echo "Sector-based resize failed; trying GB-based resize as fallback." >&2
      parted "$DEST_DRIVE" resizepart 1 ${PARTITION_SIZE}GB
    }
  fi
else
  # parted uses partition number (1), not partition path
  parted "$DEST_DRIVE" resizepart 1 ${PARTITION_SIZE}GB
fi

# Resize the NTFS filesystem
echo "Resizing the NTFS filesystem on the destination partition..."
ntfsresize "$DEST_PARTITION"

echo "Cloning and resizing complete!"