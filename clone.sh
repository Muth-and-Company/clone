#!/usr/bin/env bash

set -euo pipefail

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
  --yes                        Auto-confirm destructive operations
  -h, --help                   Show this help message

EOF
  exit 1
}

# Defaults
CALC_ONLY=false
AUTO=false
DRY_RUN=false
FILL=false
RECREATE=false
RESERVE_GB=1
MAIN_PART_OVERRIDE=""
YES=false
SOURCE_DRIVE=""
DEST_DRIVE=""
PARTITION_SIZE=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --calc-only) CALC_ONLY=true; shift;;
    --auto) AUTO=true; shift;;
    --fill) FILL=true; shift;;
    --recreate) RECREATE=true; shift;;
    --reserve-gb) RESERVE_GB="$2"; shift 2;;
    --main-part) MAIN_PART_OVERRIDE="$2"; shift 2;;
    --yes) YES=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
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

# Helper functions
get_part() {
  local drive="$1"
  if [[ "$drive" =~ nvme ]] || [[ "$drive" =~ mmcblk ]]; then
    echo "${drive}p1"
  else
    echo "${drive}1"
  fi
}

build_part() {
  local drive="$1"
  local num="$2"
  if [[ "$drive" =~ nvme ]] || [[ "$drive" =~ mmcblk ]]; then
    echo "${drive}p${num}"
  else
    echo "${drive}${num}"
  fi
}

required_tools=(parted blkid lsblk wipefs mkfs.fat partprobe udevadm)
for t in "${required_tools[@]}"; do
  if ! command -v "$t" &>/dev/null; then
    echo "Required tool missing: $t" >&2
    # ntfsclone is optional unless we find ntfs partitions (we'll check later)
  fi
done

# Calculate optimal GB (unchanged from original logic, kept compact here)
calculate_optimal_gb() {
  # If caller passed a partition path, use it. Otherwise find largest NTFS on source.
  local src_part
  if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
    src_part=$SOURCE_DRIVE
  else
    # detect largest NTFS
    if command -v lsblk >/dev/null 2>&1; then
      detected=$(lsblk -bnr -o NAME,FSTYPE,SIZE "$SOURCE_DRIVE" 2>/dev/null | awk '$2=="ntfs"{print $1" "$3}' | sort -k2 -n | tail -n1)
      if [[ -n "$detected" ]]; then
        name=$(echo "$detected" | awk '{print $1}')
        src_part="/dev/$name"
      else
        src_part=$(get_part "$SOURCE_DRIVE")
      fi
    else
      src_part=$(get_part "$SOURCE_DRIVE")
    fi
  fi

  if ! command -v ntfsresize >/dev/null 2>&1; then
    echo "ntfsresize required for calculation but missing." >&2
    return 1
  fi

  echo "Calculating optimal size for $src_part..." >&2
  info=$(ntfsresize --info -f "$src_part" 2>&1 || true)

  # attempt to parse bytes or fallback to used size
  bytes=""
  bytes=$(echo "$info" | grep -oE '[0-9]+ bytes' | head -n1 | awk '{print $1}' || true)
  if [[ -z "$bytes" ]]; then
    # last-resort: mount ro and du
    tmp=$(mktemp -d)
    if mount -o ro "$src_part" "$tmp" 2>/dev/null; then
      used_bytes=$(du -s --block-size=1 "$tmp" 2>/dev/null | awk '{print $1}')
      umount "$tmp" >/dev/null 2>&1 || true
      rmdir "$tmp" >/dev/null 2>&1 || true
      bytes=$used_bytes
    else
      rmdir "$tmp" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -z "$bytes" || "$bytes" -lt 1024 ]]; then
    echo "Unable to compute optimal size." >&2
    return 1
  fi

  min_gb=$(awk "BEGIN{printf \"%f\", $bytes/1024/1024/1024}")
  margin=$(awk "BEGIN{m=$min_gb*0.05; if(m<1) m=1; printf \"%f\", m}")
  optimal_gb=$(awk "BEGIN{printf \"%d\", int($min_gb + $margin + 0.999999)}")
  echo "${bytes}:${optimal_gb}"
}

