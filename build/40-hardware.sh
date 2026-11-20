#!/usr/bin/env bash
# 40-hardware.sh - konfigurasi spesifik Exynos 5250 / snow (XE303C12).
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
step_banner "hardware: exynos5250 (board=${BOARD}, boot=${BOOT_MODE})"
require_root

# --- 1. modul yang harus ada sejak awal --------------------------------------
# cros_ec_* : keyboard/matrix + baterai via ChromeOS EC (I2C) -> TANPA ini keyboard mati
# snd_soc_snow / max9809x : audio (codec MAX98090 pada XE303C12, MAX98095 pada snow awal)
# mwifiex_sdio : Marvell 88W8797 (WiFi) ; btmrvl_sdio : Bluetooth-nya chip yang sama
# atmel_mxt_ts : touchpad maXTouch di i2c
MODULES=(cros_ec_i2c cros_ec cros_ec_keyb rtc-cros-ec snd_soc_snow max98090 max98095
         mwifiex_sdio btmrvl_sdio atmel_mxt_ts exynos-tdc)

apply_modules() {
    local out="${TARGET_ROOTFS}/etc/modules-load.d/xe303os.conf"
    [ -f "${TARGET_ROOTFS}/etc/modules-load.d/xe303os.conf" ] && true
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "${TARGET_ROOTFS}/etc/modules-load.d"
    {
        echo "# XE303OS - modul yang di-load initrd/systemd"
        local m kver="$1" moddir="${TARGET_ROOTFS}/usr/lib/modules/$1"
        for m in "${MODULES[@]}"; do
            if [ -d "$moddir" ]; then
                if modinfo -k "$kver" "$m" >/dev/null 2>&1 || find "$moddir/kernel" -name "${m}.ko*" -print -quit 2>/dev/null | grep -q .; then
                    printf '%s\n' "$m"
                else
                    warn "modul '$m' tidak ada di kernel $kver (lewat)"
                fi
            else
                printf '%s\n' "$m"   # dry/pre-kernel: tulis saja, dpkg akan validasi nanti
            fi
        done
    } > "$out"
    info "modules-load.d -> $(grep -vc '^#' "$out" || true) modul"
}

# --- 2. parameter modul / penolakan fitur yang bikin macet --------------------
apply_modprobe() {
    local out="${TARGET_ROOTFS}/etc/modprobe.d/xe303os.conf"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "${TARGET_ROOTFS}/etc/modprobe.d"
    cat > "$out" <<'EOF'
# XE303OS - Exynos 5250 Chromebook
# WiFi Marvell: powersave agresif bikin disconnect + latency spike di mwifiex
options mwifiex_sdio ps_mode=0
# Bluetooth chip yang sama; kalau tidak dipakai, hemat RAM dengan memblokir
#blacklist btmrvl_sdio
# exynos-drm: jangan pakai CEC/HDMI audio utk panel internal
options exynosdrm hdmi_audio=0
# Panel eDP->LVDS (NXP PTN3460) butuh bridge aktif sejak awal
# (clk_ignore_unused sudah di cmdline; lihat config/kernel-cmdline.conf)
EOF
    info "modprobe.d ditulis"
}

