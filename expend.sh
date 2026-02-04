#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
opkg update
opkg install fdisk e2fsprogs resize2fs losetup
DISK="/dev/mmcblk1"
[ ! -b "$DISK" ] && DISK="/dev/sda"
PART="${DISK}p2"
[ ! -b "$PART" ] && PART="${DISK}2"
DEV_NAME=$(basename $PART)
START_SECTOR=$(cat /sys/class/block/$DEV_NAME/start)
(
echo d
echo 2
echo n
echo p
echo 2
echo $START_SECTOR
echo
echo n
echo w
) | fdisk $DISK
LOOP_DEV=$(/usr/sbin/losetup -f)
/usr/sbin/losetup "$LOOP_DEV" "$PART"
/usr/sbin/e2fsck -fy "$LOOP_DEV"
/usr/sbin/resize2fs "$LOOP_DEV"
/usr/sbin/losetup -d "$LOOP_DEV"
sync
reboot