compute_recommended_gb() {
  out=$(calculate_optimal_gb) || return 1
  needed_bytes=$(echo "$out" | awk -F: '{print $1}')
  needed_gb=$(echo "$out" | awk -F: '{print $2}')
  CALC_BYTES=$needed_bytes

  # get dest size
  if command -v blockdev >/dev/null 2>&1; then
    dest_bytes=$(blockdev --getsize64 "$DEST_DRIVE" 2>/dev/null || echo "")
  fi
  if [[ -z "$dest_bytes" ]]; then
    # parted fallback
    header=$(parted -ms "$DEST_DRIVE" unit B print 2>/dev/null | head -n1 || true)
    if [[ -n "$header" ]]; then
      # header like: /dev/sdb:500107862016B:... extract 2nd field
      dest_bytes=$(echo "$header" | awk -F: '{print $2}' | sed 's/B$//')
    fi
  fi
  if [[ -z "$dest_bytes" ]]; then
    echo "Unable to determine destination capacity." >&2
    return 1
  fi

  dest_gb=$(awk "BEGIN{printf \"%d\", int($dest_bytes/1024/1024/1024)}")
  needed_gb_int=$(awk "BEGIN{printf \"%d\", int($needed_gb)}")

  if [[ "$FILL" == true ]]; then
    reserve_bytes=$(( RESERVE_GB * 1024 * 1024 * 1024 ))
    recommended=$(( dest_gb - RESERVE_GB ))
    if [[ $recommended -lt 1 ]]; then recommended=1; fi
    recommended_bytes=$(( recommended * 1024 * 1024 * 1024 ))
    if [[ "$DRY_RUN" == true ]]; then
      echo "Fill mode: dest_gb=$dest_gb reserve_gb=$RESERVE_GB recommended=$recommended" >&2
    fi
    echo "${recommended_bytes}:${recommended}"
    return 0
  fi

  if [[ $needed_gb_int -gt $dest_gb ]]; then
    recommended=$dest_gb
  else
    recommended=$needed_gb_int
  fi
  recommended_bytes=$(( recommended * 1024 * 1024 * 1024 ))
  if [[ "$DRY_RUN" == true ]]; then
    echo "Source needed (GB): $needed_gb_int" >&2
    echo "Destination (GB): $dest_gb" >&2
    echo "Recommended: $recommended" >&2
  fi
  echo "${recommended_bytes}:${recommended}"
}

# Utility: detect source partition table and partition metadata
# Returns arrays: p_num[], p_start[], p_end[], p_fs[], p_flags[], p_name[]
read_source_partitions() {
  local src="$1"
  # strip partition number if given
  local base
  if [[ -b "$src" && ( "$src" =~ [0-9]$ || "$src" =~ p[0-9]+$ ) ]]; then
    base=$(echo "$src" | sed -E 's/(p?[0-9]+)$//')
  else
    base="$src"
  fi

  local src_map
  src_map=$(parted -ms "$base" unit s print 2>/dev/null || true)
  if [[ -z "$src_map" ]]; then
    echo "Failed to read source partition table via parted." >&2
    return 1
  fi

  local map_lines
  map_lines=$(echo "$src_map" | sed -n '2,$p' | sed '/^\s*$/d' || true)

  # initialize global arrays so they exist outside the function (avoid unbound vars)
  p_num=()
  p_start=()
  p_end=()
  p_fs=()
  p_flags=()
  p_name=()
  p_size=()
  parts=0

  local idx=0
  local line num start end fs name flags size

  while IFS= read -r line; do
    # parted partition format: num:start:end:size:fs:name:flags
    num=$(echo "$line" | awk -F: '{print $1}')
    if ! echo "$num" | grep -qE '^[0-9]+$'; then
      continue
    fi
    start=$(echo "$line" | awk -F: '{print $2}' | sed 's/s$//')
    end=$(echo "$line" | awk -F: '{print $3}' | sed 's/s$//')
    fs=$(echo "$line" | awk -F: '{print $5}')
    name=$(echo "$line" | awk -F: '{print $6}')
    flags=$(echo "$line" | awk -F: '{print $7}')
    # ensure numeric arithmetic safe
    if [[ -z "$start" || -z "$end" ]]; then
      continue
    fi
    size=$(( end - start + 1 ))
    p_num+=("$num")
    p_start+=("$start")
    p_end+=("$end")
    p_fs+=("$fs")
    p_name+=("$name")
    p_flags+=("$flags")
    p_size+=("$size")
    idx=$((idx+1))
  done <<<"$map_lines"

  parts=$idx
  return 0
}

