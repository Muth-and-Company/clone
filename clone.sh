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
  --recreate                   Recreate destination partition layout and clone partitions (safe automated)
  --fill                       Fill the destination disk (use available space) when calculating recommended size
  --dry-run                    Show detailed calculation and recommended values without changing disks
  -h, --help                   Show this help message

Examples:
  # Calculate optimal size and print it
  sudo $0 --calc-only /dev/sda /dev/sdb

  # Calculate optimal size to fill the destination (use most of dest disk)
  sudo $0 --calc-only --fill /dev/sda /dev/nvme0n1

  # Calculate and use optimal size for resize
  sudo $0 --auto /dev/sda /dev/sdb

  # Calculate and use optimal size filling destination
  sudo $0 --auto --fill /dev/sda /dev/nvme0n1

  # Use an explicit size
  sudo $0 /dev/sda /dev/sdb 100
EOF
  exit 1
}

# Parse options and arguments
CALC_ONLY=false
AUTO=false
DRY_RUN=false
FILL=false
RECREATE=false
SOURCE_DRIVE=""
DEST_DRIVE=""
PARTITION_SIZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calc-only)
      CALC_ONLY=true; shift;;
    --auto)
      AUTO=true; shift;;
    --fill)
      FILL=true; shift;;
    --recreate)
      RECREATE=true; shift;;
    --dry-run)
      DRY_RUN=true; shift;;
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
    # Try to auto-detect the largest NTFS partition on the source drive using lsblk
    if command -v lsblk >/dev/null 2>&1; then
      detected=$(lsblk -bnr -o NAME,FSTYPE,SIZE "$SOURCE_DRIVE" 2>/dev/null | awk '$2=="ntfs"{print $1" "$3}' | sort -k2 -n | tail -n1)
      if [[ -n "$detected" ]]; then
        name=$(echo "$detected" | awk '{print $1}')
        src_part="/dev/$name"
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

  # Try to extract a byte count from the suggested resize line (preferred)
  local bytes=""
  local line parsed num unit ss largest
  line=$(echo "$info" | grep -iE 'you might resize at|you might resize|estimated minimum|minimum' | head -n1 || true)
  if [[ -n "$line" ]]; then
    parsed=$(echo "$line" | sed -nE 's/.*?([0-9]+) ?bytes.*/\1/p' || true)
    if [[ -n "$parsed" ]]; then
      bytes=$parsed
    else
      # try to capture MB/GB token on same line
      parsed=$(echo "$line" | sed -nE 's/.*([0-9]+) ?([A-Za-z]+).*/\1 \2/p' || true)
      num=$(echo "$parsed" | awk '{print $1}' 2>/dev/null || echo "")
      unit=$(echo "$parsed" | awk '{print $2}' 2>/dev/null || echo "")
      unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')
      if [[ -n "$num" ]]; then
        case "$unit" in
          kb|k|kbyte|kbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024}")
            ;;
          mb|m|mbyte|mbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024 * 1024}")
            ;;
          gb|g|gbyte|gbytes)
            bytes=$(awk "BEGIN{printf \"%d\", $num * 1024 * 1024 * 1024}")
            ;;
        esac
      fi
    fi
  fi

  # If we still didn't find a bytes token, fall back to the first bytes occurrence
  if [[ -z "$bytes" ]]; then
    line=$(echo "$info" | grep -iE 'bytes' | head -n1 || true)
    if [[ -n "$line" ]]; then
      parsed=$(echo "$line" | sed -nE 's/.*([0-9]+) ?bytes.*/\1/p' || true)
      if [[ -n "$parsed" ]]; then
        bytes=$parsed
      fi
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
    # Convert bytes -> GB (float), add margin (5% or 1 GB min), ceil to integer
    local min_gb margin_gb optimal_gb
    min_gb=$(awk "BEGIN{printf \"%f\", $bytes/1024/1024/1024}")
    margin_gb=$(awk "BEGIN{m=$min_gb*0.05; if(m<1) m=1; printf \"%f\", m}")
    optimal_gb=$(awk "BEGIN{printf \"%d\", int($min_gb + $margin_gb + 0.999999)}")
    # Output in the form bytes:gb so callers can parse both values (we cannot rely on global vars when using command substitution)
    echo "${bytes}:${optimal_gb}"
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
      echo "${used_bytes}:${opt2}"
      return 0
    fi
  else
    rmdir "$tmp" >/dev/null 2>&1 || true
  fi

  echo "Unable to calculate optimal size for $src_part." >&2
  return 1
}

