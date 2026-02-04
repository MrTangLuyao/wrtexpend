#!/bin/sh
# ImmortalWrt / OpenWrt 一键扩容（按你最开始成功的“环/loop”思路）
# 目标：只扩 root 所在分区，不重建分区表、不动其他分区
# 流程：
#   Stage1(当前运行)：sfdisk -N <root分区号> 把分区扩到剩余空间 -> 写入开机自启 Stage2 -> reboot
#   Stage2(重启后自动)：losetup + e2fsck + resize2fs 扩 ext4 -> 可选 tune2fs -m 1 -> 清理自启标记
#
# 用法：
#   sh expend.sh
#
# 说明：
# - “Re-reading the partition table failed.: Resource busy” 属于正常现象（根分区在用），重启后生效。

set -eu

# ===== 固定 PATH（你最开始成功里就靠这个避免找不到 /usr/sbin 下命令）=====
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

MARK_DIR="/etc/r3s-expand"
STAGE2="/usr/sbin/r3s-expand-stage2.sh"
RCLOCAL="/etc/rc.local"

log(){ echo "[expand] $*"; }
die(){ echo "[expand][FATAL] $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" = "0" ] || die "must run as root"; }

opkg_try_install() {
  # 你之前删过 /usr/lib/opkg/info/*.list 会导致 warning；不影响安装，忽略即可
  opkg update >/dev/null 2>&1 || true
  opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || true
}

resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  [ -n "${majmin:-}" ] || die "cannot resolve root device (mountinfo)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  [ -n "${sys:-}" ] || die "cannot resolve sysfs block path"
  dev="/dev/$(basename "$sys")"
  [ -b "$dev" ] || die "resolved root dev is not block device: $dev"
  echo "$dev"
}

split_disk_part() {
  dev="$1"
  case "$dev" in
    /dev/mmcblk*p[0-9]*)
      disk="${dev%p*}"
      partnum="${dev##*p}"
      ;;
    /dev/*[0-9])
      disk="$(echo "$dev" | sed -E 's/[0-9]+$//')"
      partnum="$(echo "$dev" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/')"
      ;;
    *)
      die "unsupported root device name: $dev"
      ;;
  esac
  [ -b "$disk" ] || die "disk is not a block device: $disk"
  echo "$disk $partnum"
}

ensure_rc_local() {
  if [ ! -f "$RCLOCAL" ]; then
    cat >"$RCLOCAL" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RCLOCAL"
  fi
}

install_stage2_hook() {
  ensure_rc_local
  grep -q "$STAGE2" "$RCLOCAL" 2>/dev/null && return 0
  if grep -q "^exit 0" "$RCLOCAL"; then
    sed -i "s#^exit 0#$STAGE2 || true\nexit 0#" "$RCLOCAL"
  else
    printf "\n%s || true\n" "$STAGE2" >>"$RCLOCAL"
  fi
}

remove_stage2_hook() {
  [ -f "$RCLOCAL" ] || return 0
  sed -i "\#$STAGE2#d" "$RCLOCAL" 2>/dev/null || true
}

write_stage2() {
  mkdir -p "$MARK_DIR"
  cat >"$STAGE2" <<'EOF'
#!/bin/sh
set -eu
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

MARK_DIR="/etc/r3s-expand"
RCLOCAL="/etc/rc.local"
SELF="/usr/sbin/r3s-expand-stage2.sh"

log(){ echo "[expand][stage2] $*"; }

resolve_root_dev() {
  dev="$(readlink -f /dev/root 2>/dev/null || true)"
  if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
    echo "$dev"; return
  fi
  majmin="$(awk '$5=="/"{print $3}' /proc/self/mountinfo | head -n1)"
  sys="$(readlink -f "/sys/dev/block/$majmin" 2>/dev/null || true)"
  echo "/dev/$(basename "$sys")"
}

# 已完成就清理并退出（可重复运行不伤）
if [ -f "$MARK_DIR/stage2_done" ]; then
  [ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
  exit 0
fi

ROOT_DEV="$(resolve_root_dev)"
log "root device: $ROOT_DEV"

command -v losetup >/dev/null 2>&1 || exit 1
command -v e2fsck  >/dev/null 2>&1 || exit 1
command -v resize2fs >/dev/null 2>&1 || exit 1

LOOP_DEV="$(losetup -f)"
log "using loop: $LOOP_DEV"

# 关键：环/loop 思路（对 loop 做 fsck+resize）
losetup "$LOOP_DEV" "$ROOT_DEV"
e2fsck -f -y "$LOOP_DEV" || true
resize2fs "$LOOP_DEV"
losetup -d "$LOOP_DEV" || true

# 可选：保留块降到 1%
command -v tune2fs >/dev/null 2>&1 && tune2fs -m 1 "$ROOT_DEV" || true

sync
touch "$MARK_DIR/stage2_done"

# 清理自启
[ -f "$RCLOCAL" ] && sed -i "\#$SELF#d" "$RCLOCAL" 2>/dev/null || true
exit 0
EOF
  chmod +x "$STAGE2"
}

backup_ptable() {
  disk="$1"
  ts="$(date +%Y%m%d_%H%M%S)"
  out="/root/ptable_backup_${ts}.img"
  dd if="$disk" of="$out" bs=1M count=2 >/dev/null 2>&1 || true
  log "ptable backup: $out"
}

stage1_expand_partition_only() {
  ROOT_DEV="$(resolve_root_dev)"
  log "root device: $ROOT_DEV"

  set -- $(split_disk_part "$ROOT_DEV")
  DISK="$1"
  PARTNUM="$2"
  log "disk: $DISK  partnum: $PARTNUM"

  # 工具存在性
  command -v sfdisk >/dev/null 2>&1 || die "sfdisk not found"
  command -v fdisk  >/dev/null 2>&1 || true

  backup_ptable "$DISK"

  # 只修改指定分区（不重建 disklabel，不动其他分区）
  # 输入 ", +" 表示：保持 start 不变，size 设为“剩余全部”
  # 这一步在线重读通常会提示 Resource busy —— 正常，重启后生效
  log "expanding partition $PARTNUM on $DISK to fill remaining space"
  sfdisk --force -N "$PARTNUM" "$DISK" <<EOF
, +
EOF

  sync
}

main() {
  need_root

  # 一键从 0 开始：不信任何旧标记，先清掉（只清理本脚本的标记与 hook）
  rm -f "$MARK_DIR/stage2_done" "$MARK_DIR/stage1_done" 2>/dev/null || true
  remove_stage2_hook || true

  # 安装必要组件（最少集：sfdisk/losetup/resize2fs/e2fsprogs/tune2fs）
  opkg_try_install sfdisk losetup resize2fs e2fsprogs tune2fs

  # 写入并挂载 Stage2
  write_stage2
  install_stage2_hook

  # Stage1：扩分区
  stage1_expand_partition_only

  touch "$MARK_DIR/stage1_done" 2>/dev/null || true
  sync
  log "stage1 done; rebooting (stage2 will run automatically on boot)"
  reboot
}

main