detect_partition_role() {
  # args: device (e.g. /dev/sda1)
  local dev="$1"
  local role="other"
  # Prefer blkid TYPE, PARTLABEL, PARTTYPE or lsblk FSTYPE
  local fstype label parttype
  fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
  label=$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || true)
  parttype=$(blkid -s PARTTYPE -o value "$dev" 2>/dev/null || true)
  if [[ -n "$fstype" ]]; then
    fstype=$(echo "$fstype" | tr '[:upper:]' '[:lower:]')
    if [[ "$fstype" == "vfat" || "$fstype" == "fat32" || "$fstype" == "fat" ]]; then
      role="efi"
    elif [[ "$fstype" == "ntfs" ]]; then
      role="ntfs"
    else
      role="other"
    fi
  fi
  # Heuristics on label/parttype
  if [[ -n "$label" ]]; then
    l=$(echo "$label" | tr '[:upper:]' '[:lower:]')
    if [[ "$l" =~ efi|esp|efi\ system ]]; then role="efi"; fi
    if [[ "$l" =~ msr|microsoft\ reserved ]]; then role="msr"; fi
  fi
  if [[ -n "$parttype" ]]; then
    pt=$(echo "$parttype" | tr '[:upper:]' '[:lower:]')
    if [[ "$pt" =~ efi ]]; then role="efi"; fi
  fi

  # Use partition base (strip trailing partition number) instead of dirname
  local base devnum bytes
  devnum="${dev##*/}"
  base=$(echo "$dev" | sed -E 's/(p?[0-9]+)$//')

  # final fallback: if size small (<= 1GiB) and role still "other", treat as msr
  bytes=$(parted -ms "$base" unit B print 2>/dev/null | awk -F: -v n="$devnum" 'NR>1 { if ($1==n) print $4 }' | sed 's/B$//' || true)
  if [[ -n "$bytes" ]]; then
    if [[ "$bytes" -le $((1024*1024*1024)) && "$role" == "other" ]]; then
      role="msr"
    fi
  fi

  echo "$role"
}