# Compute recommended GB for destination: min(source-needed, destination-capacity)
compute_recommended_gb() {
  # Calculate source-needed GB and CALC_BYTES by parsing calculate_optimal_gb output (bytes:GB)
  out=$(calculate_optimal_gb) || return 1
  needed_bytes=$(echo "$out" | awk -F: '{print $1}')
  needed_gb=$(echo "$out" | awk -F: '{print $2}')
  # ensure numeric
  if [[ -z "$needed_bytes" || -z "$needed_gb" ]]; then
    echo "Failed to parse calculate_optimal_gb output: $out" >&2
    return 1
  fi
  # export CALC_BYTES for later sector math
  CALC_BYTES=$needed_bytes

  # Determine destination total bytes
  dest_bytes=""
  # Try parted header to get total sectors
  if command -v parted >/dev/null 2>&1; then
    header=$(parted -ms "$DEST_DRIVE" unit s print 2>/dev/null | head -n1 || true)
    if [[ -n "$header" ]]; then
      # header example: /dev/nvme0n1:1953525168s:... extract 2nd field
      total_sectors=$(echo "$header" | awk -F: '{print $2}' | sed 's/s$//')
      if [[ -n "$total_sectors" ]]; then
        sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)
        dest_bytes=$(awk "BEGIN{printf \"%d\", $total_sectors * $sector_size}")
      fi
    fi
  fi
  # Fallback to blockdev --getsize64
  if [[ -z "$dest_bytes" || "$dest_bytes" -le 0 ]]; then
    if command -v blockdev >/dev/null 2>&1; then
      dest_bytes=$(blockdev --getsize64 "$DEST_DRIVE" 2>/dev/null || echo "")
    fi
  fi
  if [[ -z "$dest_bytes" || "$dest_bytes" -le 0 ]]; then
    echo "Unable to determine destination disk capacity." >&2
    return 1
  fi

  # Compute GBs
  dest_gb=$(awk "BEGIN{printf \"%d\", int($dest_bytes/1024/1024/1024)}")
  needed_gb_int=$(awk "BEGIN{printf \"%d\", int($needed_gb)}")

  # If user requested filling the destination, compute available space after the partition start
  if [[ "$FILL" == true ]]; then
    # determine partition number on source (if user passed a partition path) or detect largest NTFS partition
    src_part_num=""
    src_part_name=""
    if [[ "$SOURCE_DRIVE" =~ ([0-9]+)$ ]]; then
      src_part_num="${BASH_REMATCH[1]}"
      src_part_name=$(basename "$SOURCE_DRIVE")
      # derive drive base (strip trailing partition number, handle nvme)
      if [[ "$SOURCE_DRIVE" =~ (.*p)[0-9]+$ ]]; then
        src_drive_base=${SOURCE_DRIVE%p${src_part_num}}
      else
        src_drive_base=${SOURCE_DRIVE%$src_part_num}
      fi
    else
      # detect largest NTFS partition name
      if command -v lsblk >/dev/null 2>&1; then
        detected=$(lsblk -bnr -o NAME,FSTYPE,SIZE "$SOURCE_DRIVE" 2>/dev/null | awk '$2=="ntfs"{print $1" "$3}' | sort -k2 -n | tail -n1)
        if [[ -n "$detected" ]]; then
          src_part_name=$(echo "$detected" | awk '{print $1}')
          if [[ "$src_part_name" =~ ([0-9]+)$ ]]; then src_part_num="${BASH_REMATCH[1]}"; fi
          # drive base is /dev/<name without trailing number or pN>
          src_drive_base="/dev/${src_part_name%${src_part_num}}"
        fi
      fi
    fi

    reserve_gb=1
    reserve_bytes=$(awk "BEGIN{printf \"%d\", $reserve_gb * 1024 * 1024 * 1024}")

    # default fallback: fill from sector 0 (full disk) minus reserve
    if [[ -z "$src_part_num" || -z "$src_drive_base" ]]; then
      recommended=$((dest_gb - reserve_gb))
      if [[ $recommended -lt 1 ]]; then recommended=1; fi
    else
      # get start sector of the source partition
      start_sector=$(parted -ms "$src_drive_base" unit s print 2>/dev/null | awk -F: -v ln="$((src_part_num+1))" 'NR==ln{print $2}')
      if [[ -z "$start_sector" ]]; then
        recommended=$((dest_gb - reserve_gb))
      else
        # compute start byte on dest using sector size
        sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)
        start_sector_num=$(echo "$start_sector" | sed 's/s$//')
        start_bytes=$(awk "BEGIN{printf \"%d\", $start_sector_num * $sector_size}")
        available_bytes=$(awk "BEGIN{printf \"%d\", $dest_bytes - $start_bytes - $reserve_bytes}")
        if [[ $available_bytes -lt 0 ]]; then
          recommended=1
        else
          recommended=$(awk "BEGIN{printf \"%d\", int($available_bytes/1024/1024/1024)}")
        fi
      fi
    fi
    # safety floor
    if [[ $recommended -gt $dest_gb ]]; then recommended=$dest_gb; fi
    if [[ $recommended -lt 1 ]]; then recommended=1; fi
    if [[ "$DRY_RUN" == true ]]; then
      echo "Fill mode: start_sector=$start_sector, start_bytes=${start_bytes:-0}, dest_bytes=$dest_bytes, reserve_bytes=$reserve_bytes" 
      echo "Recommended target (GB): $recommended"
    fi
    echo "$recommended"
    return 0
  fi

  # recommended is min(needed_gb_int, dest_gb)
  if [[ $needed_gb_int -gt $dest_gb ]]; then
    recommended=$dest_gb
  else
    recommended=$needed_gb_int
  fi

  # If dry-run, print details to stdout for easy capture
  if [[ "$DRY_RUN" == true ]]; then
    echo "Source needed (GB): $needed_gb_int"
    echo "Source needed (bytes): $needed_bytes"
    echo "Destination capacity (GB): $dest_gb"
    echo "Recommended target (GB): $recommended"
  fi

  echo "$recommended"
}

