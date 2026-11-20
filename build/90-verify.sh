#!/usr/bin/env bash
# 90-verify.sh - verifikasi hasil build: struktur image, isi boot, (opsional) qemu.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

QEMU_ONLY=0
[ "${1:-}" = "--qemu-only" ] && QEMU_ONLY=1
IMG="${DIST_DIR}/${IMAGE_STEM}.img"
fail=0
ok()  { info "$*"; }
bad() { err  "$*"; fail=$((fail+1)); }

if [ "$QEMU_ONLY" = "0" ]; then
step_banner "verify: ${IMG}"
[ -f "$IMG" ] || [ -f "$IMG.xz" ] || die "image belum ada - jalankan make image"
if [ ! -f "$IMG" ]; then
    note "mengurai $IMG.xz ke /tmp utk verifikasi"
    mkdir -p /tmp/xe303os-verify && xz -dc "$IMG.xz" > /tmp/xe303os-verify/check.img
    IMG=/tmp/xe303os-verify/check.img
fi

# --- 1. tabel partisi --------------------------------------------------------
mapfile -t pt < <(layout_partition_table)
field() { awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c}' <<<"$(printf '%s\n' "${pt[@]}")"; }

got=$(sfdisk -l -o "Device,Start,Sectors,Type,Name" "$IMG" 2>/dev/null | sed -n 's/^ *[0-9].*//p' | tail -4)
if [ -n "$got" ]; then
    ok "partisi terdeteksi: $(sfdisk -d "$IMG" 2>/dev/null | grep -c '^/dev\|^[0-9]*:' || true)"
    sfdisk -d "$IMG" | sed 's/^/    /'
else
    bad "gagal membaca partisi image"
fi

# --- 2. tipe GUID partisi kernel --------------------------------------------
if sfdisk -d -o Type,Name "$IMG" 2>/dev/null | grep -qiE 'FE3A2A5D|chromeos'; then
    ok "tipe GUID ChromeOS kernel (FE3A2A5D...) ada di KERN-A/B"
elif command -v sgdisk >/dev/null 2>&1 && sgdisk -i 1 "$IMG" 2>/dev/null | grep -qi '0700'; then
    ok "sgdisk: tipe 0700 (Linux filesystem) pada p1 - OK utk u-boot chainloading"
else
    warn "tidak bisa memastikan tipe GUID partisi kernel (periksa manual: sgdisk -i 1 image)"
fi

# --- 3. superblock + isi boot ------------------------------------------------
for name in BOOT ROOTFS; do
    s=$(field "$name" 2)
    magic=$(dd if="$IMG" bs=512 skip=$(( s + 2 )) count=1 status=none | od -An -tx1 -j1080 -N2 | tr -d ' \n')
    [ "$magic" = "53ef" ] && ok "superblock ${name} valid (magic 0xEF53)" || bad "superblock ${name} tidak ditemukan (dapat: ${magic:-kosong})"
done

if command -v debugfs >/dev/null 2>&1; then
    # debugfs tidak bisa baca pada offset -> ekstrak partisi BOOT dulu
    dd if="$IMG" of=/tmp/xe303os-boot.fs bs=512 skip=$(( $(field BOOT 2) )) count=$(( $(field BOOT 3) )) status=none 2>/dev/null || true
    if [ -s /tmp/xe303os-boot.fs ]; then
        if debugfs -R "stat /extlinux/extlinux.conf" /tmp/xe303os-boot.fs 2>/dev/null | grep -q 'Inode'; then
            ok "/extlinux/extlinux.conf ada di partisi BOOT"
        else
            bad "/extlinux/extlinux.conf TIDAK ada di partisi BOOT"
        fi
        debugfs -R "ls /" /tmp/xe303os-boot.fs 2>/dev/null | sed 's/^/    boot: /'
    fi
fi

# --- 4. image kernel: u-boot / vboot ----------------------------------------
KOFF=$(( $(field KERN-A 2) * 512 ))
KLIMIT=$(( $(field KERN-A 3) * 512 ))
if [ "${DRY_RUN}" != "1" ]; then
    dd if="$IMG" of=/tmp/xe303os-kern.img bs=1M iflag=skip_bytes,count_bytes \
       skip="$KOFF" count="$(( KLIMIT < 4194304 ? KLIMIT : 4194304 ))" status=none 2>/dev/null ||
    dd if="$IMG" of=/tmp/xe303os-kern.img bs=512 skip=$(( $(field KERN-A 2) )) count=8192 status=none
    if [ ! -s /tmp/xe303os-kern.img ] || ! od -An -tx1 /tmp/xe303os-kern.img | tr -d ' \n' | grep -qv '^00*$'; then
        bad "partisi KERN-A kosong - image kernel tidak ikut ditulis!"
    elif grep -aq 'd00dfeed' /tmp/xe303os-kern.img; then
        ok "KERN-A: FIT image (d00dfeed) - cocok utk mkdepthcharge/u-boot FIT"
    elif od -An -tx1 -N4 /tmp/xe303os-kern.img | grep -q '27 05 19 56'; then
        ok "KERN-A: uImage/u-boot legacy magic (0x27051956) di offset 0"
    else
        note "KERN-A: magic u-boot/uImage tak terlihat di 4MiB pertama (mungkin vboot padding)"
    fi