recreate_and_clone() {
  echo "Running recreate-and-clone mode (safe automated)." >&2

  # Safety: resolve and ensure source != dest (prevent overwriting source)
  src_real=$(readlink -f "${SOURCE_DRIVE}")
  dst_real=$(readlink -f "${DEST_DRIVE}")
  if [[ "$src_real" == "$dst_real" ]]; then
    echo "ERROR: source and destination resolve to the same device ($src_real). Aborting." >&2
    return 1
  fi
  # Prevent same physical disk (e.g. /dev/sda vs /dev/sda1)
  src_base_real=$(readlink -f "$(echo "${SOURCE_DRIVE}" | sed -E 's/(p?[0-9]+)$//')")
  dst_base_real=$(readlink -f "$(echo "${DEST_DRIVE}" | sed -E 's/(p?[0-9]+)$//')")
  if [[ "$src_base_real" == "$dst_base_real" ]]; then
    echo "ERROR: destination appears to be the same physical disk as source ($src_base_real). Aborting." >&2
    return 1
  fi

  # compute sizes if needed
  if [[ -z "${CALC_BYTES:-}" ]]; then
    out=$(calculate_optimal_gb) || { echo "Failed to calculate optimal size." >&2; return 1; }
    needed_bytes=$(echo "$out" | awk -F: '{print $1}')
    needed_gb=$(echo "$out" | awk -F: '{print $2}')
    CALC_BYTES=$needed_bytes
  else
    needed_bytes=$CALC_BYTES
    needed_gb=$(awk "BEGIN{printf \"%d\", int($CALC_BYTES/1024/1024/1024)}")
  fi

  # read source partitions
  read_source_partitions "$SOURCE_DRIVE" || { echo "Failed to read source partitions." >&2; return 1; }

  if [[ ${parts:-0} -lt 1 ]]; then
    echo "No partitions found on source." >&2
    return 1
  fi

  # identify main partition (largest NTFS or largest overall)
  main_idx=-1
  max_ntfs_size=0
  for ((i=0;i<parts;i++)); do
    src_base="$SOURCE_DRIVE"
    if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
      src_base=$(echo "$SOURCE_DRIVE" | sed -E 's/(p?[0-9]+)$//')
    fi
    src_part_dev=$(build_part "$src_base" "${p_num[$i]}")
    role=$(detect_partition_role "$src_part_dev" || echo "other")
    if [[ "$role" == "ntfs" ]]; then
      if [[ ${p_size[$i]:-0} -gt $max_ntfs_size ]]; then
        max_ntfs_size=${p_size[$i]}
        main_idx=$i
      fi
    fi
  done

  if [[ $main_idx -eq -1 ]]; then
    maxsize=0
    for ((i=0;i<parts;i++)); do
      if [[ ${p_size[$i]:-0} -gt $maxsize ]]; then
        maxsize=${p_size[$i]}
        main_idx=$i
      fi
    done
  fi

  if [[ $main_idx -eq -1 ]]; then
    echo "Unable to identify main partition." >&2
    return 1
  fi

  # Determine destination sector geometry
  if ! command -v blockdev >/dev/null 2>&1; then
    echo "blockdev missing, cannot compute destination sectors." >&2
    return 1
  fi
  sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)
  dest_total_sectors=$(blockdev --getsz "$DEST_DRIVE" 2>/dev/null || echo 0)
  if [[ -z "$dest_total_sectors" || "$dest_total_sectors" -le 0 ]]; then
    echo "Cannot determine destination total sectors." >&2
    return 1
  fi

  # compute needed sectors for main partition using CALC_BYTES + margin (5% or 1GiB)
  margin_bytes=$(awk "BEGIN{m=$CALC_BYTES*0.05; if(m<1073741824) m=1073741824; printf \"%d\", m}")
  total_bytes_needed=$(awk "BEGIN{printf \"%d\", $CALC_BYTES + $margin_bytes}")
  needed_sectors=$(awk "BEGIN{printf \"%d\", int( ($total_bytes_needed + $sector_size - 1) / $sector_size )}")

  # compute trailing partitions sectors (sectors count stored in p_size array)
  trailing_total=0
  for ((i=main_idx+1;i<parts;i++)); do
    val=${p_size[$i]:-0}
    trailing_total=$(( trailing_total + val ))
  done

  guard=2048
  main_start=${p_start[$main_idx]}
  candidate_end=$(( main_start + needed_sectors - 1 ))

  # Prefer to keep source partition-table type; detect source base and label
  if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
    src_base=$(echo "$SOURCE_DRIVE" | sed -E 's/(p?[0-9]+)$//')
  else
    src_base="$SOURCE_DRIVE"
  fi
  src_label=$(parted -ms "$src_base" unit s print 2>/dev/null | head -n1 | awk -F: '{print $6}' || true)
  src_label=$(echo "${src_label:-}" | tr '[:upper:]' '[:lower:]')

  # Decide destination label: prefer source label when known; otherwise fallback to size heuristic
  if [[ "$src_label" == "gpt" || "$src_label" == "msdos" ]]; then
    desired_label="$src_label"
  else
    dest_bytes=$(( dest_total_sectors * sector_size ))
    dest_gb=$(( dest_bytes / 1024 / 1024 / 1024 ))
    if [[ "$dest_gb" -gt 900 || "$DEST_DRIVE" =~ nvme ]]; then
      desired_label="gpt"
    else
      desired_label="msdos"
    fi
  fi

  # detect current destination label and warn if changing
  current_dest_label=$(parted -ms "$DEST_DRIVE" unit s print 2>/dev/null | head -n1 | awk -F: '{print $6}' || true)
  current_dest_label=$(echo "${current_dest_label:-}" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$current_dest_label" && "$current_dest_label" != "$desired_label" ]]; then
    echo "Warning: converting destination partition-table from '$current_dest_label' -> '$desired_label' (this will overwrite partition table)." >&2
    if [[ "$YES" != true ]]; then
      read -p "Proceed with conversion? (y/n): " _ok
      if [[ "$_ok" != "y" ]]; then
        echo "Aborting per user request." >&2
        return 1
      fi
    else
      echo "Auto-confirmed (--yes): converting to $desired_label" >&2
    fi
  fi

  echo "Planned destination label: $desired_label" >&2

  # compute usable end taking GPT backup into account
  if [[ "$desired_label" == "gpt" ]]; then
    gpt_reserved_sectors=34
  else
    gpt_reserved_sectors=0
  fi
  usable_last_sector=$(( dest_total_sectors - 1 - gpt_reserved_sectors ))

  # compute available end for main partition (stop before trailing partitions)
  first_trailing_start=$(( usable_last_sector - trailing_total + 1 ))
  available_end=$(( first_trailing_start - guard - 1 ))

  if [[ $candidate_end -le $available_end ]]; then
    final_main_end=$candidate_end
  else
    final_main_end=$available_end
  fi

  if [[ $final_main_end -lt $main_start ]]; then
    echo "Not enough space to place main partition while preserving trailing partitions." >&2
    return 1
  fi

  # compute new starts/ends (preserve trailing partition sizes exactly)
  declare -a new_start new_end
  for ((i=0;i<parts;i++)); do
    if [[ $i -lt $main_idx ]]; then
      new_start[$i]=${p_start[$i]}
      new_end[$i]=${p_end[$i]}
    elif [[ $i -eq $main_idx ]]; then
      new_start[$i]=$main_start
      new_end[$i]=$final_main_end
    else
      if [[ $i -eq $(( main_idx + 1 )) ]]; then
        s=$first_trailing_start
      else
        prev=$(( i-1 ))
        s=$(( new_end[$prev] + 1 ))
      fi

      # Align each start to 2048-sector (1 MiB) boundary for performance
      if (( s % 2048 != 0 )); then
        s=$(( (s + 2047) / 2048 * 2048 ))
      fi

      psz=${p_size[$i]:-0}
      e=$(( s + psz - 1 ))

      if [[ $e -gt $usable_last_sector ]]; then
        echo "ERROR: insufficient space for trailing partition ${p_num[$i]}; required end $e > usable last $usable_last_sector" >&2
        return 1
      fi

      new_start[$i]=$s
      new_end[$i]=$e
    fi
  done

  # Present planned layout
  echo "Planned destination layout (sectors):" >&2
  for ((i=0;i<parts;i++)); do
    echo "p${p_num[$i]}: ${new_start[$i]} - ${new_end[$i]} (orig fs='${p_fs[$i]}', name='${p_name[$i]}')" >&2
  done

  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: Would create partitions and clone data as above." >&2
    return 0
  fi

  if [[ "$YES" == true ]]; then
    ok="y"
  else
    read -p "About to recreate partition table and clone on $DEST_DRIVE. This is destructive. Continue? (y/n): " ok
  fi
  if [[ "$ok" != "y" ]]; then echo "Aborting."; return 1; fi

  # backup destination partition table
  echo "Backing up destination partition table..."
  sfdisk -d "$DEST_DRIVE" >"${DEST_DRIVE##*/}.partitions.sfdisk" 2>/dev/null || true
  dd if="$DEST_DRIVE" of="${DEST_DRIVE##*/}.mbr.bin" bs=512 count=2048 2>/dev/null || true

  # create label once
  echo "Creating label $desired_label on $DEST_DRIVE"
  parted -s "$DEST_DRIVE" mklabel "$desired_label" || { echo "Failed to mklabel $DEST_DRIVE"; return 1; }

  # Build parted mkpart commands (do not pass invalid token 'msftres')
  mkcmds=()
  if [[ -b "$SOURCE_DRIVE" && ( "$SOURCE_DRIVE" =~ [0-9]$ || "$SOURCE_DRIVE" =~ p[0-9]+$ ) ]]; then
    src_drive_base=$(echo "$SOURCE_DRIVE" | sed -E 's/(p?[0-9]+)$//')
  else
    src_drive_base=$SOURCE_DRIVE
  fi
  dest_drive_base=$DEST_DRIVE

  for ((i=0;i<parts;i++)); do
    s=${new_start[$i]}
    e=${new_end[$i]}
    src_part_guess=$(build_part "$src_drive_base" "${p_num[$i]}")
    role_guess=$(detect_partition_role "$src_part_guess" || echo "other")
    fs_token=""
    case "$role_guess" in
      efi) fs_token="fat32";;
      ntfs) fs_token="ntfs";;
      msr) fs_token="";;   # leave empty, we'll set GPT type GUID later if needed
      *) 
        pf="${p_fs[$i]:-}"
        if [[ -n "$pf" ]]; then
          pf=$(echo "$pf" | tr '[:upper:]' '[:lower:]')
          if [[ "$pf" =~ fat|vfat ]]; then fs_token="fat32"; fi
          if [[ "$pf" =~ ntfs ]]; then fs_token="ntfs"; fi
        fi
        ;;
    esac

    if [[ -n "$fs_token" ]]; then
      mkcmds+=("parted -s \"$DEST_DRIVE\" unit s mkpart primary $fs_token ${s}s ${e}s")
    else
      mkcmds+=("parted -s \"$DEST_DRIVE\" unit s mkpart primary ${s}s ${e}s")
    fi
    echo "MKPART: ${mkcmds[-1]}" >&2
  done

  # Execute mkpart commands
  echo "Executing partition creation commands..."
  for cmd in "${mkcmds[@]}"; do
    echo "RUN: $cmd" >&2
    eval "$cmd" || { echo "Partition creation failed: $cmd" >&2; return 1; }
  done

  # inform kernel
  partprobe "$DEST_DRIVE" || true
  udevadm settle --timeout=10 || true
  sleep 1

  # If GPT and sgdisk present, set Microsoft GUIDs for Windows partitions
  if command -v sgdisk >/dev/null 2>&1 && [[ "${desired_label:-}" == "gpt" ]]; then
    for ((i=0;i<parts;i++)); do
      src_part_guess=$(build_part "$src_drive_base" "${p_num[$i]}")
      role_guess=$(detect_partition_role "$src_part_guess" || echo "other")
      partnum=${p_num[$i]}
      case "$role_guess" in
        efi)
          sgdisk --typecode="${partnum}:ef00" "$DEST_DRIVE" >/dev/null 2>&1 || true
          ;;
        msr)
          sgdisk --typecode="${partnum}:E3C9E316-0B5C-4DB8-817D-F92DF00215AE" "$DEST_DRIVE" >/dev/null 2>&1 || true
          ;;
        ntfs)
          sgdisk --typecode="${partnum}:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" "$DEST_DRIVE" >/dev/null 2>&1 || true
          ;;
        *)
          ;;
      esac
    done
  fi

  # inform kernel again after typecode changes
  partprobe "$DEST_DRIVE" || true
  udevadm settle --timeout=10 || true
  sleep 1

  # Copy/format partitions
  for ((i=0;i<parts;i++)); do
    src_part=$(build_part "$src_drive_base" "${p_num[$i]}")
    dest_part=$(build_part "$dest_drive_base" "${p_num[$i]}")
    role=$(detect_partition_role "$src_part" || echo "other")
    echo "Processing partition ${p_num[$i]}: role=$role src=$src_part dest=$dest_part" >&2

    # ensure dest partition present in kernel
    if [[ ! -b "$dest_part" ]]; then
      echo "Destination partition $dest_part not present; re-probing..."
      partprobe "$DEST_DRIVE"
      udevadm settle --timeout=10
      sleep 1
      if [[ ! -b "$dest_part" ]]; then
        echo "ERROR: destination partition $dest_part still missing." >&2
        return 1
      fi
    fi

    # wipe dest signatures
    wipefs -a "$dest_part" >/dev/null 2>&1 || true

    case "$role" in
      efi)
        echo "Formatting $dest_part as FAT32 and setting esp flag"
        mkfs.fat -F32 "$dest_part" >/dev/null 2>&1 || { echo "mkfs.fat failed on $dest_part" >&2; return 1; }
        parted -s "$DEST_DRIVE" set "${p_num[$i]}" esp on || true
        ;;
      msr)
        echo "MSR/reserved partition: leaving unformatted (no fs)."
        ;;
      ntfs)
        # verify dest partition size can hold the source NTFS used size
        if command -v ntfsclone >/dev/null 2>&1; then
          used_bytes=$(ntfsclone --info -s "$src_part" 2>&1 | awk -F: '/Accounting clusters/ {getline; getline} /Space in use/ {print $0}' || true)
          # fallback: parse ntfsclone --info full output for 'Space in use' line
          space_in_use=$(ntfsclone --info "$src_part" 2>&1 | awk -F: '/Space in use/ {print $2}' | awk '{print $1}' || true)
          # best-effort: get device size
          dest_bytes=$(blockdev --getsize64 "$dest_part" 2>/dev/null || true)
          src_bytes=$(blockdev --getsize64 "$src_part" 2>/dev/null || true)
          if [[ -n "$dest_bytes" && -n "$src_bytes" ]]; then
            # if dest is smaller than source device size, complain
            if [[ "$dest_bytes" -lt "$src_bytes" ]]; then
              echo "ERROR: Destination partition $dest_part is smaller than source $src_part. Aborting clone for safety." >&2
              return 1
            fi
          fi
          echo "Cloning NTFS via ntfsclone: $src_part -> $dest_part"
          ntfsclone --overwrite "$dest_part" "$src_part" || { echo "ntfsclone failed for $src_part -> $dest_part" >&2; return 1; }
        else
          echo "ntfsclone missing; falling back to dd for NTFS copy"
          dd if="$src_part" of="$dest_part" bs=4M conv=sync,notrunc status=progress || true
        fi
        ;;
      *)
        echo "Copying raw: $src_part -> $dest_part"
        dd if="$src_part" of="$dest_part" bs=4M conv=sync,notrunc status=progress || true
        ;;
    esac
  done

  # final kernel sync and optional resize
  partprobe "$DEST_DRIVE" || true
  udevadm settle --timeout=10 || true
  sleep 1

  # Resize partition table entry for main if needed (sector-based)
  PART_NUM=${p_num[$main_idx]}
  if [[ -n "$PART_NUM" ]]; then
    echo "Resizing partition number $PART_NUM on $DEST_DRIVE to planned end (${new_end[$main_idx]})"
    parted -s "$DEST_DRIVE" unit s resizepart "$PART_NUM" "${new_end[$main_idx]}" || true
  fi

  # If main is NTFS, run ntfsresize to finalize filesystem
  main_src=$(build_part "$src_base" "${p_num[$main_idx]}")
  main_dest=$(build_part "$dest_drive_base" "${p_num[$main_idx]}")
  if [[ -n "$main_dest" ]]; then
    role_main=$(detect_partition_role "$main_src" || echo "other")
    if [[ "$role_main" == "ntfs" && -x "$(command -v ntfsresize 2>/dev/null || true)" ]]; then
      echo "Running ntfsresize on $main_dest"
      ntfsresize "$main_dest" || true
    fi
  fi

  echo "Recreate-and-clone complete."
  return 0
}

