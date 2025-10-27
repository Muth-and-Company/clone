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
sudo ./clone.sh <source_drive> <destination_drive> <main_partition_size_in_GB>
```

### Example
```bash
sudo ./clone.sh /dev/sda /dev/sdb 100
```

- `<source_drive>`: The drive you want to clone (e.g., `/dev/sda`).
- `<destination_drive>`: The drive where the clone will be written (e.g., `/dev/sdb`).
- `<main_partition_size_in_GB>`: The size of the main partition on the destination drive in gigabytes.

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

---

## Disclaimer

Use this script at your own risk. The author is not responsible for any data loss or damage caused by using this script.