# Recreate destination partition layout and clone partitions safely.
# This automated mode supports a common 3-partition layout: p1 small, p2 main NTFS, p3 small.
recreate_and_clone() {
  echo "Running recreate-and-clone mode (safe automated)." >&2
  # Ensure we have needed values
  out=$(calculate_optimal_gb) || { echo "Failed to calculate optimal size." >&2; return 1; }
  needed_bytes=$(echo "$out" | awk -F: '{print $1}')
  needed_gb=$(echo "$out" | awk -F: '{print $2}')
  CALC_BYTES=$needed_bytes

  # Detect source drive base (strip partition number)
  if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
    src_drive_base=$(echo "$SOURCE_DRIVE" | sed -E 's/(p?[0-9]+)$//')
  else
    src_drive_base=$SOURCE_DRIVE
  fi

  # Read source partition table (ms machine-readable)
  src_map=$(parted -ms "$src_drive_base" unit s print 2>/dev/null)
  if [[ -z "$src_map" ]]; then
    echo "Failed to read source partition table." >&2
    return 1
  fi

  # Count partitions
  part_count=$(echo "$src_map" | wc -l)
  # parted -ms prints header + one line per partition, so parts = lines-1
  parts=$((part_count - 1))
  if [[ $parts -ne 3 ]]; then
    echo "Recreate mode currently supports a 3-partition source layout (p1/p2/p3). Detected $parts partitions." >&2
    return 1
  fi

  # Parse partition lines
  # header is line1; p1 line is NR==2, p2 NR==3, p3 NR==4
  p1_line=$(echo "$src_map" | sed -n '2p')
  p2_line=$(echo "$src_map" | sed -n '3p')
  p3_line=$(echo "$src_map" | sed -n '4p')

  p1_start=$(echo "$p1_line" | awk -F: '{print $2}' | sed 's/s$//')
  p1_end=$(echo "$p1_line" | awk -F: '{print $3}' | sed 's/s$//')
  p1_type=$(echo "$p1_line" | awk -F: '{print $6}')

  p2_start=$(echo "$p2_line" | awk -F: '{print $2}' | sed 's/s$//')
  p2_end_src=$(echo "$p2_line" | awk -F: '{print $3}' | sed 's/s$//')
  p2_type=$(echo "$p2_line" | awk -F: '{print $6}')

  p3_start=$(echo "$p3_line" | awk -F: '{print $2}' | sed 's/s$//')
  p3_end=$(echo "$p3_line" | awk -F: '{print $3}' | sed 's/s$//')
  p3_type=$(echo "$p3_line" | awk -F: '{print $6}')

  # Destination sizes
  dest_header=$(parted -ms "$DEST_DRIVE" unit s print 2>/dev/null | head -n1)
  dest_total_sectors=$(echo "$dest_header" | awk -F: '{print $2}' | sed 's/s$//')
  sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)

  # Compute needed sectors for p2
  needed_sectors=$(awk "BEGIN{printf \"%d\", int( ($CALC_BYTES + ($CALC_BYTES*0.05) + 1073741824 -1) / $sector_size )}")

  # compute p3 size in sectors
  p3_size=$((p3_end - p3_start + 1))

  # compute new p2_end so that p3 can sit after it
  new_p2_end=$(( dest_total_sectors - p3_size - 2048 ))
  # prefer computed from needed_sectors starting at p2_start
  candidate_end=$(( p2_start + needed_sectors - 1 ))
  if [[ $candidate_end -le $new_p2_end ]]; then
    final_p2_end=$candidate_end
  else
    # shrink to fit available
    final_p2_end=$new_p2_end
  fi

  # compute where p3 will start and end
  new_p3_start=$(( final_p2_end + 1 ))
  new_p3_end=$(( new_p3_start + p3_size - 1 ))

  echo "Planned layout (sectors):" >&2
  echo "p1: $p1_start - $p1_end" >&2
  echo "p2: $p2_start - $final_p2_end" >&2
  echo "p3: $new_p3_start - $new_p3_end" >&2

  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: would back up partition table and create new partitions as above." >&2
    echo "DRY-RUN: would clone p1 (dd), clone p2 (ntfsclone), clone p3 (dd) and run ntfsresize on p2." >&2
    return 0
  fi

  read -p "About to recreate partition table and clone data on $DEST_DRIVE. This is destructive. Continue? (y/n): " ok
  if [[ "$ok" != "y" ]]; then echo "Aborting."; return 1; fi

  # Backup partition table and MBR/GPT
  echo "Backing up destination partition table..." >&2
  sudo sfdisk -d "$DEST_DRIVE" > "${DEST_DRIVE##*/}.partitions.sfdisk" 2>/dev/null || true
  sudo dd if="$DEST_DRIVE" of="${DEST_DRIVE##*/}.mbr.bin" bs=512 count=2048 2>/dev/null || true

  # Create new partition table
  echo "Creating new partition table on $DEST_DRIVE..." >&2
  parted -s "$DEST_DRIVE" mklabel msdos

  # create p1
  parted -s "$DEST_DRIVE" unit s mkpart primary ${p1_start}s ${p1_end}s
  # create p2
  parted -s "$DEST_DRIVE" unit s mkpart primary ${p2_start}s ${final_p2_end}s
  # create p3
  parted -s "$DEST_DRIVE" unit s mkpart primary ${new_p3_start}s ${new_p3_end}s

  # copy p1 content
  dest_p1=$(build_part "$DEST_DRIVE" 1)
  src_p1=$(build_part "$src_drive_base" 1)
  echo "Copying p1 from $src_p1 to $dest_p1..." >&2
  dd if="$src_p1" of="$dest_p1" bs=4M conv=sync,notrunc status=progress

  # clone p2
  dest_p2=$(build_part "$DEST_DRIVE" 2)
  src_p2=$(build_part "$src_drive_base" 2)
  echo "Cloning NTFS partition from $src_p2 to $dest_p2..." >&2
  ntfsclone --overwrite "$dest_p2" "$src_p2"

  # copy p3 content
  dest_p3=$(build_part "$DEST_DRIVE" 3)
  src_p3=$(build_part "$src_drive_base" 3)
  echo "Copying p3 from $src_p3 to $dest_p3..." >&2
  dd if="$src_p3" of="$dest_p3" bs=4M conv=sync,notrunc status=progress || true

  # Resize filesystem
  echo "Resizing NTFS filesystem on $dest_p2..." >&2
  ntfsresize "$dest_p2"

  echo "Recreate-and-clone complete." >&2
  return 0
}

