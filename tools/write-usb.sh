#!/bin/bash
# tools/write-usb.sh - tulis image XE303OS ke USB/SD dgn aman + set prioritas boot.
#
#   sudo bash tools/write-usb.sh dist/xe303os-1.0.0-snow-trixie.img.xz /dev/sdX
#   sudo bash tools/write-usb.sh --list
#
# Kenapa bukan "burn ISO": firmware Chromebook Exynos 5250 hanya membaca
# partisi GPT tipe kernel ChromeOS di awal disk. Jadi yang ditulis adalah
# IMAGE (dd), bukan ISO.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"

usage() { sed -n '2,10p' "$0"; }

list_targets() {
    echo "Perangkat blok yang kelihatan seperti USB/SD (pilih salah satu):"
    lsblk -bno NAME,SIZE,TYPE,VENDOR,MODEL,TRAN,RO,RM /dev/sd? /dev/mmcblk? 2>/dev/null |
    awk -v gb=1073741824 'BEGIN{printf "  %-14s %10s %-6s %-10s %-6s ro=%s rm=%s\n","DEV","SIZE(GiB)","TYPE","VENDOR","TRAN","ro","rm"}
        $3=="disk"{printf "  %-14s %10.1f %-6s %-10s %-6s %s %s\n", "/dev/"$1, $2/gb, $3, ($4?$4:"-"), ($7?$7:"-"), $6, $8}'
    echo
    echo "  JANGAN pilih disk yang berisi sistem kamu. Cek: lsblk -f /dev/sdX"
}

[ $# -eq 0 ] && { usage; echo; list_targets; exit 1; }
if [ "${1:-}" = "--list" ]; then list_targets; exit 0; fi

IMG="" DEV=""
for a in "$@"; do
    case "$a" in
        /dev/*) DEV="$a";;
        *) IMG="$a";;
    esac
done
[ -n "$IMG" ] && [ -n "$DEV" ] || { usage; exit 1; }
[ -f "$IMG" ] || die "file image tidak ada: $IMG"
[ -b "$DEV" ] || die "$DEV bukan block device"

require_root
# --- penjagaan: jangan timpa disk yang sedang dipakai -------------------------
if lsblk -nro MOUNTPOINTS "$DEV" 2>/dev/null | grep -q .; then
    die "$DEV masih ada mount aktif - lepas dulu (umount / luksClose)"
fi
if lsblk -nro PKNAME "$DEV" 2>/dev/null | grep -q "^$(basename "$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')")$" ; then
    die "$DEV adalah bagian dari disk root sistem ini"
fi
# --- penjagaan: ukuran device >= ukuran image --------------------------------
need_bytes=$( [ "${IMG##*.}" = "xz" ] && xz -l --robot "$IMG" 2>/dev/null | awk -F'\t' '/[^#]/{print $2}' | tail -1 || stat -c %s "$IMG" )
if [ -n "${need_bytes:-}" ] && [ "$need_bytes" -gt 0 ]; then
    have_bytes=$(blockdev --getsize64 "$DEV")
    if [ "$have_bytes" -lt "$need_bytes" ]; then
        die "device terlalu kecil: perlu $(human "$need_bytes"), ada $(human "$have_bytes")"
    fi
    log "image $(human "$need_bytes") -> $DEV ($(human "$have_bytes"))"
fi

printf '\n%s\n' "!! SEMUA DATA DI $DEV AKAN HILANG."
printf 'Ketik "TULIS" utk lanjut: '; read -r ans
[ "$ans" = "TULIS" ] || { echo "batal."; exit 1; }

sync
# lepas bila ter-partisi-mount
command -v partprobe >/dev/null 2>&1 && partprobe "$DEV" 2>/dev/null || true
udisksctl power-off -b "$DEV" 2>/dev/null || true

echo "menulis ..."
if [ "${IMG##*.}" = "xz" ]; then
    xz -dc "$IMG" | dd of="$DEV" bs=4M conv=fsync status=progress
elif [ "${IMG##*.}" = "gz" ]; then
    gzip -dc "$IMG" | dd of="$DEV" bs=4M conv=fsync status=progress
else
    dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
fi
sync
blockdev --flushbufs "$DEV" 2>/dev/null || true

# --- cek hasil ----------------------------------------------------------------
echo
if command -v sfdisk >/dev/null 2>&1; then
    sfdisk -l -o Device,Start,Sectors,Type,Name "$DEV" 2>/dev/null | tail -6
fi
if command -v cgpt >/dev/null 2>&1; then
    echo "cgpt show:"; cgpt show "$DEV" 2>/dev/null | sed -n '1,12p' || true
    cgpt prioritize -i 1 "$DEV" 2>/dev/null && echo "  KERN-A diprioritaskan (cgpt prioritize)" \
        || echo "  (cgpt prioritize gagal - tidak fatal, firmware biasanya coba KERN-A duluan)"
fi
partprobe "$DEV" 2>/dev/null || true
udisksctl power-off -b "$DEV" 2>/dev/null || true

cat <<EOF

Selesai. Selanjutnya:
  1) Chromebook dalam keadaan mati, colok USB/SD ini.
  2) Nyalakan + tahan Esc lalu tekan Refresh (F6) -> developer mode.
  3) Di layar "OS verification is OFF" tekan Ctrl+U (USB) / Ctrl+B (eMMC).
  4) Boot pertama ~1-3 menit (grow filesystem + generate SSH key).
  5) Login: ${USERNAME}/${USERPASS} -> jalankan 'passwd'.
EOF
