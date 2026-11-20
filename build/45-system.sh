#!/usr/bin/env bash
# 45-system.sh - konfigurasi sistem dasar (user, locale, storage, jaringan, first boot).
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
step_banner "system: user, locale, storage, jaringan"
require_root
mount_vfs "$TARGET_ROOTFS"
trap 'umount_vfs "$TARGET_ROOTFS"' EXIT

# --- overlay umum ------------------------------------------------------------
for f in etc/default/keyboard etc/hosts etc/nsswitch.conf etc/systemd/system/xe303os-firstboot.service; do
    [ -e "${OVERLAY_DIR}/$f" ] && copy_overlay "${OVERLAY_DIR}/$f" "${TARGET_ROOTFS}/$f"
done
copy_overlay "${OVERLAY_DIR}/etc/skel" "${TARGET_ROOTFS}/etc/skel"
copy_overlay "${OVERLAY_DIR}/usr/lib/xe303os/firstboot.sh" "${TARGET_ROOTFS}/usr/lib/xe303os/firstboot.sh"
if [ "${DRY_RUN}" != "1" ]; then
    mkdir -p "${TARGET_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf "../xe303os-firstboot.service" \
        "${TARGET_ROOTFS}/etc/systemd/system/multi-user.target.wants/xe303os-firstboot.service"
    chmod 755 "${TARGET_ROOTFS}/usr/lib/xe303os/firstboot.sh"
fi
info "overlay /etc + /usr/lib/xe303os tersalin"

# --- fstab: rootfs + /boot + tmpfs di RAM (hemat eMMC) ----------------------
write_fstab() {
    local out="${TARGET_ROOTFS}/etc/fstab"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    cat > "$out" <<EOF
# XE303OS - dibuat saat build. root di-UUID agar tahan perubahan partisi.
UUID=${ROOTFS_UUID}  /      ${ROOT_FS}  defaults,noatime,errors=remount-ro,commit=60  0 1
PARTUUID=${BOOT_PARTUUID}  /boot  ${BOOT_FS}  defaults,noatime,nofail  0 2
# /tmp di RAM (2 GiB): hemat tulis-eMMC, batasi biar tak habiskan RAM
tmpfs  /tmp  tmpfs  nodev,nosuid,size=256M,mode=1777  0 0
# swap TIDAK di eMMC - pakai zram (lihat /etc/default/zramswap)
EOF
    info "/etc/fstab ditulis (root UUID=${ROOTFS_UUID})"
}
write_fstab

# --- hostname / locale / tz / keyboard ---------------------------------------
apply_locale() {
    local t="$TARGET_ROOTFS"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  locale/tz/keyboard\n'; return 0; }
    printf '%s\n' "${HOSTNAME}" > "${t}/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "${HOSTNAME}" > "${t}/etc/hosts"
    echo "${LOCALE} UTF-8" > "${t}/etc/locale.gen"
    grep -q '^en_US.UTF-8' "${t}/etc/locale.gen" 2>/dev/null || echo "en_US.UTF-8 UTF-8" >> "${t}/etc/locale.gen"
    chroot_run "$t" locale-gen >/dev/null 2>&1 || warn "locale-gen gagal (mungkin belum ada locales)"
    chroot_run "$t" update-locale LANG="${LOCALE}" LC_MESSAGES=POSIX || true
    ln -sff "/usr/share/zoneinfo/${TIMEZONE}" "${t}/etc/localtime" 2>/dev/null || \
        { mkdir -p "${t}/etc"; cp -f "/usr/share/zoneinfo/${TIMEZONE}" "${t}/etc/localtime" 2>/dev/null || true; }
    printf '%s\n' "${TIMEZONE}" > "${t}/etc/timezone"
    info "hostname=${HOSTNAME} locale=${LOCALE} tz=${TIMEZONE}"
}
apply_locale

# --- user --------------------------------------------------------------------
apply_users() {
    local t="$TARGET_ROOTFS"
    if [ "${DRY_RUN}" = "1" ]; then printf 'DRY  buat user %s + passwd\n' "$USERNAME"; return 0; fi
    if ! chroot_run "$t" id "$USERNAME" >/dev/null 2>&1; then
        chroot_run "$t" useradd -m -s /bin/bash -G sudo,plugdev,netdev,audio,video "$USERNAME"
    fi
    printf '%s:%s\n' "$USERNAME" "$USERPASS" | chroot_run "$t" chpasswd
    printf 'root:%s\n' "$ROOTPASS" | chroot_run "$t" chpasswd
    chroot_run "$t" chfn -f "${USERFULLNAME}" "$USERNAME" >/dev/null 2>&1 || true
    # sudo tanpa password utk user pertama (perangkat pribadi; matikan bila perlu)
    cat > "${t}/etc/sudoers.d/90-xe303os" <<EOF
${USERNAME} ALL=(ALL) NOPASSWD:ALL
Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 440 "${t}/etc/sudoers.d/90-xe303os"
    info "user '${USERNAME}' (sudo nopasswd) - password default '${USERPASS}'"
    printf '\n%s\n' "!! PASSWORD DEFAULT AKTIF. Ganti setelah boot pertama: passwd ${USERNAME}" >&2
}
apply_users

