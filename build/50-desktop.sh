#!/usr/bin/env bash
# 50-desktop.sh - X11 + desktop ringan tanpa OpenGL (Mali-T604 tak punya driver mainline).
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
step_banner "desktop: ${DESKTOP} (tanpa GL, fbdev/modesetting)"
require_root
mount_vfs "$TARGET_ROOTFS"
trap 'umount_vfs "$TARGET_ROOTFS"' EXIT

# --- 1. X server: modesetting di atas exynos-drm -----------------------------
write_xorg() {
    local out="${TARGET_ROOTFS}/etc/X11/xorg.conf.d/10-exynos.conf"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'EOF'
# XE303OS - panel internal 1366x768 via exynos-drm (DECON/FIMD).
# Mali-T604 tidak punya driver mainline => jangan harap GL; pakai render=software.
Section "Device"
    Identifier  "Exynos-FIMD"
    Driver      "modesetting"
    Option      "AccelMethod"     "none"
    Option      "SwapbuffersWait" "false"
    Option      "kms"             "true"
EndSection

Section "Monitor"
    Identifier  "LVDS-1"
    # panel 11.6" 1366x768, ~60Hz; hindari DPMS blank yang bikin bridge PTN3460 macet
    Option      "Ignore" "false"
    Modeline    "1366x768" 74.25 1366 1424 1474 1536 768 771 775 791 -hsync +vsync
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "Exynos-FIMD"
    Monitor     "LVDS-1"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1366x768"
    EndSubSection
EndSection

Section "Extensions"
    # GLX tanpa driver GL cuma bikin X crash di beberapa app
    Option "GLX" "Disable"
EndSection

Section "ServerFlags"
    Option  "DontZap"    "false"
    Option  "AllowMouseOpenFail" "true"
EndSection
EOF
    info "xorg.conf.d/10-exynos.conf ditulis"
}
write_xorg

# --- 2. libinput: touchpad maXTouch + tapping --------------------------------
write_libinput() {
    local out="${TARGET_ROOTFS}/etc/X11/xorg.conf.d/40-libinput.conf"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'EOF'
Section "InputClass"
    Identifier "xe303os touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "TappingButtonMap" "lrm"
    Option "NaturalScrolling" "on"
    Option "ClickMethod" "clickareas"
    Option "DisableWhileTyping" "on"
EndSection
Section "InputClass"
    Identifier "xe303os keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
    # Chromebook: Fn di baris atas -> kunci F1..F12 tetap normal via hwdb
    Option "XkbOptions" "lv3:ralt_switch"
EndSection
EOF
    info "libinput (tapping, clickareas, natural scroll) dikonfigurasi"
}
write_libinput

# --- 3. display manager + auto-login -----------------------------------------
configure_dm() {
    local t="${TARGET_ROOTFS}"
    if [ "${DRY_RUN}" = "1" ]; then printf 'DRY  configure lightdm + autologin=%s\n' "${AUTologin:-no}"; return 0; fi
    mkdir -p "${t}/etc/lightdm" "${t}/etc/systemd/system"
    {
        echo "[LightDM]"
        echo "greeter-hide-users=false"
        echo ""
        echo "[Seat:*]"
        echo "greeter-allow-guest=false"
        if [ "${AUTologin:-no}" = "yes" ]; then
            echo "autologin-user=${USERNAME}"
            echo "autologin-user-timeout=0"
            echo "# auto-login = tak ada greeter; aman untuk perangkat pribadi"
        fi
        echo "user-session=lxqt"
        [ "${DESKTOP}" = "xfce" ] && echo "user-session=xfce"
        [ "${DESKTOP}" = "openbox" ] && echo "user-session=openbox"
    } > "${t}/etc/lightdm/lightdm.conf"
    ln -sf /lib/systemd/system/lightdm.service "${t}/etc/systemd/system/display-manager.service"
    info "lightdm + auto-login user '${USERNAME}'; session=${DESKTOP}"
}
configure_dm

# --- 4. skel: preferensi desktop hemat resource ------------------------------
copy_overlay "${OVERLAY_DIR}/etc/skel" "${TARGET_ROOTFS}/etc/skel"
if [ "${DRY_RUN}" != "1" ]; then
    chown -R root:root "${TARGET_ROOTFS}/etc/skel" 2>/dev/null || true
fi

# --- 5. matikan service yang tak ada gunanya di perangkat ini ----------------
disable_services() {
    local t="${TARGET_ROOTFS}" s
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  mask/less service\n'; return 0; }
    mkdir -p "${t}/etc/systemd/system"
    # cups/avahi/spice/uDisks tak dipakai; each ~10-30MB RSS yang mahal di 2GB
    for s in cups.service cups.socket cups-browsed.service; do
        if [ -e "${t}/lib/systemd/system/${s}" ] || [ -e "${t}/usr/lib/systemd/system/${s}" ]; then
            printf '[Unit]\nDescription=%s (masked by XE303OS)\nAfter=dbus.service\n' "$s" > \
                "${t}/etc/systemd/system/${s}"
            echo "MaskedBy=XE303OS" >> "${t}/etc/systemd/system/${s}"
        fi
    done
    # udisks2 polling media bisa bikin wake-up; tetap aktifkan tapi tanpa swap detection
    mkdir -p "${t}/etc/udisks2"
    cat > "${t}/etc/udisks2/udisks2.conf" <<'EOF'
[udisks]
polling = 0
EOF
    info "service cetak/udisks polling dibatasi"
}
disable_services

# --- 6. tampilan: blanking + DPMS utk hemat batre -----------------------------
configure_dpms() {
    local t="${TARGET_ROOTFS}"
    local out="${t}/etc/X11/Xsession.d/90xe303os-dpms"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'EOF'
#!/bin/sh
# XE303OS: standby 10 menit (backlight PWM), screensaver off - panel eDP/PTN3460
# kadang tak kembali dari mode blank penuh, jadi kita cuma turunkan brightness.
if command -v xset >/dev/null 2>&1; then
    xset s off           >/dev/null 2>&1 || true
    xset -dpms           >/dev/null 2>&1 || true
    xset dpms 600 600 600 >/dev/null 2>&1 || true
fi
EOF
    chmod 755 "$out"
    info "Xsession.d dpms/backlight policy ditulis"
}
configure_dpms

# --- 7. verifikasi desktop terpasang ----------------------------------------
verify_desktop() {
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  verifikasi desktop %s\n' "$DESKTOP"; return 0; }
    local bin
    case "$DESKTOP" in
        lxqt)    bin=lxqt-session;;
        xfce)    bin=xfce4-session;;
        openbox) bin=openbox;;
        *)       die "DESKTOP tak dikenal: $DESKTOP";;
    esac
    if [ -x "${TARGET_ROOTFS}/usr/bin/${bin}" ] || [ -L "${TARGET_ROOTFS}/usr/bin/${bin}" ]; then
        info "session '${bin}' ada"
    else
        warn "${bin} tidak ditemukan di /usr/bin - cek config/packages/desktop-${DESKTOP}.list"
    fi
}
verify_desktop

info "desktop siap (${DESKTOP}); tanpa OpenGL, tanpa compositor"
