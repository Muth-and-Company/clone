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
 - Recreate-and-clone: use `--recreate` to tell the script to recreate the destination partition table in a safe order (p1, p2 sized to the recommendation, then p3...), clone data into the new partitions, and resize the filesystem. This is the safest automated way to fill a larger destination when simple resizing would overlap other partitions.
- `--reserve-gb N` — when using `--fill`, reserve N GiB at the end of the destination disk instead of filling it completely (default: 1 GiB). Useful to leave a small safety buffer.
- `--main-part N` — force the script to treat source partition number N (for example `2`) as the main partition to be resized/cloned. By default the script picks the largest NTFS partition.
- `--yes` — skip interactive confirmation prompts and auto-confirm destructive steps. Use with caution; recommended only when scripting or after confirming a `--dry-run` first.

Recreate behavior and safety notes:

- When `--recreate` runs it will print the exact `parted` mkpart commands the script will execute (in `--dry-run` they are shown but not executed). When run without `--dry-run` you will be prompted to confirm the mkpart execution. Use `--yes` to skip the prompts.
- The script creates backups before destructive actions: a `sfdisk` dump named `<disk>.partitions.sfdisk` and an initial disk image `<disk>.mbr.bin` (first 2048 sectors). Verify those files exist before proceeding.

### Important Caveats

This script is intended to aid in the replacement of old PCs that cannot make it to Windows 11 while retaining all personal data. 
IMPORTANT: Check if you are on Legacy with msinfo32
If you are on Legacy, before you clone, make sure to convert to GPT by running
```cmd
mbr2gpt /validate /allowfullos
mbr2gpt /convert /allowfullos
```
If on the live ISO you may need to provide a /drive option:
```cmd
mbr2gpt /validate /disk:0
mbr2gpt /convert /disk:0
```

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
Find your main NTFS partition and your FAT32 partition. If there is no FAT32 partition, your source drive may have been installed on Legacy instead of GPT.
```cmd
diskpart
list vol
```

Then run this command to replace the boot entry files
```cmd
bcdboot {NTFS DRIVE LETTER}:\Windows /s {FAT32 DRIVE LETTER} /f UEFI
```

### 3. Restart and Test
Reboot the system and verify that Windows boots correctly from the cloned drive.

---

## Notes

- The script assumes the source drive has a single NTFS partition. If your drive has multiple partitions, additional steps may be required.
- If the cloned drive does not boot, ensure the partition flags are set correctly using `parted` or `diskpart`.
- This script does not handle non-NTFS filesystems.

Recent changes (what I added in this branch):

- Destination-aware calculation with `--fill` and `--dry-run` reporting.
- `--recreate` mode that safely recreates the destination partition table, clones partitions, and resizes the main NTFS partition.
- New safety and control flags: `--reserve-gb`, `--main-part`, and `--yes`.
- The recreate flow prints exact `parted mkpart` commands and requires confirmation before executing them.

Planned/next improvements:

- Add an explicit `--gpt`/`--use-gpt` option to switch to GPT partition labels automatically for large drives.
- Add a small test-mode that simulates `dd`/`ntfsclone` without writing data (useful for CI/dry-run automation).
- More robust error handling and retry logic for parted/ntfsclone/disk IO failures.

Notes about the calculation:

- The script tries to use `ntfsresize --info` to determine the minimum required size for the NTFS filesystem. If successful it adds a small margin (5% or at least 1 GB) and returns a rounded-up value in GB.
- If `ntfsresize` cannot provide the info, the script will attempt a read-only mount of the source partition and measure used bytes as a fallback. This may fail if the partition is in use.
- `ntfsresize` and `ntfsclone` must be installed for the calculation and cloning to function.

---

## Disclaimer

Use this script at your own risk. The author is not responsible for any data loss or damage caused by using this script.

