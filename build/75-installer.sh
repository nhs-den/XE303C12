#!/usr/bin/env bash
# 75-installer.sh - image USB berisi Debian-installer (d-i) dgn boot chain Chromebook.
#
# STATUS: EKSPERIMENTAL (belum diuji di perangkat). Jalur utama yang disarankan
# tetap `make image` -> flash image jadi -> tools/install-to-emmc.sh.
#
# Cocok dipakai kalau kamu mau: layout partisi sendiri, enkripsi, user lain,
# atau install langsung ke eMMC tanpa menyalin image.
#
# Butuh: tahap rootfs+packages sudah pernah jalan (kita ambil .dtb exynos dari
# paket kernel di ${WORK_DIR}/rootfs), karena kernel/initrd d-i tidak membawa
# DTB utk armmp di semua suite.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

step_banner "installer: Debian-installer utk boot chain XE303C12"
require_root

DI="${WORK_DIR}/installer"
NETBOOT="${DI}/netboot"
BOOT_DIR="${DI}/boot"
IMG="${DIST_DIR}/${DISTRO_NAME}-${VERSION}-installer-${SUITE}.img"
DI_BASE="${DEBIAN_MIRROR}/dists/${SUITE}/main/installer-${ARCH}/current/images/netboot"
CMDLINE="$(__layout_cmdline)"

run mkdir -p "$NETBOOT" "$BOOT_DIR/install/dtbs" "$BOOT_DIR/extlinux"

# --- 1. kernel + initrd d-i ---------------------------------------------------
fetch_di() {
    local f path ok=0
    for f in vmlinuz kernel.bin initrd.gz; do
        [ -s "${NETBOOT}/${f}" ] && continue
        for path in "$DI_BASE/$f" "$DI_BASE/multiplatform/armmp/$f" \
                    "$DI_BASE/multiplatform/$f" "$DI_BASE/current/$f"; do
            if run curl -fsSL -m 300 -o "${NETBOOT}/${f}" "$path"; then
                [ -s "${NETBOOT}/${f}" ] && { info "d-i ${f}: $path"; ok=1; break; }
            fi
            rm -f "${NETBOOT}/${f}"
        done
    done
    if [ "${DRY_RUN}" != "1" ]; then
        [ -s "${NETBOOT}/initrd.gz" ] || die "gagal unduh initrd.gz dari ${DI_BASE} - cek struktur arsip ${SUITE}"
        if [ ! -s "${NETBOOT}/vmlinuz" ] && [ -s "${NETBOOT}/kernel.bin" ]; then
            mv "${NETBOOT}/kernel.bin" "${NETBOOT}/vmlinuz"
        fi
        [ -s "${NETBOOT}/vmlinuz" ] || die "gagal unduh kernel d-i dari ${DI_BASE}"
    fi
}
fetch_di

# --- 2. DTB (dari paket kernel di rootfs hasil tahap 20/30) ------------------
fetch_dtb() {
    local src="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}/usr/lib" d n=0
    if [ "${DRY_RUN}" = "1" ]; then printf 'DRY  salin DTB exynos dari %s\n' "$src"; return 0; fi
    for d in "$src"/linux-image-*/; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            cp -f "$f" "${BOOT_DIR}/install/dtbs/" && n=$((n+1))
        done < <(find "$d" -maxdepth 1 -name 'exynos*.dtb' 2>/dev/null)
    done
    if [ "$n" = "0" ]; then
        die "tidak ada DTB exynos di ${src}. Jalankan dulu:  sudo -E make rootfs packages"
    fi
    info "DTB utk d-i: $n file ($(cd "${BOOT_DIR}/install/dtbs" && ls -1 | tr '\n' ' '))"
}
fetch_dtb

