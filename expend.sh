#!/bin/sh

# 1. Install necessary utilities
opkg update
opkg install fdisk e2fsprogs resize2fs losetup tune2fs

# 2. Identify Root Disk and Partition
# Checks for mmcblk1 (SD) or sda (USB/SSD)
if [ -b "/dev/mmcblk1" ]; then
    DISK="/dev/mmcblk1"
elif [ -b "/dev/sda" ]; then
    DISK="/dev/sda"
else
    echo "Error: No suitable disk found (/dev/mmcblk1 or /dev/sda)."
    exit 1
fi

# Detect partition path (e.g., mmcblk1p2 or sda2)
PART="${DISK}p2"
[ ! -b "$PART" ] && PART="${DISK}2"

# 3. Extract Start Sector using sysfs (Avoids fdisk parsing issues)
DEV_NAME=$(basename $PART)
START_SECTOR=$(cat /sys/class/block/$DEV_NAME/start)

# 4. Repartitioning
# d: delete, 2: partition 2, n: new, p: primary, 2: partition 2
# $START_SECTOR: keep original offset, empty line: use max sector
# n: DO NOT remove signature (Critical for data safety)
# w: write changes
printf "d\n2\nn\np\n2\n%s\n\nn\nw\n" "$START_SECTOR" | fdisk "$DISK"

# 5. Expand Filesystem via Loop Device
# This bypasses "mounted device" locks
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$PART"

# Mandatory forced check (Required by resize2fs)
e2fsck -fy "$LOOP_DEV"

# Execute Resize
resize2fs "$LOOP_DEV"

# Optimize Reserved Space (Set to 1%)
tune2fs -m 1 "$LOOP_DEV"

# 6. Cleanup and Reboot
losetup -d "$LOOP_DEV"
sync

echo "----------------------------------------------------"
echo "Root partition expansion complete."
echo "System will reboot in 3 seconds to apply changes."
echo "----------------------------------------------------"
sleep 3
reboot
