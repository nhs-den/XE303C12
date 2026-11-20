#!/bin/bash
# tools/grow-partition.sh - perbesar partisi root + filesystem manual.
# Dipakai kalau service first-boot gagal (mis. image di-flash lalu partisi
# ROOTFS-nya dipotong ulang), atau sesudah kloning ke SD lebih besar.
#
#   sudo bash tools/grow-partition.sh            # kerja pada device root "/"
#   sudo bash tools/grow-partition.sh /dev/mmcblk0p4
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"

require_root
TARGET="${1:-$(findmnt -no SOURCE /)}"
canon=$(readlink -f "$TARGET")
case "$canon" in
    *p[0-9]*) partno=${canon##*p} ;;
    *[0-9]*)  partno=${canon##*[a-z]} ;;
    *) die "nama partisi tak dikenali: $canon" ;;
esac
disk=${canon%%[0-9]*}; disk=${disk%p}
[ -b "$disk" ] || die "disk induk tidak ada: $disk"

# 1. backup GPT harus di akhir disk yang baru (kalau disk diganti lebih besar)
if command -v sgdisk >/dev/null 2>&1; then
    log "sgdisk -e $disk (pindah backup GPT ke akhir disk)"
    sgdisk -e "$disk"
else
    warn "sgdisk tidak ada (apt-get install gdisk); lewati pemindahan backup GPT"
fi
partx -u "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true

# 2. hitung ulang
devsz=$(blockdev --getsz "$disk")                       # sektor
read -r start size <<<"$(lsblk -bnro START,SIZE "$canon" | awk 'NR==1{printf "%d %d", $1/512, $2/512}')"
free=$(( devsz - start - 2048 ))
log "$canon: start=${start} size=${size} -> target=${free} sektor (sisa $(human $(( (free-size) * 512 ))))"
[ "$free" -gt "$size" ] || { echo "Tidak ada ruang untuk diperbesar."; exit 0; }

# 3. ubah ukuran partisi (uuid & type tetap)
sfdisk --part-size "$disk" "$partno" "$free"
partx -u "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true
blockdev --rereadpt "$disk" 2>/dev/null || true
sleep 1

# 4. resize filesystem
fstype=$(lsblk -nro FSTYPE "$canon")
case "$fstype" in
    ext4|ext2|ext3) resize2fs "$canon" ;;
    btrfs)          mount -o remount,ro / 2>/dev/null || true
                    btrfs filesystem resize max / ;;
    swap)           swapoff "$canon"; mkswap "$canon"; swapon "$canon" ;;
    *)              die "fstype '$fstype' tak dikenal - resize manual ya" ;;
esac
# 4b. normalisasi GPT: tanpa ini firmware H2C bisa menolak disk setelah grow
if command -v cgpt >/dev/null 2>&1; then
    log "cgpt repair $disk"
    cgpt repair "$disk" 2>&1 | tail -3 || warn "cgpt repair gagal - lanjut, tapi tes reboot sebelum cabut media lain"
else
    warn "cgpt tidak ada: sudo apt-get install -y vboot-utils && sudo cgpt repair $disk"
fi

sync
info "selesai: $(lsblk -bno SIZE "$canon" | awk '{printf "%.2f GiB partisi\n", $1/1073741824}')"
df -h / | tail -1 | sed 's/^/  root: /'