# Main flow flags (calc/auto/recreate) — similar to original usage
if [[ "$CALC_ONLY" == true ]]; then
  out=$(compute_recommended_gb 2>/dev/null) || { echo "Failed to calculate optimal size." >&2; exit 2; }
  echo "$out" | awk -F: '{print $2}'
  exit 0
fi

if [[ "$AUTO" == true ]]; then
  out=$(compute_recommended_gb) || { echo "Failed to calculate optimal size." >&2; exit 2; }
  CALC_BYTES=$(echo "$out" | awk -F: '{print $1}')
  recommended=$(echo "$out" | awk -F: '{print $2}')
  PARTITION_SIZE=$recommended
  echo "Using calculated partition size: ${PARTITION_SIZE}GB"
fi

if [[ "$RECREATE" == true ]]; then
  if [[ -z "${CALC_BYTES:-}" ]]; then
    out=$(compute_recommended_gb) || { echo "Failed to calculate optimal size." >&2; exit 2; }
    CALC_BYTES=$(echo "$out" | awk -F: '{print $1}')
    recommended=$(echo "$out" | awk -F: '{print $2}')
    PARTITION_SIZE=$recommended
  else
    if [[ -z "$PARTITION_SIZE" ]]; then
      PARTITION_SIZE=$(awk "BEGIN{printf \"%d\", int($CALC_BYTES/1024/1024/1024)}")
    fi
  fi
  echo "Running recreate-and-clone with target ${PARTITION_SIZE}GB (dry-run=$DRY_RUN)"
  recreate_and_clone || { echo "Recreate-and-clone failed." >&2; exit 1; }
  exit 0
