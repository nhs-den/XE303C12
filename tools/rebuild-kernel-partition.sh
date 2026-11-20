#!/bin/bash
# tools/rebuild-kernel-partition.sh - tulis ulang partisi KERN-A/B dari sistem yang jalan.
#
# Dipakai setelah upgrade kernel / ganti DTB / pindah mode boot. Dijalankan DI
# CHROMEBOOK (bukan di host build):
#
#   sudo bash tools/rebuild-kernel-partition.sh                 # mode u-boot (default)
#   sudo bash tools/rebuild-kernel-partition.sh --mode vboot     # pack kernel via mkdepthcharge
#   sudo bash tools/rebuild-kernel-partition.sh --dtb exynos5250-spring.dtb
#   sudo bash tools/rebuild-kernel-partition.sh --dry-run        # cetak rencana saja
#
# Bila gagal dengan EROFS/Permission denied -> write protect hardware aktif.
# Solusi (Snow/Peach): buka casing, lepas sekrup write-protect (ditandai simbol
# gembok/baut), atau jalankan dari USB live yang bisa nulis.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

MODE="${BOOT_MODE}"
DTB=""
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift;;
        --dtb)  DTB="$2"; shift;;
        --dry-run) DRY=1;;
        *) die "opsi tak dikenal: $1";;
    esac
    shift
done
DRY_RUN=$DRY

DISK=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
DISK=$(readlink -f "$DISK")
KV=$(uname -r)
[ -n "$DTB" ] || DTB=$(ls /boot/${KV}/exynos*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] || DTB=$(ls /usr/lib/linux-image-${KV}/exynos*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] || die "DTB exynos tidak ditemukan di /boot/${KV} atau /usr/lib/linux-image-${KV}"
info "kernel=${KV} dtb=$(basename "$DTB") mode=${MODE} disk=${DISK}"

CMDLINE=$(cat /etc/xe303os/cmdline 2>/dev/null || cat /etc/kernel/cmdline 2>/dev/null \
          || echo "console=tty1 rootwait rw")

build_img() {
    case "$MODE" in
        uboot-extlinux)
            [ -n "${UBOOT_KPART:-}" ] || die "set UBOOT_KPART=<path .kpart> (hasil tools/fetch-uboot.sh)"
            KIMG="$UBOOT_KPART";;
        vboot-direct)
            command -v mkdepthcharge >/dev/null 2>&1 || die "apt-get install -y depthcharge-tools"
            KIMG=/tmp/xe303os-kern-$$.img
            run mkdepthcharge -v -o "$KIMG" --arch arm --format fit --patch-dtbs \
                --kernel-start 0x40008000 --cmdline "$CMDLINE" -- \
                "/boot/vmlinuz-${KV}" "/boot/initrd.img-${KV}" "$DTB";;
        *) die "--mode harus uboot-extlinux | vboot-direct";;
    esac
}
build_img

pick_parts() {
    # pakai cgpt supaya tahu partisi kernel yang ada & prioritasnya
    if command -v cgpt >/dev/null 2>&1; then
        cgpt show "$DISK" 2>/dev/null | awk 'NR>1 && $3=="" {}
            /FE3A2A5D|KERN/ {print $4}' | head -2 > /tmp/xe303os-kparts
        mapfile -t P < /tmp/xe303os-kparts
    fi
    if [ "${#P[@]:-0}" -lt 1 ] || [ ! -e "${P[0]:-/nonexistent}" ]; then
        P=("${DISK}p1" "${DISK}p2")
        note "cgpt tak memberi hasil - pakai ${P[*]}"
    fi
}
pick_parts

write_parts() {
    local p
    for p in "${P[@]}"; do
        [ -b "$p" ] || { warn "lewat: $p bukan block device"; continue; }
        log "dd -> $p"
        run dd if="$KIMG" of="$p" bs=1M conv=fsync status=none
    done
    command -v cgpt >/dev/null 2>&1 && {
        run cgpt add -i 1 -P 15 -T 5 -S 1 "$DISK" || warn "cgpt gagal (dev mode?)"
        run cgpt add -i 2 -P 10 -T 5 -S 1 "$DISK" || true
    }
}
write_parts

if [ "${DRY}" = "0" ]; then
    # jangan reboot ke sistem yang tak boot: verifikasi image target dulu
    if command -v futility >/dev/null 2>&1; then
        futility vbutil_kernel --verify "$KIMG" >/dev/null 2>&1 && info "verify OK" || warn "verify gagal - JANGAN reboot dulu"
    fi
    printf '\n'
    warn "Reboot hanya setelah kamu yakin ada jalur boot lain (USB/SD yang masih berisi image lama)."
    info "selesai: $KIMG ditulis ke ${P[*]}"
fi
