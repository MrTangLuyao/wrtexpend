#!/bin/sh

# 1. Update package list and install required utilities
opkg update
opkg install fdisk e2fsprogs resize2fs losetup tune2fs

# 2. Define target disk and partition variables
DISK="/dev/mmcblk1"
PART="/dev/mmcblk1p2"

# 3. Extract the starting sector of the root partition (Partition 2)
START_SECTOR=$(fdisk -l $DISK | grep $PART | awk '{print $2}')

# 4. Re-define the partition table
# Sequence: Delete partition 2 -> Create new primary partition 2 -> Use original start sector -> Use default end sector -> Keep signature -> Write changes
fdisk $DISK <<EOF
d
2
n
p
2
$START_SECTOR

n
w
EOF

# 5. Expand the filesystem using a loop device to bypass mount locks
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" $PART

# Run a forced filesystem check (mandatory for resize2fs)
e2fsck -y "$LOOP_DEV"

# Resize the filesystem to fill the newly enlarged partition
resize2fs "$LOOP_DEV"

# Reduce reserved blocks to 1% to maximize user-available space
tune2fs -m 1 "$LOOP_DEV"

# 6. Detach loop device and sync data to disk
losetup -d "$LOOP_DEV"
sync

echo "Expansion successful. The system is rebooting to apply changes..."
reboot
