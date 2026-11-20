#!/bin/bash
# /usr/lib/xe303os/mkboot.sh - (re)buat isi partisi BOOT supaya kernel baru tetap boot.
#
# Dipanggil oleh /etc/kernel/postinst.d/90-xe303os-boot saat `apt full-upgrade`,
# dan bisa dipanggil manual:  sudo /usr/lib/xe303os/mkboot.sh [kver]
#
# Kenapa ini ada: di XE303C12 tidak ada GRUB. Yang dibaca firmware/u-boot adalah
# /boot/extlinux/extlinux.conf + file di dalam partisi BOOT (bagian depan /boot).
# Tanpa hook ini, upgrade kernel = sistem mati diam-diam saat reboot.
set -uo pipefail

PRUNE=0
ZIMAGE=""
VERSIONS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --prune) PRUNE=1;;
        --zimage) ZIMAGE="$2"; shift;;
        -h|--help) sed -n '2,12p' "$0"; exit 0;;
        *) VERSIONS+=("$1");;
    esac
    shift
done

BOOT=${BOOT_DIR:-/boot}
DTB_SRC_GLOB='exynos5250-*.dtb exynos5420-*.dtb exynos5422-*.dtb exynos5800-*.dtb'
CMDLINE_FILE=/etc/xe303os/cmdline
[ -r /etc/kernel/cmdline ] && CMDLINE_FILE=/etc/kernel/cmdline
log() { printf 'mkboot: %s\n' "$*"; }
die() { printf 'mkboot: ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$BOOT" ] || die "$BOOT tidak ada"
if ! mountpoint -q "$BOOT"; then
    log "$BOOT bukan partisi terpisah - menulis ke rootfs (tetap berguna utk flow env.txt)"
fi

# --- pilih versi kernel ------------------------------------------------------
if [ ${#VERSIONS[@]} -eq 0 ]; then
    mapfile -t VERSIONS < <(ls -1 "$BOOT"/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V)
fi
[ ${#VERSIONS[@]} -gt 0 ] || die "tidak ada /boot/vmlinuz-* - install kernel dulu"

# --- pruner: simpan 2 kernel terbaru saja (eMMC 16GB!) ----------------------
if [ "$PRUNE" = "1" ]; then
    keep=$(ls -1 "$BOOT" 2>/dev/null | sed -n 's|^vmlinuz-||p' | sort -V | tail -2 | tr '\n' ' ')
    running=$(uname -r)
    for v in "${VERSIONS[@]}"; do
        case "$keep" in *"$v"*) continue;; esac
        [ "$v" = "$running" ] && continue
        log "prune $v (dipertahankan: ${keep% })"
        rm -rf "${BOOT}/${v}"
    done
fi

# --- fungsi bantu ------------------------------------------------------------
decompress() {  # $1 in, $2 out
    local in="$1" out="$2" t
    t=$(file -b "$in" 2>/dev/null || echo unknown)
    case "$t" in
        *gzip*)               gzip -dc  < "$in" > "$out" ;;
        *LZMA*)               lzma -dc  < "$in" > "$out" ;;
        *"XZ compressed"*)    xz -dc    < "$in" > "$out" ;;
        *"LZO compressed"*)   lzop -dc  < "$in" > "$out" ;;
        *"Zstd compressed"*)  zstd -dcq < "$in" > "$out" ;;
        *"u-boot legacy"*)    dd if="$in" of="$out" bs=64 skip=1 status=none ;;
        *ELF*)                die "$in adalah ELF; kernel armhf harusnya zImage" ;;
        *)                    cp -f "$in" "$out" ;;
    esac
    return 0
}

