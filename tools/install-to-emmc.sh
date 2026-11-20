#!/bin/bash
# tools/install-to-emmc.sh - pindahkan sistem dari USB/SD ke eMMC internal.
#
# Dijalankan DARI XE303C12 yang lagi boot dari USB (bukan dari host PC!).
#   sudo bash tools/install-to-emmc.sh              # target /dev/mmcblk0
#   sudo bash tools/install-to-emmc.sh --target /dev/mmcblk0 --keep-size
#
# Yang dilakukan:
#   1. partisi eMMC: KERN-A(1) KERN-B(2) BOOT(3) ROOTFS(4) - sama dgn image USB
#   2. salian rootfs dengan rsync (kecuali /proc /sys /dev /run /tmp)
#   3. tulis ulang image partisi kernel (u-boot / vboot) ke KERN-A & KERN-B
#   4. atur UUID fs root = nilai di /etc/fstab (agar fstab target valid)
#   5. cgpt prioritize KERN-A
# Kalau write-protect hardware aktif, penulisan partisi kernel akan gagal
# (EACCES/EROFS) -> lihat docs/troubleshooting.md bagian "write protect".
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

TARGET=/dev/mmcblk0
DO_UBOOT=1
KEEP_PART_MB=0
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift;;
        --image)  SRC_IMG="$2"; shift;;
        --no-kernpart) DO_UBOOT=0;;
        --keep-size) KEEP_PART_MB=1;;
        *) die "opsi tak dikenal: $1";;
    esac
    shift
done

require_root
[ -b "$TARGET" ] || die "$TARGET bukan block device (eMMC harusnya /dev/mmcblk0)"
CUR=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
CUR=$(readlink -f "$CUR")
[ "$(basename "$CUR")" != "$(basename "$TARGET")" ] || die "kamu sedang boot dari $TARGET - boot dulu dari USB/SD"

log "  sumber : $CUR"
log "  target : $TARGET  ($(human $(blockdev --getsize64 "$TARGET")))"
read -t 20 -p "LANJUT? Semua data di $TARGET hilang. Ketik 'PAHAM' dalam 20s: " ans
[ "${ans:-}" = "PAHAM" ] || die "batal"

# --- 1. partisi ---------------------------------------------------------------
mapfile -t PT < <(layout_partition_table)
field() { awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c}' <<<"$(printf '%s\n' "${PT[@]}")"; }

