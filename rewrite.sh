#!/bin/bash
# Safe disk cloning script with GPT conversion and NTFS resizing

set -euo pipefail

SOURCE_DISK="$1"
TARGET_DISK="$2"
DRY_RUN="${3:-false}"

# Helper: print and optionally run
run() {
    echo "+ $*"
    $([ "$DRY_RUN" = true ] && echo "DRY RUN: skipping" || true)
    $([ "$DRY_RUN" = true ] || "$@")
}

# Step 1: detect source partition table
SRC_TYPE=$(parted -m "$SOURCE_DISK" print | head -n1 | cut -d: -f6)
echo "Source partition table type: $SRC_TYPE"

# Step 2: read partitions
mapfile -t PARTS < <(parted -m "$SOURCE_DISK" unit s print | tail -n +2 | cut -d: -f1,2,3,5)

# Step 3: prepare target
if [ "$SRC_TYPE" = "msdos" ]; then
    echo "Converting target to GPT"
    run parted "$TARGET_DISK" mklabel gpt
else
    run parted "$TARGET_DISK" mklabel gpt
fi

# Step 4: clone partitions preserving layout & resizing main NTFS
for part in "${PARTS[@]}"; do
    IFS=: read -r NUM START SIZE TYPE <<<"$part"

    # For main NTFS, compute expandable size
    if [[ "$TYPE" =~ ntfs ]]; then
        NEXT_START=$(parted "$SOURCE_DISK" unit s print | awk -v n=$NUM -F: 'NR>1 && $1==n+1 {gsub(/s/,"",$2); print $2}')
        if [[ -n "$NEXT_START" ]]; then
            EXPAND_SIZE=$((NEXT_START - START))
        else
            DISK_END=$(blockdev --getsz "$TARGET_DISK")
            EXPAND_SIZE=$((DISK_END - START))
        fi
    else
        EXPAND_SIZE=$SIZE
    fi

    # Create partition
    run parted "$TARGET_DISK" mkpart primary "${TYPE}" "${START}s" "$((START+EXPAND_SIZE))s"

    # Clone data
    SRC_START_BYTE=$((START*512))
    SIZE_BYTE=$((EXPAND_SIZE*512))
    run dd if="$SOURCE_DISK" of="$TARGET_DISK" bs=512 skip="$START" count="$EXPAND_SIZE" status=progress
done

# Step 5: Resize NTFS
MAIN_PART_NUM=$(parted "$TARGET_DISK" print | awk '$6~/ntfs/ {print $1; exit}')
if [ -n "$MAIN_PART_NUM" ]; then
    echo "Resizing NTFS partition $MAIN_PART_NUM to fill target space"
    run ntfsresize -f -v -i "${TARGET_DISK}${MAIN_PART_NUM}"
fi

echo "Clone complete."
