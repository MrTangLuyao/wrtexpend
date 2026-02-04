<a id="en"></a>
# WRTExpand 
---
An easy to use batch auto expend root storage for Firendlyelec NanoPi and compatible Arm devices
---
[点击跳转中文版](#cn)
---
Automated root partition and filesystem expansion script for **OpenWrt/ImmortalWrt** on ARM devices (optimized for **NanoPi R3S**, Other NanoPi devices should also be compatible.).

---

## Features
* **Automated Dependency Installation**: Installs `fdisk`, `e2fsprogs`, `resize2fs`, `losetup`, and `tune2fs`.
* **Partition Resizing**: Safely redefines the partition table to use total disk capacity.
* **Online-Bypass Expansion**: Uses `losetup` to handle filesystems that refuse online resizing.
* **Reserved Space Optimization**: Sets reserved blocks to 1% to increase usable capacity.

---

## Usage (One-Click)

Execute the following command in your SSH terminal:

```bash
wget -qO- https://raw.githubusercontent.com/MrTangLuyao/wrtexpend/refs/heads/main/expend.sh | sh
```
**If the expansion is successful but storage usage is almost full run:**
```bash
sync
reboot
opkg update
opkg install tune2fs
tune2fs -m 1 /dev/mmcblk1p2
```
---

## Mechanism
1. **Initialization**: Checks and installs missing tools via `opkg`.
2. **Sector Detection**: Identifies the exact starting sector of the root partition.
3. **Partition Table Update**: Re-creates the partition entry using the full disk range.
4. **Filesystem Resize**:
   - Maps the partition to a loop device.
   - Runs mandatory `e2fsck` (filesystem check).
   - Executes `resize2fs`.
5. **Finalization**: Reduces reserved blocks and reboots the system to apply changes.

---

## Prerequisites
* **Device**: FriendlyElec NanoPi R3S (Target disk: `/dev/mmcblk1`).
* **Firmware**: ImmortalWrt / OpenWrt (Ext4 filesystem).
* **Network**: Active internet connection for `opkg` downloads.

---

## Warning
**Use at your own risk.** This script modifies partition tables. Back up critical data before proceeding.

---
<a id="cn"></a>
[Switch to English](#en)
# 中文说明 (Chinese Version)

适用于 ARM 设备（针对 **NanoPi R3S** 优化, 其他友善科技 NanoPi 系列也应该适用）的 **OpenWrt/ImmortalWrt** 根分区与文件系统自动化扩容脚本。

---

## 功能特点
* **自动化依赖安装**: 自动安装 `fdisk`, `e2fsprogs`, `resize2fs`, `losetup` 和 `tune2fs`。
* **分区调整**: 安全地重定义分区表，以利用 TF 卡的全部剩余容量。
* **绕过在线扩容限制**: 使用 `losetup` 回环设备挂载，解决内核不支持在线调整根分区的问题。
* **空间优化**: 将系统预留块比例降至 1%，释放更多可用空间。

---

## 使用方法 (一键脚本)

在 SSH 终端中执行以下命令：

```bash
wget -qO- https://raw.githubusercontent.com/MrTangLuyao/wrtexpend/refs/heads/main/expend.sh | sh
```
**如果扩容成功但空间占用却异常的高,请执行:**
```bash
sync
reboot
opkg update
opkg install tune2fs
tune2fs -m 1 /dev/mmcblk1p2
```
---

## 工作原理
1. **环境初始化**: 通过 `opkg` 检查并安装缺少的工具。
2. **扇区检测**: 自动获取当前根分区的起始扇区偏移量。
3. **更新分区表**: 删除旧分区定义并基于原起始扇区重建分区，使其覆盖磁盘末尾。
4. **文件系统扩容**:
   - 将分区映射至回环设备（Loop Device）。
   - 执行强制文件系统检查（`e2fsck`）。
   - 执行 `resize2fs` 完成逻辑扩容。
5. **完成收尾**: 调整预留空间比例并自动重启系统。

---

## 前提条件
* **硬件**: 友善电子 NanoPi R3S（目标磁盘识别为 `/dev/mmcblk1`）。
* **固件**: ImmortalWrt / OpenWrt (Ext4 格式)。
* **网络**: 需要互联网连接以获取 `opkg` 软件包供应。

---

## 警告
**风险自担。** 修改分区表属于高风险操作。在执行脚本前，请务必备份您的重要配置文件。