# If requested, calculate and print size, or calculate and use it
if [[ "$CALC_ONLY" == true ]]; then
  if recommended=$(compute_recommended_gb 2>/dev/null); then
    echo "$recommended"
    exit 0
  else
    echo "Failed to calculate optimal size." >&2
    exit 2
  fi
fi

if [[ "$AUTO" == true ]]; then
  recommended=$(compute_recommended_gb) || { echo "Failed to calculate optimal size." >&2; exit 2; }
  PARTITION_SIZE=$recommended
  echo "Using calculated partition size: ${PARTITION_SIZE}GB"
fi

if [[ "$RECREATE" == true ]]; then
  recommended=$(compute_recommended_gb) || { echo "Failed to calculate optimal size." >&2; exit 2; }
  PARTITION_SIZE=$recommended
  echo "Running recreate-and-clone with target ${PARTITION_SIZE}GB (dry-run=$DRY_RUN)"
  recreate_and_clone || { echo "Recreate-and-clone failed." >&2; exit 1; }
  exit 0
fi

if [[ -z "$PARTITION_SIZE" ]]; then
  echo "Main partition size (GB) not provided. Use --calc-only, --auto, or pass a size." >&2
  usage
fi

# Use ntfsclone to clone the NTFS partition
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
    # pick largest NTFS partition by size (bytes)
    detected=$(lsblk -bnr -o NAME,FSTYPE,SIZE "$SOURCE_DRIVE" 2>/dev/null | awk '$2=="ntfs"{print $1" "$3}' | sort -k2 -n | tail -n1)
    if [[ -n "$detected" ]]; then
      name=$(echo "$detected" | awk '{print $1}')
      SOURCE_PARTITION="/dev/$name"
      if [[ "$name" =~ ([0-9]+)$ ]]; then PART_NUM="${BASH_REMATCH[1]}"; fi
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
    echo "Resizing partition $PART_NUM to end at sector $end_sector (unit: sectors)" >&2
    parted -s "$DEST_DRIVE" unit s resizepart $PART_NUM $end_sector || {
      echo "Sector-based resize failed; trying GB-based resize as fallback." >&2
      parted "$DEST_DRIVE" resizepart $PART_NUM ${PARTITION_SIZE}GB
    }
  fi
else
  # parted uses partition number, not partition path
  parted "$DEST_DRIVE" resizepart $PART_NUM ${PARTITION_SIZE}GB
fi

# Resize the NTFS filesystem
echo "Resizing the NTFS filesystem on the destination partition..."
ntfsresize "$DEST_PARTITION"

echo "Cloning and resizing complete!"