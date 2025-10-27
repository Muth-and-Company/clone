#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

# Function to display usage
usage() {
  echo "Usage: $0 <source_drive> <destination_drive> <main_partition_size_in_GB>"
  echo "Example: $0 /dev/sda /dev/sdb 100"
  exit 1
}

# Check arguments
if [[ $# -ne 3 ]]; then
  usage
fi

SOURCE_DRIVE=$1
DEST_DRIVE=$2
PARTITION_SIZE=$3

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
SOURCE_PARTITION="${SOURCE_DRIVE}1"
DEST_PARTITION="${DEST_DRIVE}1"
ntfsclone --overwrite $DEST_PARTITION $SOURCE_PARTITION

# Resize the destination partition
echo "Resizing the destination partition to ${PARTITION_SIZE}GB..."
parted $DEST_DRIVE resizepart 1 ${PARTITION_SIZE}GB

# Resize the NTFS filesystem
echo "Resizing the NTFS filesystem on the destination partition..."
ntfsresize $DEST_PARTITION

echo "Cloning and resizing complete!"