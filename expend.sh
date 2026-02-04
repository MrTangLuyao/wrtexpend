#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
opkg update
opkg install e2fsprogs resize2fs losetup sfdisk

DISK="/dev/mmcblk1"
[ ! -b "$DISK" ] && DISK="/dev/sda"
PART="${DISK}p2"
[ ! -b "$PART" ] && PART="${DISK}2"

/usr/sbin/sfdisk --force -N 2 $DISK <<EOF
, +
EOF

LOOP_DEV=$(/usr/sbin/losetup -f)
/usr/sbin/losetup "$LOOP_DEV" "$PART"
/usr/sbin/e2fsck -fy "$LOOP_DEV"
/usr/sbin/resize2fs "$LOOP_DEV"
/usr/sbin/losetup -d "$LOOP_DEV"

sync
reboot
