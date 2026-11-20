#!/usr/bin/env bash
# 60-bootimg.sh - siapkan partisi BOOT (extlinux) + image partisi KERN-A/B.
#
# BOOT_MODE=uboot-extlinux (default, direkomendasikan utk Exynos 5250):
#   KERN-A/B  = image U-Boot chainloading (dibuat dari u-boot.bin + vbutil_kernel,
#               atau prebuilt nv_uboot-snow.kpart)
#   BOOT      = zImage/uImage + initrd + .dtb + extlinux/extlinux.conf  (dibaca u-boot)
#
# BOOT_MODE=vboot-direct:
#   KERN-A/B  = FIT image (kernel+initrd+dtb) yang dipaket mkdepthcharge.
#   Catatan: di keluarga snow/peach firmware H2C sering menolak image ini
#            (2x bip, balik ke ChromeOS). Itu bug firmware, bukan image kamu.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
BOOT_DIR="${BOOT_DIR:-${WORK_DIR}/boot}"
KERN_IMG="${WORK_DIR}/bootimg"

step_banner "bootimg: partisi BOOT + KERN-A/B (${BOOT_MODE})"
require_root
mkdir -p "$BOOT_DIR" "$KERN_IMG" "${WORK_DIR}/uboot"

# --- 1. temukan kernel -------------------------------------------------------
KVER="${KVER:-}"
if [ -z "$KVER" ]; then
    KVER=$(ls -1 "${TARGET_ROOTFS}/boot/" 2>/dev/null | sed -n 's/^vmlinuz-//p' | sort -V | tail -1 || true)
fi
if [ -z "$KVER" ]; then
    # dry-run: tidak ada rootfs -> pakai placeholder supaya logika tahap ini tetap teruji
    if [ "${DRY_RUN}" = "1" ]; then
        KVER="0.0.0-dryrun"
        note "dry-run: tidak ada /boot/vmlinuz-* - pakai KVER=${KVER}"
    else
        die "tidak menemukan /boot/vmlinuz-* di rootfs. Jalankan tahap packages dulu."
    fi
fi
info "kernel: ${KVER}"

KVDIR="${BOOT_DIR}/${KVER}"
[ "${DRY_RUN}" = "1" ] || rm -rf "$KVDIR"
run mkdir -p "$KVDIR"

# --- 2. salin vmlinuz + initrd ----------------------------------------------
VMLINUZ="${TARGET_ROOTFS}/boot/vmlinuz-${KVER}"
INITRD="${TARGET_ROOTFS}/boot/initrd.img-${KVER}"
run cp -f "$VMLINUZ" "${KVDIR}/vmlinuz"
if [ -f "$INITRD" ] || [ "${DRY_RUN}" = "1" ]; then
    [ -f "$INITRD" ] || warn "initrd ${INITRD##*/} tidak ada - build initramfs dulu (update-initramfs -c -k $KVER)"
    run cp -f "$INITRD" "${KVDIR}/initrd.img"
fi