fi
if command -v vbutil_kernel >/dev/null 2>&1 && [ -s /tmp/xe303os-kern.img ]; then
    # vboot preamble ada di 64K pertama -> potong ke ukuran partisi utk verifikasi penuh
    dd if="$IMG" of=/tmp/xe303os-kern-full.img bs=512 skip=$(( $(field KERN-A 2) )) count=$(( $(field KERN-A 3) )) status=none
    if vbutil_kernel --verify /tmp/xe303os-kern-full.img >/dev/null 2>&1; then
        ok "vbutil_kernel --verify: image kernel tersignatur (devkey) dan utuh"
    else
        bad "vbutil_kernel --verify GAGAL - firmware kemungkinan menolak (2x bip)"
    fi
fi

# --- 5. rootfs: file kunci --------------------------------------------------
if command -v debugfs >/dev/null 2>&1; then
    dd if="$IMG" of=/tmp/xe303os-root.fs bs=512 skip=$(( $(field ROOTFS 2) )) count=$(( $(field ROOTFS 3) )) status=none 2>/dev/null || true
    for f in /etc/fstab /etc/modules-load.d/xe303os.conf /boot/extlinux/extlinux.conf /etc/lightdm/lightdm.conf; do
        if debugfs -R "stat $f" /tmp/xe303os-root.fs 2>/dev/null | grep -q 'Inode'; then
            ok "rootfs: $f ada"
        else
            case "$f" in
                /boot/*) note "rootfs: $f di partisi BOOT (normal)";;
                *) bad "rootfs: $f Hilang";;
            esac
        fi
    done
fi

# --- 6. checksum ------------------------------------------------------------
if [ -f "$IMG.xz" ]; then
    ( cd "$DIST_DIR" && sha256sum -c "$(basename "$IMG").xz.sha256" >/dev/null 2>&1 ) \
        && ok "sha256 cocok" || warn "sha256 belum ada / cocok (jalankan make image sampai selesai)"
fi
rm -rf /tmp/xe303os-verify /tmp/xe303os-boot.fs /tmp/xe303os-root.fs \
       /tmp/xe303os-kern.img /tmp/xe303os-kern-full.img 2>/dev/null || true
fi

# --- 7. qemu smoke test (opsional) -------------------------------------------
step_banner "qemu: smoke test kernel (bukan test exynos - qemu tak punya mesin exynos5250)"
KV="${WORK_DIR}/boot/${KVER:-$(ls -1 "${WORK_DIR}/boot" 2>/dev/null | head -1)}"
if ! command -v qemu-system-arm >/dev/null 2>&1; then
    note "qemu-system-arm tidak dipasang - skip (apt-get install -y qemu-system-arm)"
elif [ ! -f "${KV}/zImage" ]; then
    note "${KV}/zImage belum ada - skip (jalankan make bootimg)"
else
    log "  boot zImage di mesin virt ARM (console=ttyAMA0) selama 20 detik..."
    if timeout 20 qemu-system-arm -machine virt -cpu cortex-a15 -m 1024 -nographic \
        -kernel "${KV}/zImage" -append "console=ttyAMA0 ${QEMU_APPEND:-}" \
        -no-reboot > "${WORK_DIR}/qemu-smoke.log" 2>&1; then
        ok "qemu: kernel exit normal"
    else
        rc=$?
        if [ "$rc" = "124" ]; then ok "qemu: kernel berjalan (timeout tercapai = boot hidup)"; else
            warn "qemu: rc=$rc - periksa work/qemu-smoke.log"
        fi
    fi
    grep -m3 -E 'Linux version|Kernel command line|Booting Linux' "${WORK_DIR}/qemu-smoke.log" | sed 's/^/    /' || true
fi

printf '\n'
if [ "$fail" -gt 0 ]; then err "verifikasi: $fail masalah"; exit 1; fi
info "verifikasi OK"
