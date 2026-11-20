#!/bin/bash
# tools/unique-ids.sh - bikin UUID filesystem & PARTUUID unik per unit.
#
# Kenapa: image XE303OS memakai UUID tetap (deterministik, reproducible build).
# Kalau kamu menyalin image ke 2 perangkat sekaligus di satu jaringan, mereka
# akan tabrakan (systemd/fstab mount salah disk, avahi/DNS ganda). Jalankan ini
# di TiAP perangkat setelah install:
#     sudo bash tools/unique-ids.sh
# lalu reboot.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"
require_root

ROOT=$(findmnt -no SOURCE /)
BOOT=$(findmnt -no SOURCE /boot 2>/dev/null || true)
new_uuid() { cat /proc/sys/kernel/random/uuid; }

log "root: $ROOT"
RU=$(new_uuid)
if ! command -v tune2fs >/dev/null 2>&1; then die "butuh e2fsprogs (tune2fs)"; fi
# root ter-mount: tune2fs -U boleh pada ext4 yang ter-mount (read-only diperlukan untuk
# beberapa opsi; UUID aman). Tetap remount ro utk keselamatan.
findmnt -no OPTIONS / | grep -q ' ro,' || findmnt -no OPTIONS / | grep -q 'ro$' || {
    mount -o remount,ro / 2>/dev/null && REMOUNTED=1 || warn "remount ro gagal - lanjut hati-hati"
}
tune2fs -U "$RU" "$ROOT"
[ "${REMOUNTED:-0}" = "1" ] && mount -o remount,rw /

# fstab harus ikut berubah
sed -i "s|UUID=[0-9a-fA-F-]\{36\}|UUID=${RU}|" /etc/fstab
log "fstab root -> UUID=${RU}"

# /etc/xe303os/cmdline (dipakai mkdepthcharge) + /etc/kernel/cmdline
for f in /etc/xe303os/cmdline /etc/kernel/cmdline; do
    [ -f "$f" ] && sed -i "s|root=UUID=[0-9a-fA-F-]\{36\}|root=UUID=${RU}|" "$f" && log "$f diperbarui"
done

# extlinux.conf di partisi BOOT
if [ -n "$BOOT" ] && [ -f /boot/extlinux/extlinux.conf ]; then
    sed -i "s|root=UUID=[0-9a-fA-F-]\{36\}|root=UUID=${RU}|g" /boot/extlinux/extlinux.conf
    log "/boot/extlinux/extlinux.conf diperbarui"
fi
if [ -n "$BOOT" ] && [ -f /boot/env.txt ]; then
    sed -i "s|root=UUID=[0-9a-fA-F-]\{36\}|root=UUID=${RU}|g" /boot/env.txt
    log "/boot/env.txt diperbarui"
fi

# PARTUUID rootfs + boot (biar konsisten dgn fstab PARTUUID= utk /boot)
disk=${ROOT%%[0-9]*}; disk=${disk%p}
partno=${ROOT##*[a-z]}; partno=${partno#p}
if command -v sfdisk >/dev/null 2>&1; then
    PU=$(new_uuid)
    sfdisk --part-uuid "$disk" "$partno" "$PU" && log "PARTUUID root -> $PU"
    if [ -n "$BOOT" ]; then
        bdev=$(readlink -f "$BOOT"); bp=${bdev##*[a-z]}; bp=${bp#p}
        PU2=$(new_uuid); sfdisk --part-uuid "$disk" "$bp" "$PU2" || true
        sed -i "s|PARTUUID=[0-9a-fA-F-]\{36\}|PARTUUID=${PU2}|" /etc/fstab
        log "PARTUUID /boot -> $PU2"
    fi
fi

sync
info "UUID/PARTUUID sudah unik."
log "cek:   lsblk -fo UUID,PARTUUID,TARGET"
log "lalu:  sudo reboot"