# --- 3. kumpulkan DTB --------------------------------------------------------
DTBS=()
collect_dtbs() {
    local src="${TARGET_ROOTFS}/usr/lib/linux-image-${KVER}" d found
    for d in $DTB_CANDIDATES; do
        if [ -f "${src}/${d}" ]; then
            run cp -f "${src}/${d}" "${KVDIR}/"
            DTBS+=("$d"); found=1
        fi
    done
    if [ "${found:-0}" = "0" ] && [ "${DRY_RUN}" != "1" ]; then
        # fallback: ambil semua exynos dtb yang ada, biar u-boot yang pilih
        while IFS= read -r f; do
            run cp -f "$f" "${KVDIR}/"; DTBS+=("$(basename "$f")")
        done < <(find "$src" -maxdepth 1 -name 'exynos*.dtb' 2>/dev/null | sort | head -6)
    fi
    if [ ${#DTBS[@]} -eq 0 ]; then
        if [ "${DRY_RUN}" = "1" ]; then
            DTBS=(exynos5250-snow.dtb exynos5800-peach-pi.dtb)
            note "dry-run: pakai DTB kandidat dari config"
        else
            die "tidak ada DTB exynos di ${src} (suite/kernel tidak cocok dengan DTB_CANDIDATES)"
        fi
    fi
    info "DTB: ${DTBS[*]}"
}
collect_dtbs

# --- 4. zImage / uImage / uInitrd utk flow u-boot lama ----------------------
# u-boot lama snow memakai `bootm` + uImage/uInitrd; flow `sysboot` (extlinux)
# memakai zImage+dtb mentah. Kita siapkan keduanya.
prepare_images() {
    local comp
    comp=$(file -b "${KVDIR}/vmlinuz" 2>/dev/null || echo unknown)
    note "vmlinuz: ${comp}"
    case "$comp" in
        *gzip*)        run sh -c "gzip -dc < '${KVDIR}/vmlinuz' > '${KVDIR}/zImage'";;
        *LZMA*)        run sh -c "lzma -dc < '${KVDIR}/vmlinuz' > '${KVDIR}/zImage'";;
        *"XZ compressed"*) run sh -c "xz -dc < '${KVDIR}/vmlinuz' > '${KVDIR}/zImage'";;
        *"LZO compressed"*) run sh -c "lzop -dc < '${KVDIR}/vmlinuz' > '${KVDIR}/zImage'";;
        *"u-boot"*)    run sh -c "dd if='${KVDIR}/vmlinuz' of='${KVDIR}/zImage' bs=64 skip=1 status=none";;
        *ELF*)         die "vmlinuz adalah ELF (bzImage x86?) - salah arsitektur, harusnya zImage ARM";;
        *)             run cp -f "${KVDIR}/vmlinuz" "${KVDIR}/zImage";;
    esac
    # uImage: header 64B, load/entry Exynos5250 = 0x40008000
    run mkimage -A arm -O linux -T kernel -C none -a 0x40008000 -e 0x40008000 \
        -n "XE303OS ${KVER}" -d "${KVDIR}/zImage" "${KVDIR}/uImage"
    if [ -f "${KVDIR}/initrd.img" ] || [ "${DRY_RUN}" = "1" ]; then
        run mkimage -A arm -O linux -T ramdisk -C none -a 0x43000000 -e 0x43000000 \
            -n "XE303OS initrd ${KVER}" -d "${KVDIR}/initrd.img" "${KVDIR}/uInitrd"
    fi
    info "zImage + uImage$( [ -f "${KVDIR}/uInitrd" ] || [ "${DRY_RUN}" = "1" ] && echo ' + uInitrd' ) siap"
}
prepare_images

# --- 5. extlinux.conf + env.txt ---------------------------------------------
write_bootcfg() {
    local out="${BOOT_DIR}/extlinux/extlinux.conf" env="${BOOT_DIR}/env.txt"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  layout_extlinux_conf %s -> %s\n' "$KVER" "$out"
        printf 'DRY  layout_env_txt %s -> %s\n' "$KVER" "$env"
        return 0
    fi
    mkdir -p "${BOOT_DIR}/extlinux"
    layout_extlinux_conf "$KVER" "${DTBS[@]}" > "$out"
    layout_env_txt "$KVER" "${DTBS[0]}" > "$env"
    salinan="${BOOT_DIR}/extlinux/extlinux.conf.bootpart"
    cp -f "$out" "$salinan"
    info "extlinux.conf (LABEL utk ${#DTBS[@]} DTB) + env.txt ditulis"
    sed -n '1,14p' "$out" | sed 's/^/      /'
}
write_bootcfg

# --- 6. image partisi kernel -------------------------------------------------
KERN_SRC=""
build_uboot_kpart() {
    if [ "${UBOOT_BUILD_FROM_SOURCE}" = "yes" ]; then
        bash "${ROOT_DIR}/tools/build-uboot.sh" || die "build u-boot gagal"
        KERN_SRC="${WORK_DIR}/uboot/u-boot.kpart"
    else
        bash "${ROOT_DIR}/tools/fetch-uboot.sh" || die "unduh u-boot kpart gagal"
        KERN_SRC="${WORK_DIR}/uboot/$(basename "${UBOOT_PREBUILT_URL%.bz2}")"
    fi
    [ -f "$KERN_SRC" ] || [ "${DRY_RUN}" = "1" ] || die "image u-boot tidak ketemu: $KERN_SRC"
    info "partisi kernel = U-Boot chainloading: ${KERN_SRC##*/}"
}

