# Drive Cloning Script

This script clones a source drive to a destination drive, resizes the main partition, and adjusts the NTFS filesystem to fit the resized partition. It is designed for use with NTFS-formatted drives.

---

## Prerequisites

1. Ensure you have `ntfsclone`, `parted`, and `ntfsresize` installed on your system.
2. Run the script as `root` or with `sudo` privileges.
3. Back up any important data before proceeding, as this script will overwrite the destination drive.

---

## Usage

Run the script with the following syntax:

```bash
sudo ./clone.sh [options] <source_drive> <destination_drive> [main_partition_size_in_GB]
```

The script supports the following modes:

- Explicit size: pass the desired main partition size in GB as the third positional argument.
- Automatic calculation: use `--auto` to let the script calculate an optimal size and use it for the resize.
- Calculate-only: use `--calc-only` to calculate the optimal size and print it, without making changes.
 - Fill destination: use `--fill` with `--calc-only` or `--auto` to make the script choose a partition size that fills the destination disk (preserving the source partition start); useful when you want the cloned partition to occupy most of the destination drive.
 - Dry-run / verbose calculation: use `--dry-run` with `--calc-only` to print internal calculation details (source needed bytes, destination capacity, recommended GB) without performing any changes.

### Examples

```bash
# Calculate optimal size and print it (no changes made)
sudo ./clone.sh --calc-only /dev/sda /dev/sdb

# Calculate optimal size and use it to resize the destination
sudo ./clone.sh --auto /dev/sda /dev/sdb

# Use an explicit size
sudo ./clone.sh /dev/sda /dev/sdb 100

# Calculate to fill the destination (recommended)
sudo ./clone.sh --calc-only --fill --dry-run /dev/sda /dev/nvme0n1

# Calculate and apply a resize that fills destination
sudo ./clone.sh --auto --fill /dev/sda /dev/nvme0n1
```

- `<source_drive>`: The drive you want to clone (e.g., `/dev/sda`).
- `<destination_drive>`: The drive where the clone will be written (e.g., `/dev/sdb`).
- `<main_partition_size_in_GB>`: (optional) The size of the main partition on the destination drive in gigabytes. If omitted, use `--auto` to compute it.

---

## Post-Clone Steps

After running the script, additional steps are required to ensure the cloned drive is bootable:

### 1. Boot into Windows Recovery
- Use a Windows installation or recovery USB.
- Select **Repair your computer** > **Troubleshoot** > **Advanced options** > **Command Prompt**.

### 2. Run Boot Repair Commands
Run the following commands in the recovery environment:
```cmd
bootrec /rebuildbcd bootrec /fixmbr bootrec /fixboot
```

### 3. Mark the Partition as Active
Use `diskpart` to mark the main partition as active:
```cmd
diskpart select disk <destination_disk> select partition <partition_number> active exit
```

Replace `<destination_disk>` and `<partition_number>` with the appropriate values for your cloned drive.

### 4. Restart and Test
Reboot the system and verify that Windows boots correctly from the cloned drive.

---

## Notes

- The script assumes the source drive has a single NTFS partition. If your drive has multiple partitions, additional steps may be required.
- If the cloned drive does not boot, ensure the partition flags are set correctly using `parted` or `diskpart`.
- This script does not handle non-NTFS filesystems.

Notes about the calculation:

- The script tries to use `ntfsresize --info` to determine the minimum required size for the NTFS filesystem. If successful it adds a small margin (5% or at least 1 GB) and returns a rounded-up value in GB.
- If `ntfsresize` cannot provide the info, the script will attempt a read-only mount of the source partition and measure used bytes as a fallback. This may fail if the partition is in use.
- `ntfsresize` and `ntfsclone` must be installed for the calculation and cloning to function.

---

## Disclaimer

Use this script at your own risk. The author is not responsible for any data loss or damage caused by using this script.