find_dtb_dir() {  # $1 kver
    local v="$1" d
    for d in "/usr/lib/linux-image-${v}" "/boot/dtb/xe303os" "/usr/lib/linux-image-${v}/device-tree" "/lib/firmware/devicetree/base"; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

# --- bangun ulang utk tiap versi --------------------------------------------
DTBS=()
for v in "${VERSIONS[@]}"; do
    [ -n "$v" ] || continue
    src="${BOOT}/vmlinuz-${v}"
    [ -f "$src" ] || { log "lewati $v (tidak ada $src)"; continue; }
    d="${BOOT}/${v}"
    mkdir -p "$d" || continue

    cp -f "$src" "${d}/vmlinuz"
    decompress "$src" "${d}/zImage" || log "gagal dekompresi $v - pakai vmlinuz apa adanya"
    [ -s "${d}/zImage" ] || cp -f "$src" "${d}/zImage"

    if [ -f "${BOOT}/initrd.img-${v}" ]; then
        cp -f "${BOOT}/initrd.img-${v}" "${d}/initrd.img"
    elif [ -f "${d}/initrd.img" ]; then
        log "initrd.img-${v} tidak ada, memakai ${d}/initrd.img yang ada"
    else
        log "TIDAK ada initramfs utk $v - jalankan: update-initramfs -c -k $v"
    fi

    # uImage/uInitrd utk flow u-boot lama (nv_uboot env.txt)
    if command -v mkimage >/dev/null 2>&1; then
        mkimage -A arm -O linux -T kernel -C none -a 0x40008000 -e 0x40008000 \
            -n "XE303OS ${v}" -d "${d}/zImage" "${d}/uImage" >/dev/null 2>&1 || true
        [ -f "${d}/initrd.img" ] && mkimage -A arm -O linux -T ramdisk -C none \
            -a 0x43000000 -e 0x43000000 -n "XE303OS initrd ${v}" \
            -d "${d}/initrd.img" "${d}/uInitrd" >/dev/null 2>&1 || true
    fi

    # DTB
    if dd_=$(find_dtb_dir "$v"); then
        n=0
        for pat in $DTB_SRC_GLOB; do
            for f in "${dd_}/${pat}"; do
                [ -f "$f" ] || continue
                cp -f "$f" "$d/" && { DTBS+=("$(basename "$f")"); n=$((n+1)); }
            done
        done
        [ "$n" -gt 0 ] && log "$v: $n DTB disalin dari $dd_" || log "$v: TIDAK ada DTB exynos di $dd_"
    else
        log "$v: direktori DTB tidak ditemukan"
    fi
done

# uniq + urut
mapfile -t DTBS < <(printf '%s\n' "${DTBS[@]}" | grep -v '^$' | sort -u)
[ ${#DTBS[@]} -gt 0 ] || DTBS=(exynos5250-snow.dtb)

# --- extlinux.conf -----------------------------------------------------------
last_v="${VERSIONS[${#VERSIONS[@]}-1]}"
BASE_ARGS=$(grep -vE '^[[:space:]]*(#|$)' "$CMDLINE_FILE" 2>/dev/null | tr '\n' ' ')
if ! grep -q 'root=' <<<"$BASE_ARGS"; then
    # fallback: root=UUIDdevice saat ini, supaya tidak boot ke root yang salah
    BASE_ARGS="${BASE_ARGS} root=UUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE /)" 2>/dev/null || true) rootwait rw"
fi
mkdir -p "${BOOT}/extlinux"
{
    echo "# Dibuat otomatis oleh /usr/lib/xe303os/mkboot.sh pada $(date -Is)"
    echo "# Jangan edit manual; ubah /etc/xe303os/cmdline lalu jalankan mkboot.sh"
    echo "DEFAULT xe303os-${last_v}"
    echo "TIMEOUT 30"
    for v in "${VERSIONS[@]}"; do
        for dtb in "${DTBS[@]}"; do
            [ -f "${BOOT}/${v}/${dtb}" ] || continue
            echo ""
            echo "LABEL xe303os-${v}-${dtb%.dtb}"
            echo "  MENU LABEL XE303OS ${v} (${dtb%.dtb})"
            echo "  KERNEL /${v}/vmlinuz"
            [ -f "${BOOT}/${v}/initrd.img" ] && echo "  INITRD /${v}/initrd.img"
            echo "  FDT /${v}/${dtb}"
            echo "  APPEND ${BASE_ARGS}"
        done
    done
} > "${BOOT}/extlinux/extlinux.conf.new"

if [ -s "${BOOT}/extlinux/extlinux.conf.new" ] && grep -q '^LABEL' "${BOOT}/extlinux/extlinux.conf.new"; then
    mv "${BOOT}/extlinux/extlinux.conf.new" "${BOOT}/extlinux/extlinux.conf"
    log "extlinux.conf ditulis ($(grep -c '^LABEL' "${BOOT}/extlinux/extlinux.conf") LABEL)"
else
    rm -f "${BOOT}/extlinux/extlinux.conf.new"
    log "PERINGATAN: tidak ada LABEL valid - extlinux.conf lama dibiarkan"
fi

# env.txt utk flow lama
{
    echo "# XE303OS env.txt (flow nv_uboot) - dibuat mkboot.sh"
    echo "boot_part=3"
    echo "root_part=4"
    echo "loadaddr=0x40008000"
    echo "dtaddr=0x42000000"
    echo "initrdaddr=0x43000000"
    echo "kernel_path=/${last_v}/zImage"
    echo "initrd_path=/${last_v}/initrd.img"
    echo "dtb_path=/${last_v}/${DTBS[0]}"
    echo "bootargs=${BASE_ARGS}"
} > "${BOOT}/env.txt"

# --- opsional: image vboot utk depthcharge (kalau dipakai) -------------------
if command -v mkdepthcharge >/dev/null 2>&1; then
    mkdir -p "${BOOT}/depthcharge"
    if mkdepthcharge -v -o "${BOOT}/depthcharge/${last_v}.img" \
         --arch arm --format fit --patch-dtbs --kernel-start 0x40008000 \
         --cmdline "${BASE_ARGS}" -- \
         "${BOOT}/${last_v}/zImage" "${BOOT}/${last_v}/initrd.img" \
         "${BOOT}/${last_v}/${DTBS[0]}" >/dev/null 2>&1; then
        log "image vboot: ${BOOT}/depthcharge/${last_v}.img (untuk depthchargectl write)"
    else
        log "mkdepthcharge gagal (tidak fatal - jalur utama = u-boot chainloading)"
    fi
fi

sync
log "selesai. JANGAN reboot sebelum cek: ls ${BOOT}/extlinux/extlinux.conf"
exit 0
