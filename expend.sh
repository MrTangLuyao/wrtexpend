#!/bin/sh

# 1. 环境准备
opkg update
opkg install fdisk e2fsprogs resize2fs losetup

# 2. 磁盘定位
DISK="/dev/mmcblk1"
PART="/dev/mmcblk1p2"
[ ! -b "$DISK" ] && DISK="/dev/sda" && PART="/dev/sda2"

# 3. 提取物理起始扇区
START_SECTOR=$(cat /sys/class/block/$(basename $PART)/start)

# 4. 强制物理重分区 (修复交互错位)
# 序列说明：删除 -> 新建 -> 保持起始位 -> 默认结束位 -> 拒绝删除签名(n) -> 写入(w)
printf "d\n2\nn\np\n2\n%s\n\nn\nw\n" "$START_SECTOR" | fdisk "$DISK"

# 5. 告知内核同步 (如果失败则必须重启)
partprobe "$DISK" 2>/dev/null || sync

# 6. 复刻回环设备扩容逻辑
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$PART"

# 强制自检（resize2fs 的前置条件）
e2fsck -fy "$LOOP_DEV"

# 逻辑扩容
resize2fs "$LOOP_DEV"

# 释放回环设备
losetup -d "$LOOP_DEV"
sync

echo "------------------------------------------------"
echo "物理分区与文件系统扩容已尝试完成。"
echo "若 df -h 容量未变，请立即执行：reboot"
echo "------------------------------------------------"
