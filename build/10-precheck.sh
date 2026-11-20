#!/usr/bin/env bash
# 10-precheck.sh - pastikan host build mampu menghasilkan image untuk XE303C12.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

step_banner "precheck: host build"

fail=0
ok()   { info "$*"; }
bad()  { err "$*"; fail=$((fail+1)); }
skip() { note "skip: $*"; }

# 1. Tool wajib
if command -v debootstrap >/dev/null 2>&1 || command -v mmdebstrap >/dev/null 2>&1; then
    ok "bootstrapper: $(command -v mmdebstrap >/dev/null 2>&1 && echo mmdebstrap || echo debootstrap)"
else
    bad "butuh debootstrap atau mmdebstrap  (sudo apt-get install -y debootstrap mmdebstrap)"
fi

if [ "${BOOT_MODE}" = "uboot-extlinux" ]; then
    for c in mkimage fdtget; do command -v "$c" >/dev/null 2>&1 || bad "butuh $c (apt-get install -y u-boot-tools)"; done
    command -v bunzip2 >/dev/null 2>&1 || [ "${UBOOT_PREBUILT_URL}" = "" ] && [ "${UBOOT_BUILD_FROM_SOURCE}" != "yes" ] \
        && bad "butuh bunzip2 untuk u-boot prebuilt (apt-get install -y bzip2)" || true
else
    for c in mkdepthcharge vbutil_kernel; do
        command -v "$c" >/dev/null 2>&1 || bad "butuh $c (apt-get install -y depthcharge-tools vboot-kernel-utils)"
    done
fi

for c in mkfs.ext2 mkfs.ext4 sfdisk truncate rsync xz sha256sum; do
    command -v "$c" >/dev/null 2>&1 || bad "butuh $c"
done

# 2. Root (debootstrap/mke2fs -d butuh root utk ownership & device node)
if [ "${DRY_RUN}" = "1" ]; then
    skip "cek root (dry-run)"
elif [ "$(id -u)" -eq 0 ]; then
    ok "berjalan sebagai root"
else
    bad "butuh root:  sudo -E make image   (debootstrap + mke2fs -d)"
fi

# 3. Cross-exec: binfmt/qemu untuk second-stage debootstrap armhf di host x86
hostarch=$(uname -m)
if [ "$hostarch" = "armv7l" ]; then
    ok "host sudah ARMv7 -> native bootstrap"
else
    if [ -f /usr/bin/qemu-arm-static ]; then
        if [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || [ -e /proc/sys/fs/binfmt_misc/qemu-arm-static ] \
           || ls /proc/sys/fs/binfmt_misc/ >/dev/null 2>&1; then
            ok "qemu-arm-static ada; binfmt_misc terpasang"
        else
            warn "qemu-arm-static ada tapi binfmt_misc tidak terlihat; mmdebstrap biasanya tetap jalan"
        fi
    else
        bad "host $hostarch tanpa qemu-arm-static  (apt-get install -y qemu-user-static binfmt-support)"
    fi
fi

# 4. Ruang disk: rootfs + boot + image mentah + xz
need_mb=$(( (ROOT_PART_MB + BOOT_PART_MB + 2*KERN_PART_MB) * 3 + 4096 ))
avail_mb=$(df -Pm "$WORK_DIR" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${avail_mb:-}" ]; then
    if [ "$avail_mb" -lt "$need_mb" ]; then
        bad "ruang disk kurang: perlu ~$((need_mb/1024)) GiB, tersedia ${avail_mb} MiB di ${WORK_DIR}"
    else
        ok "ruang disk cukup: ${avail_mb} MiB tersedia (perlu ~$((need_mb/1024)) GiB)"
    fi
else
    skip "cek ruang disk (df gagal)"
fi

# 5. Akses arsip Debian
if command -v curl >/dev/null 2>&1; then
    code=$(curl -m 12 -sS -o /dev/null -w '%{http_code}' "${DEBIAN_MIRROR}/dists/${SUITE}/Release" 2>/dev/null || echo 000)
    case "$code" in
        200) ok "mirror ${DEBIAN_MIRROR} suite ${SUITE}: 200" ;;
        000) warn "mirror tidak terjangkau dari host ini (offline sandbox?) - build butuh akses ${DEBIAN_MIRROR}" ;;
        *)   bad "mirror ${DEBIAN_MIRROR} suite ${SUITE} -> HTTP $code" ;;
    esac
fi

# 6. Konsistensi konfigurasi
if layout_validate; then :; else bad "konfigurasi layout tidak konsisten (lihat pesan di atas)"; fi

# 7. Reality check target hardware
step_banner "target hardware"
cat <<EOF
  Device : Samsung Chromebook Series 3 (XE303C12)
  SoC    : Exynos 5250, 2x Cortex-A15 @1.7GHz  -> ARMv7 hard-float  (arch=armhf)
  RAM    : 2 GB soldered  |  Storage: 16 GB eMMC  |  1366x768
  GPU    : Mali-T604 (Utgard) - TIDAK ada driver GL mainline => desktop tanpa GL
  Firmware: fork Das U-Boot (H2C), BUKAN coreboot+depthcharge
            => boot mode aktif: ${BOOT_MODE}
EOF
if [ "${ARCH}" != "armhf" ]; then
    bad "ARCH=${ARCH} salah untuk perangkat ini (harus armhf)"
fi
case "${BOOT_MODE}" in
    uboot-extlinux) ok "boot chain: U-Boot chainloading + extlinux (paling andal di snow/peach)";;
    vboot-direct)   warn "vboot-direct: di keluarga snow/peach firmware sering menolak kernel vboot (2x bip). Pakai hanya jika U-Boot tidak bisa."; ;;
    *) bad "BOOT_MODE tidak dikenal: ${BOOT_MODE}";;
esac

printf '\n'
if [ "$fail" -gt 0 ]; then
    err "precheck gagal di $fail point. Perbaiki lalu ulangi:  make precheck"
    exit 1
fi
info "precheck OK - siap bootstrap"