fi

# If we get here we expect an explicit PARTITION_SIZE or the user used --auto
if [[ -z "$PARTITION_SIZE" ]]; then
  echo "Main partition size (GB) not provided. Use --calc-only, --auto, or pass a size." >&2
  usage
fi

# direct clone single partition flow (when user provided a partition explicitly or using default)
# Determine source partition path
PART_NUM=""
if [[ "$SOURCE_DRIVE" =~ ([0-9]+)$ ]]; then
  PART_NUM="${BASH_REMATCH[1]}"
fi

if [[ -n "$PART_NUM" && -b "$SOURCE_DRIVE" ]]; then
  SOURCE_PARTITION="$SOURCE_DRIVE"
else
  # detect largest NTFS partition
  if command -v lsblk >/dev/null 2>&1; then
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

DEST_PARTITION=$(build_part "$DEST_DRIVE" "$PART_NUM")

echo "Source Drive: $SOURCE_DRIVE"
echo "Source Partition: $SOURCE_PARTITION"
echo "Destination Drive: $DEST_DRIVE"
echo "Destination Partition: $DEST_PARTITION"
echo "Main Partition Size: ${PARTITION_SIZE}GB"

if [[ "$YES" == true ]]; then
  CONFIRM="y"
else
  read -p "Are these details correct? (y/n): " CONFIRM