# --- 3. preseed --------------------------------------------------------------
write_preseed() {
    local f="${BOOT_DIR}/preseed.cfg"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  tulis %s\n' "$f"; return 0; }
    cat > "$f" <<EOF
# XE303OS preseed - Debian-installer ${SUITE}/${ARCH} (armhf, Exynos 5250)
d-i debian-installer/locale string ${LOCALE}
d-i keyboard-configuration/xkb-keymap select ${KEYMAP}
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ${HOSTNAME}
d-i mirror/country string manual
d-i mirror/http/hostname string ${DEBIAN_MIRROR#http://}
d-i mirror/http/directory string /debian
d-i passwd/root-login boolean false
d-i passwd/user-fullname string ${USERFULLNAME}
d-i passwd/username string ${USERNAME}
d-i passwd/user-password password ${USERPASS}
d-i passwd/user-password-again password ${USERPASS}
d-i clock-setup/utc boolean true
d-i time/zone string ${TIMEZONE}
# partisi: pertahankan KERN-A/B (p1,p2) & BOOT (p3); ganti hanya ROOTFS (p4)
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select rootfs-only
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i apt-setup/contrib boolean true
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server network-manager wpasupplicant alsa-utils zram-tools earlyoom firmware-libertas firmware-marvell depthcharge-tools cgpt vboot-kernel-utils
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i finish-install/keep-consoles boolean true
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string \
  in-target cp -f /etc/xe303os/cmdline /etc/kernel/cmdline 2>/dev/null || true; \
  in-target ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
EOF
    info "preseed.cfg ditulis"
}
write_preseed

# --- 4. extlinux.conf utk d-i -------------------------------------------------
write_extlinux() {
    local f="${BOOT_DIR}/extlinux/extlinux.conf" dtb="exynos5250-snow.dtb"
    [ -f "${BOOT_DIR}/install/dtbs/${dtb}" ] || dtb=$(basename "$(find "${BOOT_DIR}/install/dtbs" -name 'exynos*.dtb' 2>/dev/null | head -1 || true)")
    if [ "${DRY_RUN}" = "1" ]; then printf 'DRY  tulis %s\n' "$f"; return 0; fi
    cat > "$f" <<EOF
# XE303OS - Debian Installer (EKSPERIMENTAL)
DEFAULT debian-installer
TIMEOUT 50

LABEL debian-installer
  MENU LABEL Install Debian ${SUITE} ke eMMC (d-i + preseed)
  KERNEL /install/vmlinuz
  INITRD /install/initrd.gz
  FDT /install/dtbs/${dtb}
  APPEND ${CMDLINE} auto=true priority=critical preseed/file=/preseed.cfg locale=${LOCALE%%.*}
EOF
    info "extlinux.conf d-i ditulis (DTB=${dtb})"
}
write_extlinux

# --- 5. image: KERN = u-boot chainloading, BOOT = ext2 berisi d-i ------------
assemble() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  truncate %s + sfdisk + mkfs.%s -d %s + dd u-boot kpart\n' "$IMG" "$BOOT_FS" "$BOOT_DIR"
        return 0
    fi
    bash "${ROOT_DIR}/tools/fetch-uboot.sh" || die "u-boot kpart tidak tersedia"
    local kern_src
    kern_src=$(ls -1 "${WORK_DIR}/uboot"/*.kpart | head -1)
    [ -n "$kern_src" ] || die "tidak ada *.kpart di ${WORK_DIR}/uboot"

    # rootfs kecil: cukup utk d-i jalankan; isinya hanya README + target=initrd-shell
    mkdir -p "${DI}/rootfs"
    printf 'installer rootfs: tidak dipakai (d-i jalan dari RAM)\n' > "${DI}/rootfs/README.txt"

    local total; total=$(layout_image_bytes)
    rm -f "$IMG"; truncate -s "$total" "$IMG"
    layout_sfdisk_script > "${DI}/sfdisk.txt"
    sfdisk --quiet --no-tell-user --unit=S "$IMG" < "${DI}/sfdisk.txt"
    cp "${DI}/sfdisk.txt" "${DIST_DIR}/${DISTRO_NAME}-${VERSION}-installer-partitions.txt"

    local pt name start size bytes
    mapfile -t pt < <(layout_partition_table)
    field() { awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c}' <<<"$(printf '%s\n' "${pt[@]}")"; }

    # BOOT
    start=$(field BOOT 2); size=$(field BOOT 3); bytes=$(( size * SECTOR ))
    rm -f "${DI}/boot.fs"; truncate -s "$bytes" "${DI}/boot.fs"
    mkfs."$BOOT_FS" -F -q -L "${DISTRO_ID^}_BOOT" -U "$BOOT_PARTUUID" -b 4096 -m 0 -d "$BOOT_DIR" "${DI}/boot.fs"
    dd if="${DI}/boot.fs" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none

    # ROOTFS (kecil)
    start=$(field ROOTFS 2); size=$(field ROOTFS 3); bytes=$(( size * SECTOR ))
    rm -f "${DI}/root.fs"; truncate -s "$bytes" "${DI}/root.fs"
    mkfs."$ROOT_FS" -F -q -L "${DISTRO_ID^}_INST" -U "$ROOTFS_UUID" -m 0 -O ^64bit -d "${DI}/rootfs" "${DI}/root.fs"
    dd if="${DI}/root.fs" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none

    # KERN-A / KERN-B
    for name in KERN-A KERN-B; do
        start=$(field "$name" 2)
        dd if="$kern_src" of="$IMG" bs=1M seek=$(( start * SECTOR / 1048576 )) conv=notrunc status=none
    done
    command -v cgpt >/dev/null 2>&1 && { cgpt add -i 1 -P 15 -T 5 -S 1 "$IMG" 2>/dev/null || true; }

    xz -T0 -3 -f -k "$IMG"
    ( cd "$DIST_DIR" && sha256sum "$(basename "$IMG").xz" > "$(basename "$IMG").xz.sha256" )
    info "image installer: ${IMG}.xz ($(human $(stat -c %s "$IMG".xz)) )"
}
assemble

printf '\n'
warn "EKSPERIMENTAL: kalau device menolak boot (2x bip) atau layar blank,"
warn "gunakan 'make image' + tools/install-to-emmc.sh sebagai gantinya. Lihat docs/troubleshooting.md"
info "flash:  xz -dc $(basename "$IMG").xz | sudo dd of=/dev/sdX bs=4M conv=fsync"
