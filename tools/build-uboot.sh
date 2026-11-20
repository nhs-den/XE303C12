#!/bin/bash
# tools/build-uboot.sh - bangun U-Boot chainloading utk Samsung XE303C12 (Exynos 5250/snow).
#
# Hasil: ${WORK_DIR}/uboot/u-boot.kpart  -> dipakai build/60-bootimg.sh
#
# Kenapa dari sumber? Prebuilt biner sulit diverifikasi. Build sendiri butuh:
#   apt-get install -y build-essential gcc-arm-linux-gnueabihf device-tree-compiler \
#       bison flex bc python3 libssl-dev vboot-kernel-utils git
#
# Config: snow_defconfig (mainline u-boot mendukung exynos5250 Chromebook).
# U-Boot "chainloading" = u-boot ditaruh di partisi KERN-A/B dan mem-boot
# extlinux dari partisi berikutnya; lihat docs/boot-chain.md.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"

UBOOT_SRC="${WORK_DIR}/u-boot-src"
UBOOT_VERSION="${UBOOT_VERSION:-2024.07}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-snow_defconfig}"
OUT="${WORK_DIR}/uboot"

step_banner "u-boot: build ${UBOOT_VERSION} (${UBOOT_DEFCONFIG})"
for c in make gcc arm-linux-gnueabihf-gcc dtc mkimage vbutil_kernel git; do
    command -v "$c" >/dev/null 2>&1 || die "butuh $c (lihat komentar di kepala script ini)"
done
mkdir -p "$OUT"

# sumber: tarball resmi (verifiable) > git mirror
fetch_src() {
    if [ -d "${UBOOT_SRC}" ] && [ -f "${UBOOT_SRC}/Makefile" ]; then
        info "sumber sudah ada: $UBOOT_SRC"; return 0
    fi
    local tb="${WORK_DIR}/u-boot-${UBOOT_VERSION}.tar.bz2"
    if [ ! -f "$tb" ]; then
        note "unduh tarball u-boot ${UBOOT_VERSION}"
        run curl -fL --retry 3 -m 900 -o "$tb" "${UBOOT_TARBALL:-https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2}" \
            || die "unduh gagal; set UBOOT_TARBALL=<url> di config/build.local.conf"
    fi
    if [ "${UBOOT_SHA256:-}" != "" ]; then
        printf '%s  %s\n' "$UBOOT_SHA256" "$tb" | sha256sum -c - || die "SHA256 tarball tidak cocok"
        info "sha256 tarball cocok"
    else
        note "sha256: $( [ -f "$tb" ] && sha256sum "$tb" | cut -c1-64 || echo '<dry-run>' )"
        warn "UBOOT_SHA256 kosong - cocokkan dengan https://ftp.denx.de/pub/u-boot/ lalu isi di config"
    fi
    run mkdir -p "$UBOOT_SRC"
    run tar -xf "$tb" -C "$UBOOT_SRC" --strip-components=1
}
fetch_src

# Tambah/ubah CONFIG di .config tanpa bergantung pada scripts/config (tidak
# selalu ada di tree u-boot), lalu biarkan `make olddefconfig` merapikan dependensi.
apply_config() {
    local f="${UBOOT_SRC}/.config" line key
    [ -f "$f" ] || { warn "$f belum ada - lewati apply_config"; return 0; }
    while IFS= read -r line; do
        [ -z "${line// }" ] && continue
        case "$line" in \#*) continue;; esac
        key=${line%%=*}
        if grep -q "^${key}=" "$f"; then
            sed -i "s|^${key}=.*|${line}|" "$f"
        elif grep -q "^# ${key} is not set\$" "$f"; then
            sed -i "s|^# ${key} is not set\$|${line}|" "$f"
        else
            printf '%s\n' "$line" >> "$f"
        fi
    done <<<"${UBOOT_EXTRA_CONFIG}"
    if [ "${DRY_RUN}" != "1" ]; then
        make -C "$UBOOT_SRC" $XC olddefconfig
        info "config diturunkan: $(grep -c '^CONFIG_' "$f") simbol"
    fi
}

XC="CROSS_COMPILE=arm-linux-gnueabihf-"
build() {
    run make -C "$UBOOT_SRC" $XC mrproper
    run make -C "$UBOOT_SRC" $XC "${UBOOT_DEFCONFIG}"
    # opsi yang membuat u-boot ini jadi 'chainloader': baca extlinux/FAT/ext2/ext4
    # dari partisi berikutnya + errata Cortex-A15 r0p* (773022) utk Exynos 5250 awal.
    apply_config
    run make -C "$UBOOT_SRC" $XC -j"$(nproc)" u-boot-dtb.bin
    [ -f "${UBOOT_SRC}/u-boot-dtb.bin" ] || [ "${DRY_RUN}" = "1" ] || \
        die "u-boot-dtb.bin tidak terbentuk - coba target: make u-boot.bin"
}
UBOOT_EXTRA_CONFIG='
CONFIG_DISTRO_DEFAULTS=y
CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_USE_SECTOR=y
CONFIG_CMD_SYSBOOT=y
CONFIG_CMD_EXT2=y
CONFIG_CMD_EXT4=y
CONFIG_CMD_FS_GENERIC=y
CONFIG_CMD_FAT=y
CONFIG_CMD_MMC=y
CONFIG_CMD_USB=y
CONFIG_CMD_USB_MASS_STORAGE=y
CONFIG_DOS_PARTITION=y
CONFIG_EFI_PARTITION=y
CONFIG_OF_LIBFDT=y
CONFIG_ARM_ERRATA_773022=y
CONFIG_USE_DEFAULT_ENV_FILE=y
'
build

pack() {
    local ubin="${UBOOT_SRC}/u-boot-dtb.bin"
    [ -f "$ubin" ] || ubin="${UBOOT_SRC}/u-boot.bin"
    [ -f "$ubin" ] || { note "dry-run: tidak ada u-boot.bin utk dipaket"; return 0; }
    # partisi kernel ChromeOS = [vbkernel header][u-boot]. Bootloader stub = 512B nol.
    run dd if=/dev/zero of="${OUT}/bootloader.bin" bs=512 count=1
    printf 'rootwait rw console=tty1 cros_legacy\n' > "${OUT}/cmdline"
    run vbutil_kernel --pack "${OUT}/u-boot.kpart" \
        --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
        --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
        --version 1 --config "${OUT}/cmdline" \
        --bootloader "${OUT}/bootloader.bin" \
        --vmlinuz "$ubin" --arch arm
    run vbutil_kernel --verify "${OUT}/u-boot.kpart"
    [ -f "${OUT}/u-boot.kpart" ] || die "u-boot.kpart tidak terbentuk"
    info "hasil: ${OUT}/u-boot.kpart ($(human $(stat -c %s "${OUT}/u-boot.kpart")))"
    printf '%s\n' "${OUT}/u-boot.kpart" > "${OUT}/.path"
}
pack

cat <<'EOF'
Catatan penting utk exynos5250 (snow/peach):
  * Beberapa unit menolak image vboot dari USB. Kalau 2x bip:
      - coba nv_uboot-snow.kpart (prebuilt) lewat UBOOT_PREBUILT_URL, atau
      - pakai "swizzle": partisi kernel harus di-pack ulang dengan
        CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_USE_SECTOR dan dev_boot_usb=1.
  * Boot dari USB sering gagal tergantung kualitas kartu: coba SDHC kelas 10
    (hexdump0815: "peach chromebooks seem to not boot ... from usb devices").
EOF