# --- 3. kernel cmdline (dipakai u-boot/extlinux DAN depthchargectl) ---------
apply_cmdline() {
    local cl
    cl="$(__layout_cmdline) root=UUID=${ROOTFS_UUID} rootwait rw"
    local f
    for f in etc/kernel/cmdline etc/xe303os/cmdline; do
        [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s/%s\n' "$TARGET_ROOTFS" "$f"; continue; }
        mkdir -p "${TARGET_ROOTFS}/$(dirname "$f")"
        printf '%s\n' "$cl" > "${TARGET_ROOTFS}/$f"
    done
    info "cmdline: $cl"
}

# --- 4. device tree ---------------------------------------------------------
# Cari .dtb yang disediakan paket kernel Debian di /usr/lib/linux-image-<kver>/
apply_device_tree() {
    local kver="$1"
    local src="${TARGET_ROOTFS}/usr/lib/linux-image-${kver}"
    local dst="${TARGET_ROOTFS}/boot/dtb/xe303os"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  cp dtb dari %s ke %s\n' "$src" "$dst"; return 0
    fi
    [ -d "$src" ] || { warn "$src tidak ada - lewati (tahap bootimg akan cari lagi)"; return 0; }
    mkdir -p "$dst"
    local found=0 d
    for d in $DTB_CANDIDATES; do
        if [ -f "${src}/${d}" ]; then
            cp -f "${src}/${d}" "$dst/" && { info "DTB: $d"; found=$((found+1)); }
        else
            warn "DTB ${d} tidak ada di paket kernel"
        fi
    done
    if [ "$found" = "0" ]; then
        err "Tidak ada satu pun DTB kandidat ($DTB_CANDIDATES) di ${src}."
        err "Kernel Debian armmp harusnya menyertakan exynos5250-snow.dtb / exynos5800-peach-pi.dtb."
        return 1
    fi
    if [ "${DTB_PACK_ALL}" = "yes" ]; then
        # simpan juga semua dtb exynos utk jaga-jaga (rev4/rev5 snow, spring, peach)
        find "$src" -maxdepth 1 -name 'exynos*.dtb' -exec cp -f -t "$dst" {} + 2>/dev/null || true
        info "semua DTB exynos ikut dipaketkan ($(ls "$dst" | wc -l) file)"
    fi
}

# --- 5. firmware WiFi/BT check ------------------------------------------------
check_firmware() {
    local fwroot="${TARGET_ROOTFS}/usr/lib/firmware"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  cek firmware di %s\n' "$fwroot"; return 0; }
    local want=(mrvl/sd8797_uapsta.bin) f missing=()
    for f in "${want[@]}"; do
        [ -f "${fwroot}/${f}" ] || missing+=("$f")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "firmware hilang: ${missing[*]}"
        warn "pasang paket firmware-libertas di host lalu ulangi, atau salin manual ke /lib/firmware/mrvl/"
    else
        info "firmware WiFi (Marvell 88W8797) ada: mrvl/sd8797_uapsta.bin"
    fi
    if [ -d "${fwroot}" ]; then
        local n; n=$(find "${fwroot}" -name '*.bin' | wc -l)
        log "  total file firmware di image: $n"
    fi
}

# --- 6. audio: speaker max98090 default MUTE di mainline ---------------------
apply_audio() {
    copy_overlay "${OVERLAY_DIR}/usr/lib/xe303os/alsa-unmute.sh" \
                 "${TARGET_ROOTFS}/usr/lib/xe303os/alsa-unmute.sh"
    [ "${DRY_RUN}" = "1" ] && return 0
    chmod 755 "${TARGET_ROOTFS}/usr/lib/xe303os/alsa-unmute.sh"
    ln -sf ../xe303os-alsa.service "${TARGET_ROOTFS}/etc/systemd/system/multi-user.target.wants/xe303os-alsa.service" 2>/dev/null || {
        mkdir -p "${TARGET_ROOTFS}/etc/systemd/system/multi-user.target.wants"
        cp -f "${OVERLAY_DIR}/etc/systemd/system/xe303os-alsa.service" "${TARGET_ROOTFS}/etc/systemd/system/"
        ln -sf "../xe303os-alsa.service" "${TARGET_ROOTFS}/etc/systemd/system/multi-user.target.wants/xe303os-alsa.service"
    }
    info "service unmute speaker + restore state ALSA terpasang"
}

# --- 7. daya & umur eMMC ------------------------------------------------------
apply_power() {
    copy_overlay "${OVERLAY_DIR}/etc/udev/rules.d/70-xe303os-power.rules" \
                 "${TARGET_ROOTFS}/etc/udev/rules.d/70-xe303os-power.rules"
    copy_overlay "${OVERLAY_DIR}/etc/sysctl.d/99-xe303os.conf" \
                 "${TARGET_ROOTFS}/etc/sysctl.d/99-xe303os.conf"
    copy_overlay "${OVERLAY_DIR}/etc/systemd/journald.conf.d/99-xe303os.conf" \
                 "${TARGET_ROOTFS}/etc/systemd/journald.conf.d/99-xe303os.conf"
    info "udev (governor/IO-scheduler), sysctl, journald size-cap terpasang"
}

# --- 8. hook agar kernel upgrade tetap bootable ------------------------------
apply_kernel_hook() {
    copy_overlay "${OVERLAY_DIR}/etc/kernel/postinst.d/90-xe303os-boot" \
                 "${TARGET_ROOTFS}/etc/kernel/postinst.d/90-xe303os-boot"
    copy_overlay "${OVERLAY_DIR}/etc/kernel/prerm.d/90-xe303os-boot" \
                 "${TARGET_ROOTFS}/etc/kernel/prerm.d/90-xe303os-boot"
    copy_overlay "${OVERLAY_DIR}/usr/lib/xe303os/mkboot.sh" \
                 "${TARGET_ROOTFS}/usr/lib/xe303os/mkboot.sh"
    [ "${DRY_RUN}" = "1" ] || chmod 755 "${TARGET_ROOTFS}"/usr/lib/xe303os/mkboot.sh \
        "${TARGET_ROOTFS}"/etc/kernel/postinst.d/90-xe303os-boot 2>/dev/null || true
    info "/etc/kernel/postinst.d/90-xe303os-boot: rebuild /boot/<kver> + extlinux.conf"
}

# --- jalankan ---------------------------------------------------------------
kver=""
if [ "${DRY_RUN}" != "1" ]; then
    kver=$(ls -1 "${TARGET_ROOTFS}/usr/lib/" 2>/dev/null | sed -n 's/^linux-image-\(.*\)$/\1/p' | tail -1 || true)
    [ -n "$kver" ] || kver=$(ls -1 "${TARGET_ROOTFS}/boot/" 2>/dev/null | sed -n 's/^vmlinuz-//p' | tail -1 || true)
    if [ -z "$kver" ]; then
        warn "versi kernel belum terdeteksi (mungkin tahap packages belum jalan) - modul tidak difilter"
    else
        info "kernel target: $kver"
    fi
fi
apply_modules "${kver:-<kver>}"
apply_modprobe
apply_cmdline
apply_device_tree "${kver:-<kver>}"
check_firmware
apply_audio
apply_power
apply_kernel_hook

info "konfigurasi hardware selesai"