build_vboot_kpart() {
    # kumpulkan ukuran utk pemilihan kompresi yang didukung kernel
    local comp="none" cfg="${TARGET_ROOTFS}/boot/config-${KVER}"
    if [ -r "$cfg" ]; then
        grep -q '^CONFIG_KERNEL_LZMA=y' "$cfg" && comp="lzma"
        [ "$comp" = "none" ] && grep -q '^CONFIG_KERNEL_GZIP=y' "$cfg" && comp="gzip"
    fi
    [ "${KERNEL_COMPRESS}" != "auto" ] && comp="${KERNEL_COMPRESS}"
    info "kompresi FIT: ${comp}"

    local args=( -v -o "${KERN_IMG}/vmlinux.kpart"
                 --arch arm --format fit --compress "$comp"
                 --patch-dtbs --kernel-start "${KERNEL_START:-0x40008000}"
                 --keydir /usr/share/vboot/devkeys
                 --cmdline "$(__layout_cmdline) root=UUID=${ROOTFS_UUID} rootwait rw" )
    command -v mkdepthcharge >/dev/null 2>&1 || die "mkdepthcharge tidak ada (apt-get install -y depthcharge-tools)"
    run mkdepthcharge "${args[@]}" -- "${KVDIR}/zImage" "${KVDIR}/initrd.img" "${DTBS[@]/#/${KVDIR}/}"
    KERN_SRC="${KERN_IMG}/vmlinux.kpart"
    # verifikasi: vbutil_kernel --verify harus lolos
    if [ "${DRY_RUN}" != "1" ] && command -v vbutil_kernel >/dev/null 2>&1; then
        if vbutil_kernel --verify "$KERN_SRC" >/dev/null 2>&1; then
            info "vbutil_kernel --verify: OK (signature devkey valid)"
        else
            warn "vbutil_kernel --verify gagal - periksa ulang args"
        fi
    fi
}

case "${BOOT_MODE}" in
    uboot-extlinux) build_uboot_kpart;;
    vboot-direct)   build_vboot_kpart;;
    *) die "BOOT_MODE tidak dikenal: ${BOOT_MODE}";;
esac

# --- 7. cek muat: image kernel harus <= ukuran partisi -----------------------
check_fit_size() {
    local img="$1" limit_mb="${KERN_PART_MB}"
    [ "${BOOT_MODE}" = "vboot-direct" ] && limit_mb="${KERN_PART_MB_VBOOT}"
    if [ ! -f "$img" ] || [ "${DRY_RUN}" = "1" ]; then
        note "cek ukuran image kernel dilewati (dry-run / file belum ada)"
        return 0
    fi
    local sz mb
    sz=$(stat -c %s "$img"); mb=$(( sz / 1048576 ))
    if [ "$mb" -ge "$limit_mb" ]; then
        err "image kernel ${mb} MiB >= partisi ${limit_mb} MiB."
        err "naikkan KERN_PART_MB di config/build.conf lalu build ulang."
        return 1
    fi
    info "image kernel ${mb} MiB muat di partisi ${limit_mb} MiB"
}
check_fit_size "$KERN_SRC"

# --- 8. sinkronkan /boot di rootfs ------------------------------------------
sync_rootfs_boot() {
    local d="${TARGET_ROOTFS}/boot/${KVER}"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  sync %s -> %s\n' "$BOOT_DIR" "$d"; return 0; }
    mkdir -p "$d"
    rsync -a --delete "${KVDIR}/" "$d/"
    rsync -a "${BOOT_DIR}/extlinux" "${TARGET_ROOTFS}/boot/"
    cp -f "${BOOT_DIR}/env.txt" "${TARGET_ROOTFS}/boot/env.txt"
    printf '%s\n' "$KVER" > "${TARGET_ROOTFS}/etc/xe303os-kernel"
    info "/boot/<kver> di rootfs disinkronkan (hook postinst pakai /usr/lib/xe303os/mkboot.sh)"
}
sync_rootfs_boot

info "boot image siap: ${BOOT_DIR##*/}/ + ${KERN_SRC:-<uboot>}"