# --- SSH ---------------------------------------------------------------------
apply_ssh() {
    local t="$TARGET_ROOTFS"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  ssh=%s\n' "$SSH"; return 0; }
    if [ "${SSH}" = "enable" ]; then
        mkdir -p "${t}/etc/systemd/system/multi-user.target.wants"
        ln -sf /lib/systemd/system/sshd.service "${t}/etc/systemd/system/multi-user.target.wants/sshd.service"
        # host key dibuat saat first boot (lihat firstboot.sh) supaya tiap unit beda
        rm -f "${t}"/etc/ssh/ssh_host_*
        info "sshd diaktifkan (host key digenerate saat boot pertama)"
    else
        chroot_run "$t" systemctl disable ssh.service >/dev/null 2>&1 || true
        note "sshd tidak diaktifkan"
    fi
}
apply_ssh

# --- zram (RAM 2GB => wajib) + earlyoom --------------------------------------
apply_memory() {
    local t="$TARGET_ROOTFS"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  zram=%sMB earlyoom=%s\n' "$ZRAM_SIZE_MB" "$EARLYOOM"; return 0; }
    mkdir -p "${t}/etc/default"
    cat > "${t}/etc/default/zramswap" <<EOF
# XE303OS: zramswap sebesar ${ZRAM_SIZE_MB}MB, lzo-rle (murah di Cortex-A15)
ALGO=lzo-rle
SIZE=${ZRAM_SIZE_MB}M
PRIORITY=100
EOF
    if [ "${EARLYOOM}" = "yes" ]; then
        apt_install "$t" earlyoom >/dev/null 2>&1 || warn "earlyoom tidak terpasang"
        mkdir -p "${t}/etc/default"
        cat > "${t}/etc/default/earlyoom" <<'EOF'
# bunuh proses raksaat sebelum sistem freeze (-m 5 = sisa RAM 5%)
OPTS="-m 5 -M 300 --avoid '(^(systemd|dbus|NetworkManager|X11|lxqt|xfce))' --prefer '(firefox|chromium)"
EOF
        ln -sf /lib/systemd/system/earlyoom.service "${t}/etc/systemd/system/multi-user.target.wants/earlyoom.service" 2>/dev/null || true
    fi
    info "zram ${ZRAM_SIZE_MB}MB (lzo-rle) + earlyoom=${EARLYOOM}"
}
apply_memory

# --- WiFi preseed (headless install) -----------------------------------------
apply_wifi() {
    [ -z "${WIFI_SSID}" ] && { note "WIFI_SSID kosong -> tidak ada preconnect (isi utk install headless)"; return 0; }
    local t="$TARGET_ROOTFS"
    local out="${t}/etc/NetworkManager/system-connections/xe303os-0.nmconnection"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<EOF
[connection]
id=xe303os-0
type=wifi
permissions=

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSPHRASE}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    chmod 600 "$out"; chown root:root "$out" 2>/dev/null || true
    info "profil WiFi '${WIFI_SSID}' dipreseed (mode 600)"
}
apply_wifi

# --- timer yang bikin eMMC capek ----------------------------------------------
mask_timers() {
    local t="$TARGET_ROOTFS"
    local s
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  mask timer apt/fstrim-manual\n'; return 0; }
    mkdir -p "${t}/etc/systemd/system"
    for s in apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer; do
        ln -sf /dev/null "${t}/etc/systemd/system/${s}"
    done
    # fstrim 1x/minggu justru bagus utk eMMC: biarkan timer-nya
    info "apt-daily timer di-mask (update manual: apt update && apt full-upgrade)"
}
mask_timers

# --- pesan login singkat ------------------------------------------------------
write_motd() {
    local t="$TARGET_ROOTFS"
    local out="${t}/etc/xe303os/motd"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  tulis %s\n' "$out"; return 0; }
    mkdir -p "${t}/etc/xe303os"
    cat > "$out" <<EOF
${DISTRO_LABEL} ${VERSION} - Samsung Chromebook Series 3 (XE303C12, Exynos 5250 / armhf)
  kapasitas : RAM 2 GiB (zram ${ZRAM_SIZE_MB} MiB aktif) | eMMC 16 GiB | tanpa OpenGL (Mali-T604)
  cepat     : df -h /              sudo tools/device-status.sh        sudo apt update
  audio     : sudo /usr/lib/xe303os/alsa-unmute.sh   (speaker default kernel itu BISU)
  kernel    : jangan full-upgrade tanpa membaca docs/troubleshooting.md #8
  ganti pwd : passwd
EOF
    info "/etc/xe303os/motd ditulis"
}
write_motd

# --- bersih-bersih ------------------------------------------------------------
finalize() {
    local t="$TARGET_ROOTFS"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  finalize rootfs\n'; return 0; }
    rm -f "${t}/etc/ssh/ssh_host_"* 
    : > "${t}/etc/machine-id"
    rm -f "${t}/var/lib/dbus/machine-id" 2>/dev/null || true
    rm -rf "${t}/var/cache/apt/archives/"* 2>/dev/null || true
    find "${t}/var/log" -mindepth 1 -not -name 'README*' -delete 2>/dev/null || true
    info "machine-id dikosongkan, cache/log dibersihkan"
}
finalize

info "konfigurasi sistem selesai"