TOTAL=$(blockdev --getsz "$TARGET")
{
    echo "label: gpt"
    echo "label-id: 58453330-3343-4141-2D53-453033433132"
    echo "unit: sectors"
    echo "first-lba: ${FIRST_LBA}"
    echo "last-lba: $(( TOTAL - 2049 ))"
    local_start=$FIRST_LBA
    for name in KERN-A KERN-B BOOT; do
        size=$(field "$name" 3)
        printf 'start=%d, size=%d, type=%s, name="%s"\n' "$local_start" "$size" \
            "$( [ "${name#KERN}" != "$name" ] && echo FE3A2A5D-4F32-41A7-B725-ACCC3285A309 || echo 0FC63DAF-8483-4772-8E79-3D69D8477DE4 )" "$name"
        local_start=$(( local_start + size ))
    done
    # ROOTFS = sisa ruang
    printf 'start=%d, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ROOTFS", uuid=%s\n' \
        "$local_start" "$(( TOTAL - 2048 - local_start ))" "$ROOTFS_PARTUUID"
} > /tmp/xe303os-emmc-pt.txt

if [ "${KEEP_PART_MB}" = "0" ]; then
    sed -i 's/^/  /' /tmp/xe303os-emmc-pt.txt
    log "rencana partisi:"; cat /tmp/xe303os-emmc-pt.txt
    sed -i 's/^  //' /tmp/xe303os-emmc-pt.txt
    sfdisk --quiet --no-tell-user --force "$TARGET" < /tmp/xe303os-emmc-pt.txt \
        || die "gagal menulis partisi (write-protect? lihat docs/troubleshooting.md)"
    partx -u "$TARGET" 2>/dev/null || partprobe "$TARGET"
    # PARTUUID boot
    sfdisk --part-uuid "$TARGET" 3 "$BOOT_PARTUUID" 2>/dev/null || true
    sfdisk --part-uuid "$TARGET" 4 "$ROOTFS_PARTUUID" 2>/dev/null || true
fi
for n in 1 2 3 4; do
    [ -b "${TARGET}p${n}" ] || die "partisi ${TARGET}p${n} tidak muncul"
done

# --- 2. filesystem + salin ----------------------------------------------------
log "format ROOTFS (ext4)"
mkfs.ext4 -q -F -L "$ROOTFS_LABEL" -U "$ROOTFS_UUID" -m 1 -O ^64bit "${TARGET}p4"
mkdir -p /mnt/newroot
mount "${TARGET}p4" /mnt/newroot
log "format BOOT (ext2)"
mkfs.ext2 -q -F -L "$BOOT_LABEL" -U "$BOOT_PARTUUID" -b 4096 "${TARGET}p3"
mount "${TARGET}p3" /mnt/newroot/boot 2>/dev/null || { mkdir -p /mnt/newroot/boot; mount "${TARGET}p3" /mnt/newroot/boot; }

SRCROOT=$(findmnt -no TARGET /)
log "rsync rootfs dari $SRCROOT ..."
rsync -aHAXxS --info=progress2 \
    --exclude '/proc/*' --exclude '/sys/*' --exclude '/dev/*' --exclude '/run/*' \
    --exclude '/tmp/*' --exclude '/mnt/*' --exclude '/media/*' --exclude '/lost+found/*' \
    "${SRCROOT}/" /mnt/newroot/
log "rsync /boot ..."
rsync -aHAXx --delete --exclude 'lost+found' /boot/ /mnt/newroot/boot/

# --- 3. fstab target pakai UUID yang baru (tetap sama dgn config) -------------
if grep -q "UUID=${ROOTFS_UUID}" /mnt/newroot/etc/fstab; then
    log "fstab sudah merujuk UUID root yang benar"
else
    warn "fstab tidak cocok; ditulis ulang utk eMMC"
    cat > /mnt/newroot/etc/fstab <<EOF
UUID=${ROOTFS_UUID}  /      ${ROOT_FS}  defaults,noatime,errors=remount-ro,commit=60  0 1
PARTUUID=${BOOT_PARTUUID}  /boot  ${BOOT_FS}  defaults,noatime,nofail  0 2
tmpfs  /tmp  tmpfs  nodev,nosuid,size=256M,mode=1777  0 0
EOF
fi

# --- 4. partisi kernel --------------------------------------------------------
if [ "${DO_UBOOT}" = "1" ]; then
    KSRC=""
    for c in /boot/depthcharge/*.img "${WORK_DIR}/bootimg/vmlinux.kpart" /boot/u-boot.kpart; do
        [ -f "$c" ] && { KSRC="$c"; break; }
    done
    if [ -z "$KSRC" ]; then
        note "mencoba mkdepthcharge utk partisi kernel ..."
        KV=$(ls /usr/lib/linux-image-*/ -d 2>/dev/null | head -1)
        KV=${KV#/usr/lib/linux-image-}; KV=${KV%/}
        if command -v mkdepthcharge >/dev/null 2>&1 && [ -n "$KV" ]; then
            DTB=$(ls /boot/${KV}/exynos*.dtb 2>/dev/null | head -1)
            mkdepthcharge -o /tmp/xe303os-kern.img --arch arm --format fit --patch-dtbs \
                --kernel-start 0x40008000 \
                --cmdline "$(cat /etc/xe303os/cmdline 2>/dev/null || echo 'console=tty1 rootwait rw')" \
                -- /boot/vmlinuz-"$KV" /boot/initrd.img-"$KV" "$DTB" && KSRC=/tmp/xe303os-kern.img
        fi
    fi
    if [ -n "$KSRC" ]; then
        for p in 1 2; do
            dd if="$KSRC" of="${TARGET}p${p}" bs=1M conv=fsync status=none \
                || die "gagal menulis ${TARGET}p${p}: write-protect aktif? (docs/troubleshooting.md)"
        done
        info "partisi kernel ditulis dari $(basename "$KSRC")"
    else
        warn "tidak ada image partisi kernel - setelah reboot, jalankan ulang skrip ini"
        warn "atau: sudo bash tools/rebuild-kernel-partition.sh"
    fi
fi

# --- 5. prioritaskan KERN-A ---------------------------------------------------
command -v cgpt >/dev/null 2>&1 && {
    cgpt add -i 1 -P 15 -T 5 -S 1 "$TARGET" 2>/dev/null && info "cgpt: KERN-A prioritas 15" || warn "cgpt gagal (dev mode / write protect?)"
    cgpt add -i 2 -P 10 -T 5 -S 1 "$TARGET" 2>/dev/null || true
}
sync
umount -R /mnt/newroot
printf '\n'
info "INSTALL KE eMMC SELESAI"
log "cabut USB, reboot:  sudo systemctl reboot"
log "di layar developer mode tekan Ctrl+B (eMMC). Kalau blank: docs/troubleshooting.md"
