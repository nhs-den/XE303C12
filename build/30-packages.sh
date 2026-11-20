#!/usr/bin/env bash
# 30-packages.sh - pasang paket basis + kernel + dukungan hardware + desktop.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
[ -d "$TARGET_ROOTFS" ] || die "rootfs belum ada ($TARGET_ROOTFS). Jalankan tahap rootfs dulu."

step_banner "packages: install ke ${TARGET_ROOTFS}"
require_root
mount_vfs "$TARGET_ROOTFS"
trap 'umount_vfs "$TARGET_ROOTFS"' EXIT

# --- baca daftar paket -------------------------------------------------------
read_list() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed 's/#.*$//' "$f" | tr -d '\r' | awk 'NF' | sort -u
}

pkg_available() {  # nama paket ada di arsip?
    chroot_run "$TARGET_ROOTFS" apt-cache show "$1" >/dev/null 2>&1
}

install_strict() {   # gagal = build gagal
    local -a pkgs=()
    local p
    for p in "$@"; do pkgs+=("$p"); done
    [ ${#pkgs[@]} -eq 0 ] && return 0
    note "install (strict): ${#pkgs[@]} paket"
    apt_install "$TARGET_ROOTFS" "${pkgs[@]}"
}

install_tolerant() { # paket tak dikenal dilewati dengan peringatan
    local p missing=()
    for p in "$@"; do
        if pkg_available "$p"; then
            apt_install "$TARGET_ROOTFS" "$p" || { warn "gagal install $p (dilewati)"; continue; }
        else
            missing+=("$p")
        fi
    done
    [ ${#missing[@]} -gt 0 ] && warn "tidak ada di arsip ${SUITE}/${ARCH}: ${missing[*]}"
    return 0
}

# --- blocklist: jangan pernah tarik DE berat ke perangkat 2GB ---------------
write_blocklist() {
    local list="${CONFIG_DIR}/packages/blocklist.list"
    local out="${TARGET_ROOTFS}/etc/apt/preferences.d/99xe303os-block"
    [ -f "$list" ] || return 0
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$out"; return 0; }
    : > "$out"
    local p
    for p in $(read_list "$list"); do
        cat >> "$out" <<EOF

Package: $p
Pin: release *
Pin-Priority: -1
EOF
    done
    info "blocklist apt: $(grep -c '^Package:' "$out") paket ditahan"
}

# --- urutan install ----------------------------------------------------------
apt_in "$TARGET_ROOTFS" update
write_blocklist

BASE_PKGS=($(read_list "${CONFIG_DIR}/packages/base.list"))
HW_PKGS=($(read_list "${CONFIG_DIR}/packages/hardware.list"))
DESKTOP_LIST="${CONFIG_DIR}/packages/desktop-${DESKTOP}.list"
[ -f "$DESKTOP_LIST" ] || die "daftar desktop tidak ada: $DESKTOP_LIST (DESKTOP=lxqt|xfce|openbox)"
DESKTOP_PKGS=($(read_list "$DESKTOP_LIST"))

note "kernel: ${KERNEL_META}"
install_strict "$KERNEL_META"          # tanpa kernel tidak ada image -> hard fail
install_strict initramfs-tools linux-base   # dipakai hook /etc/kernel/postinst.d
install_tolerant "${BASE_PKGS[@]}"     # nama paket bisa beda antar suite
install_tolerant "${HW_PKGS[@]}"
install_tolerant "${DESKTOP_PKGS[@]}"

# verifikasi kritis: kalau salah satu absen, image tidak akan berguna
CRITICAL=("$KERNEL_META" initramfs-tools lightdm alsa-utils network-manager)
[ "${DESKTOP}" != "openbox" ] && CRITICAL+=("xserver-xorg-video-modesetting")
missing=()
for p in "${CRITICAL[@]}"; do
    if [ "${DRY_RUN}" = "1" ]; then continue; fi
    chroot_run "$TARGET_ROOTFS" dpkg -l "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    err "paket kritis belum terpasang: ${missing[*]}"
    err "cek network/arsip, atau sesuaikan config/packages/*.list untuk ${SUITE}"
    exit 1
fi
info "paket kritis OK: ${CRITICAL[*]}"

if [ "${BROWSER}" != "none" ] && [ -n "${BROWSER}" ]; then
    install_tolerant "$BROWSER"
fi
if [ "${EXTRA:-no}" = "yes" ]; then
    install_tolerant $(read_list "${CONFIG_DIR}/packages/recommended.list")
fi

# initramfs: modular + hemat (tanpa module autoload berlebihan utk eMMC)
if [ "${DRY_RUN}" != "1" ]; then
    mkdir -p "${TARGET_ROOTFS}/etc/initramfs-tools"
    cat > "${TARGET_ROOTFS}/etc/initramfs-tools/conf.d/xe303os" <<'EOF'
# XE303OS: initramfs sekecil mungkin, semua driver exynos/mmc built-in atau modular
MODULES=dep
EOF
    cat > "${TARGET_ROOTFS}/etc/initramfs-tools/scripts/init-bottom/xe303os-umount" <<'EOF'
#!/bin/sh
# pastikan /boot tidak mount-anomali saat pivot
PREROOT="$1"
[ -d "$PREROOT/boot" ] && mountpoint -q "$PREROOT/boot" && umount -l "$PREROOT/boot" 2>/dev/null
exit 0
EOF
    chmod +x "${TARGET_ROOTFS}/etc/initramfs-tools/scripts/init-bottom/xe303os-umount"
fi

step_banner "ringkasan ukuran"
if [ "${DRY_RUN}" != "1" ]; then
    du -sh --exclude=proc --exclude=sys --exclude=dev "${TARGET_ROOTFS}" 2>/dev/null |
        awk '{printf "  rootfs saat ini: %s\n", $1}'
    free_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    log "  (RAM host ${free_mb} MiB - tidak relevan, target 2 GiB)"
fi

apt_in "$TARGET_ROOTFS" clean
apt_in "$TARGET_ROOTFS" autoclean || true
info "paket terpasang"
