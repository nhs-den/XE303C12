#!/usr/bin/env bash
# 70-image.sh - rakit image GPT siap-dd (TANPA loop device, TANPA mount di host).
#
# Teknik: filesystem dibangun sebagai file lepas dengan `mke2fs -d <dir>`
# (e2fsprogs >= 1.43) lalu di-dd ke offset partisi. Lebih aman & lebih cepat
# daripada losetup+mount, dan tidak butuh udev/systemd di host build.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
BOOT_DIR="${BOOT_DIR:-${WORK_DIR}/boot}"
IMG="${DIST_DIR}/${IMAGE_STEM}.img"
KERN_SRC=""

step_banner "image: ${IMG}"
require_root
if [ ! -d "$TARGET_ROOTFS" ]; then
    if [ "${DRY_RUN}" = "1" ]; then
        note "dry-run: rootfs belum ada - layout tetap divalidasi"
    else
        die "rootfs belum ada ($TARGET_ROOTFS). Jalankan tahap rootfs lebih dulu."
    fi
fi
mkdir -p "$DIST_DIR" "$WORK_DIR/fs"

# --- 0. temukan image partisi kernel hasil tahap 60 -------------------------
find_kern_img() {
    local cand
    for cand in "${WORK_DIR}/bootimg/vmlinux.kpart" \
                "${WORK_DIR}/uboot"/*.kpart \
                "${WORK_DIR}/uboot"/u-boot.kpart; do
        if [ -f "$cand" ]; then KERN_SRC="$cand"; return 0; fi
    done
    return 1
}
if ! find_kern_img; then
    if [ "${DRY_RUN}" = "1" ]; then
        KERN_SRC="${WORK_DIR}/bootimg/vmlinux.kpart"
        note "dry-run: pakai path image kernel dummy"
    else
        die "image partisi kernel tidak ditemukan - jalankan tahap bootimg (60) dulu"
    fi
fi
[ "${DRY_RUN}" = "1" ] || info "image kernel: ${KERN_SRC} ($(human $(stat -c %s "$KERN_SRC")))"

# --- 1. finalisasi rootfs (buang artefak build) ------------------------------
finalize_rootfs() {
    local t="$TARGET_ROOTFS"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  finalisasi rootfs (qemu-static, policy-rc.d, apt cache)\n'; return 0
    fi
    rm -f "$t/usr/bin/qemu-arm-static" "$t/.xe303os-qemu" "$t/usr/sbin/policy-rc.d"
    rm -f "$t/etc/resolv.conf" 2>/dev/null || true
    # /etc/ssh: biarkan kosong; host key dibuat firstboot
    rm -f "$t"/etc/ssh/ssh_host_* 2>/dev/null || true
    # pastikan /boot, /tmp, /proc ... ada sebagai mountpoint kosong
    mkdir -p "$t/boot" "$t/tmp" "$t/proc" "$t/sys" "$t/dev" "$t/run"
    apt_in "$t" clean >/dev/null 2>&1 || true
    du -sh "$t" 2>/dev/null | awk '{printf "  ukuran rootfs: %s\n", $1}'
}
finalize_rootfs

# --- 2. tabel partisi -------------------------------------------------------
mapfile -t PT < <(layout_partition_table)
total_bytes=$(layout_image_bytes)

make_disk() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  truncate -s %s %s\n' "$total_bytes" "$IMG"
        printf 'DRY  sfdisk <%s (layout_sfdisk_script)\n' "$WORK_DIR/sfdisk.txt"
        return 0
    fi
    rm -f "$IMG"
    run truncate -s "$total_bytes" "$IMG"
    layout_sfdisk_script > "${WORK_DIR}/sfdisk.txt"
    # sfdisk pada file reguler: tidak perlu --force
    run sfdisk --quiet --no-tell-user --unit=S "$IMG" < "${WORK_DIR}/sfdisk.txt"
    cp "${WORK_DIR}/sfdisk.txt" "${DIST_DIR}/${IMAGE_STEM}-partitions.txt"
    info "GPT ditulis ke image"
}
make_disk

# --- 3. filesystem BOOT (ext2) ----------------------------------------------
part_field() { local name="$1" col="$2"; awk -F'\t' -v n="$name" -v c="$col" '$1==n{print $c}' <<<"$(printf '%s\n' "${PT[@]}")"; }

build_boot_fs() {
    local start size bytes fs="${WORK_DIR}/fs/boot.fs"
    start=$(part_field BOOT 2); size=$(part_field BOOT 3); bytes=$(( size * SECTOR ))
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  mkfs.%s -d %s (%d sektor @%d) -> dd ke sektor %s\n' "$BOOT_FS" "$BOOT_DIR" "$size" "$SECTOR" "$start"
        return 0
    fi
    rm -f "$fs"; truncate -s "$bytes" "$fs"
    run mkfs."$BOOT_FS" -F -q -L "$BOOT_LABEL" -U "$BOOT_PARTUUID" -b 4096 -m 0 -d "$BOOT_DIR" "$fs"
    run dd if="$fs" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none
    info "partisi BOOT (ext2, $(human "$bytes")) ditulis di sektor ${start}"
}
build_boot_fs

# --- 4. filesystem ROOTFS ---------------------------------------------------
build_root_fs() {
    local start size bytes fs="${WORK_DIR}/fs/root.fs" opts=()
    start=$(part_field ROOTFS 2); size=$(part_field ROOTFS 3); bytes=$(( size * SECTOR ))
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  mkfs.%s -d %s (%d sektor @%d) -> dd ke sektor %s\n' "$ROOT_FS" "$TARGET_ROOTFS" "$size" "$SECTOR" "$start"
        return 0
    fi
    rm -f "$fs"; truncate -s "$bytes" "$fs"
    # ext4 untuk rootfs: metadata_csum cepat; jangan 64bit (kernel 32-bit lama) &
    # jangan lazy_journal_init (boot pertama di perangkat lambat)
    opts=(-F -q -L "$ROOTFS_LABEL" -U "$ROOTFS_UUID" -m 1 -O ^64bit)
    run mkfs."$ROOT_FS" "${opts[@]}" -d "$TARGET_ROOTFS" "$fs"
    # kalau -d gagal karena fitur, ulangi tanpa ^64bit (fallback utk e2fsprogs lama)
    if [ ! -s "$fs" ]; then
        warn "mkfs dengan -O ^64bit gagal; retry tanpa opsi itu"
        run mkfs."$ROOT_FS" -F -q -L "$ROOTFS_LABEL" -U "$ROOTFS_UUID" -m 1 -d "$TARGET_ROOTFS" "$fs"
    fi
    run dd if="$fs" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none
    info "partisi ROOTFS (${ROOT_FS}, $(human "$bytes")) ditulis di sektor ${start}"
}
build_root_fs

# --- 5. partisi kernel (KERN-A + KERN-B) ------------------------------------
write_kern_parts() {
    local name start img_size limit
    for name in KERN-A KERN-B; do
        start=$(part_field "$name" 2)
        limit=$(( $(part_field "$name" 3) * SECTOR ))
        if [ "${DRY_RUN}" = "1" ]; then
            printf 'DRY  dd %s -> %s (sektor %s, max %s byte)\n' "$KERN_SRC" "$name" "$start" "$limit"
            continue
        fi
        img_size=$(stat -c %s "$KERN_SRC")
        [ "$img_size" -le "$limit" ] || die "${name}: image ${img_size} byte > partisi ${limit} byte"
        # isi partisi dgn nol dulu supaya tidak ada sisa data lama
        run dd if=/dev/zero of="$IMG" bs=1M count=$(( limit / 1048576 )) seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none
        run dd if="$KERN_SRC" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none
        info "partisi ${name} ditulis di sektor ${start} (${img_size} byte)"
    done
    # atribut ChromeOS: KERN-A diprioritaskan, KERN-B fallback
    if command -v cgpt >/dev/null 2>&1 && [ "${DRY_RUN}" != "1" ]; then
        cgpt add -i 1 -P 15 -T 5 -S 1 "$IMG" 2>/dev/null && \
        cgpt add -i 2 -P 10 -T 5 -S 1 "$IMG" 2>/dev/null && \
            info "cgpt prioritize: KERN-A P15/T5/S1, KERN-B P10/T5/S1" || \
            warn "cgpt pada file gagal - tools/write-usb.sh akan memperbaikinya di perangkat target"
    fi
}
write_kern_parts

# --- 6. verifikasi + kemas ---------------------------------------------------
verify_and_pack() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  verifikasi image + %s compress + sha256\n' "$COMPRESS"; return 0
    fi
    sfdisk -d "$IMG" | sed 's/^/    /'
    # sanity: tiap partisi harus punya magic yg benar
    local boot_start root_start
    boot_start=$(part_field BOOT 2); root_start=$(part_field ROOTFS 2)
    local magic_boot magic_root
    magic_boot=$(dd if="$IMG" bs=512 skip=$(( boot_start + 2 )) count=1 status=none | od -An -tx1 -j1080 -N2 | tr -d ' \n')
    magic_root=$(dd if="$IMG" bs=512 skip=$(( root_start + 2 )) count=1 status=none | od -An -tx1 -j1080 -N2 | tr -d ' \n')
    [ "$magic_boot" = "53ef" ] && info "ext2 superblock BOOT ok" || warn "BOOT superblock tak ditemukan ($magic_boot)"
    [ "$magic_root" = "53ef" ] && info "ext4 superblock ROOTFS ok" || warn "ROOTFS superblock tak ditemukan ($magic_root)"

    local out="$IMG"
    case "$COMPRESS" in
        xz) out="$IMG.xz"; run xz -T0 -3 -f -k "$IMG"; info "dipaket: $(human $(stat -c %s "$out"))";;
        gz) out="$IMG.gz"; run gzip -3 -k -f "$IMG"; info "dipaket: $(human $(stat -c %s "$out"))";;
        none) note "tanpa kompresi";;
        *) die "COMPRESS tidak dikenal: $COMPRESS";;
    esac
    ( cd "$DIST_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    write_manifest "${DIST_DIR}/build-manifest.txt"
    info "checksum: ${DIST_DIR}/$(basename "$out").sha256"
}
verify_and_pack

printf '\n'
info "IMAGE SIAP: ${DIST_DIR}/${IMAGE_STEM}.img.${COMPRESS}"
cat <<EOF

  Flash ke USB/SD (dari host mana pun):
      xz -dc ${IMAGE_STEM}.img.${COMPRESS} | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
      # atau:  sudo bash tools/write-usb.sh /dev/sdX

  Di Chromebook: matikan layar (Esc+F6?), masuk developer mode, lalu Ctrl+U
  untuk boot dari USB. Detail + cara masuk ke eMMC: docs/install.md
EOF
