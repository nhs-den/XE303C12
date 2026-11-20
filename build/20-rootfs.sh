#!/usr/bin/env bash
# 20-rootfs.sh - buat rootfs Debian ${SUITE}/${ARCH} (armhf) dengan debootstrap/mmdebstrap.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TARGET_ROOTFS="${TARGET_ROOTFS:-${WORK_DIR}/rootfs}"
step_banner "rootfs: bootstrap ${SUITE}/${ARCH} -> ${TARGET_ROOTFS}"
require_root

mkdir -p "$WORK_DIR"
if [ -d "$TARGET_ROOTFS" ] && [ -n "$(ls -A "$TARGET_ROOTFS" 2>/dev/null || true)" ]; then
    warn "${TARGET_ROOTFS} sudah ada - dihapus lalu bootstrap ulang"
    run rm -rf "$TARGET_ROOTFS"
fi
run mkdir -p "$TARGET_ROOTFS"

# --- sumber paket utk target ------------------------------------------------
write_sources() {
    local dst="${TARGET_ROOTFS}/etc/apt/sources.list.d"
    local f="${dst}/debian.sources"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$f"; return 0; }
    mkdir -p "$dst" "${TARGET_ROOTFS}/etc/apt/apt.conf.d"
    cat > "$f" <<EOF
Types: deb
URIs: ${DEBIAN_MIRROR}
Suites: ${SUITE}
Components: ${COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${SECURITY_MIRROR}
Suites: ${SUITE}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    printf 'APT::Install-Recommends "%s";\n' "${APT_RECOMMENDS}" > \
        "${TARGET_ROOTFS}/etc/apt/apt.conf.d/99xe303os"
    printf 'Acquire::Retries "%s";\n' "${APT_RETRIES}" >> \
        "${TARGET_ROOTFS}/etc/apt/apt.conf.d/99xe303os"
    info "sources ditulis: $f"
}
write_sources

# --- cegah service dicoba start selama build --------------------------------
block_services() {
    local f="${TARGET_ROOTFS}/usr/sbin/policy-rc.d"
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  write %s\n' "$f"; return 0; }
    mkdir -p "${TARGET_ROOTFS}/usr/sbin"
    cat > "$f" <<'EOF'
#!/bin/sh
# XE303OS build: jangan start/stop service di dalam chroot
exit 101
EOF
    chmod 755 "$f"
}
block_services

# --- bootstrap --------------------------------------------------------------
bootstrap_mmdebstrap() {
    local comps inc
    comps=$(printf '%s' "${COMPONENTS}" | tr ' ' ',')
    note "mmdebstrap --format=directory (native cross-arch, tanpa second-stage)"
    run mmdebstrap \
        --architecture="$ARCH" \
        --format=directory \
        --components="$comps" \
        --aptopt="Acquire::Retries '${APT_RETRIES}'" \
        --skip=update \
        --skip=customize \
        --variant=minbase \
        "$SUITE" "$TARGET_ROOTFS" "$DEBIAN_MIRROR"
}

bootstrap_debootstrap() {
    # debootstrap di bookworm belum tentu punya script utk suite lebih baru
    local scripts_dir
    scripts_dir=$(dpkg -L debootstrap 2>/dev/null | sed -n 's|/scripts/.*||;1p')
    scripts_dir=${scripts_dir:-/usr/share/debootstrap}/scripts
    if [ ! -e "${scripts_dir}/${SUITE}" ] && [ "${DRY_RUN}" != "1" ]; then
        warn "debootstrap tanpa script '${SUITE}' -> symlink ke sid"
        ln -sf "${scripts_dir}/sid" "${scripts_dir}/${SUITE}"
    fi
    run debootstrap \
        --arch="$ARCH" \
        --foreign \
        --variant=minbase \
        --components="$(printf '%s' "${COMPONENTS}" | tr ' ' ',')" \
        --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
        "$SUITE" "$TARGET_ROOTFS" "$DEBIAN_MIRROR"

    # stage 2 butuh eksekusi binary armhf -> qemu-user-static
    if [ "$(uname -m)" != "armv7l" ]; then
        require_cmd qemu-arm-static || true
        run cp -a /usr/bin/qemu-arm-static "${TARGET_ROOTFS}/usr/bin/qemu-arm-static"
        printf 'xe303os-qemu-static\n' > "${TARGET_ROOTFS}/.xe303os-qemu"
    fi
    mount_vfs "$TARGET_ROOTFS"
    [ -f "${TARGET_ROOTFS}/etc/resolv.conf" ] || run cp /etc/resolv.conf "${TARGET_ROOTFS}/etc/resolv.conf"
    chroot_run "$TARGET_ROOTFS" /debootstrap/debootstrap --second-stage
    umount_vfs "$TARGET_ROOTFS"
}

if command -v mmdebstrap >/dev/null 2>&1; then
    bootstrap_mmdebstrap
    # mmdebstrap --skip=customize tidak menjalankan dpkg --configure; lakukan manual
    if [ "$(uname -m)" != "armv7l" ] && [ "${DRY_RUN}" != "1" ]; then
        run cp -a /usr/bin/qemu-arm-static "${TARGET_ROOTFS}/usr/bin/qemu-arm-static"
        printf 'xe303os-qemu-static\n' > "${TARGET_ROOTFS}/.xe303os-qemu"
    fi
    mount_vfs "$TARGET_ROOTFS"
    chroot_run "$TARGET_ROOTFS" dpkg --configure -a || true
    umount_vfs "$TARGET_ROOTFS"
else
    bootstrap_debootstrap
fi

# --- sanity -----------------------------------------------------------------
step_banner "sanity rootfs"
if [ "${DRY_RUN}" = "1" ]; then
    note "DRY verifikasi rootfs"
else
    [ -x "${TARGET_ROOTFS}/bin/sh" ] || die "rootfs tidak valid: /bin/sh tidak executable"
    arch_in=$(chroot "$TARGET_ROOTFS" uname -m 2>/dev/null || file -b "${TARGET_ROOTFS}/bin/sh" | sed 's/,.*//')
    log "  arsitektur binari: ${arch_in}"
    case "${arch_in}" in
        armv7*|*ARM*) info "binari ARMv7 - sesuai XE303C12";;
        *) warn "binari terlihat '${arch_in}'; harusnya ARM. Cek --arch=$ARCH";;
    esac
    : "${TARGET_ROOTFS}/etc/hostname"
    printf '%s\n' "${HOSTNAME}" > "${TARGET_ROOTFS}/etc/hostname"
    n=$(chroot "$TARGET_ROOTFS" dpkg-query -f '${binary:Package}\n' -W 2>/dev/null | wc -l)
    info "paket basis terpasang: $n"
fi

info "rootfs siap di ${TARGET_ROOTFS}"
