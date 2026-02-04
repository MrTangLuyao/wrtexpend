#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

opkg update
opkg install util-linux-fdisk util-linux-losetup e2fsprogs resize2fs tune2fs sfdisk kmod-loop

DISK="/dev/mmcblk1"
[ ! -b "$DISK" ] && DISK="/dev/sda"
PART="${DISK}p2"
[ ! -b "$PART" ] && PART="${DISK}2"

/usr/sbin/sfdisk --force -N 2 $DISK <<EOF
, +
EOF

[ -e /dev/loop0 ] || mknod /dev/loop0 b 7 0

LOOP_DEV=$(/usr/sbin/losetup -f)
/usr/sbin/losetup "$LOOP_DEV" "$PART"

/usr/sbin/e2fsck -fy "$LOOP_DEV"
/usr/sbin/resize2fs "$LOOP_DEV"
/usr/sbin/tune2fs -m 1 "$LOOP_DEV"

/usr/sbin/losetup -d "$LOOP_DEV"

sync
echo "Expansion complete."
reboot