fi
if [[ $CONFIRM != "y" ]]; then
  echo "Aborting."
  exit 1
fi

# Backup partition table from source? (not copying entire table to destination)
echo "Backing up source partition table..."
sfdisk -d "$SOURCE_DRIVE" >"${SOURCE_DRIVE##*/}.partitions.sfdisk" 2>/dev/null || true
dd if="$SOURCE_DRIVE" of="${SOURCE_DRIVE##*/}.mbr.bin" bs=512 count=2048 2>/dev/null || true

# Prepare dest: wipe signatures on the specific partition that will be overwritten
if [[ -b "$DEST_PARTITION" ]]; then
  echo "Wiping signatures on $DEST_PARTITION"
  wipefs -a "$DEST_PARTITION" || true
else
  echo "Destination partition $DEST_PARTITION missing; ensure partition exists or run --recreate." >&2
  exit 1
fi

# Identify role of the source partition
role_main=$(detect_partition_role "$SOURCE_PARTITION" || echo "other")
echo "Detected role for source partition: $role_main"

# Clone appropriately
case "$role_main" in
  efi)
    echo "Formatting destination as FAT32 for EFI"
    mkfs.fat -F32 "$DEST_PARTITION"
    parted -s "$DEST_DRIVE" set "$PART_NUM" esp on || true
    ;;
  ntfs)
    if ! command -v ntfsclone >/dev/null 2>&1; then
      echo "ntfsclone missing; using dd fallback"
      dd if="$SOURCE_PARTITION" of="$DEST_PARTITION" bs=4M conv=sync,notrunc status=progress || true
    else
      echo "Cloning NTFS via ntfsclone..."
      ntfsclone --overwrite "$DEST_PARTITION" "$SOURCE_PARTITION"
    fi
    # compute resize using CALC_BYTES if present
    if [[ -n "${CALC_BYTES:-}" ]]; then
      margin_bytes=$(awk "BEGIN{m=$CALC_BYTES*0.05; if(m<1073741824) m=1073741824; printf \"%d\", m}")
      total_bytes=$(awk "BEGIN{printf \"%d\", $CALC_BYTES + $margin_bytes}")
      sector_size=$(blockdev --getss "$DEST_DRIVE" 2>/dev/null || echo 512)
      needed_sectors=$(awk "BEGIN{printf \"%d\", int( ($total_bytes + $sector_size -1) / $sector_size )}")
      # determine start sector
      start_sector=$(parted -ms "$DEST_DRIVE" unit s print | awk -F: -v ln="$((PART_NUM+1))" 'NR==ln{print $2}')
      if [[ -n "$start_sector" ]]; then
        start_sector_num=$(echo "$start_sector" | sed 's/s$//')
        end_sector=$(( start_sector_num + needed_sectors - 1 ))
        parted -s "$DEST_DRIVE" unit s resizepart "$PART_NUM" "$end_sector" || true
      else
        # fallback to GB-based resize
        parted "$DEST_DRIVE" resizepart "$PART_NUM" ${PARTITION_SIZE}GB || true
      fi
    else
      parted "$DEST_DRIVE" resizepart "$PART_NUM" ${PARTITION_SIZE}GB || true
    fi
    # run ntfsresize to shrink if necessary
    if command -v ntfsresize >/dev/null 2>&1; then
      ntfsresize "$DEST_PARTITION" || true
    else
      echo "ntfsresize not available; may need to resize in Windows if space mismatch." >&2
    fi
    ;;
  msr)
    echo "Creating MSR (reserved) partition left unformatted."
    ;;
  *)
    echo "Default: raw copy via dd..."
    dd if="$SOURCE_PARTITION" of="$DEST_PARTITION" bs=4M conv=sync,notrunc status=progress || true
    ;;
esac

echo "Clone operation complete."

exit 0
