#!/usr/bin/env bash
# 80-iso.sh - kemas hasil build jadi SATU file ISO (kontainer offline).
#
# PENTING - baca dulu (docs/iso-note.md ada juga di dalam ISO):
#   Chromebook Exynos 5250 TIDAK bisa boot dari ISO9660. Firmware-nya (fork
#   Das U-Boot "H2C") hanya membaca partisi GPT tipe kernel ChromeOS
#   (FE3A2A5D-4F32-41A7-B725-ACCC3285A309) di sektor awal disk. Karena itu
#   artefak yang di-flash ke USB/SD adalah file .img, bukan .iso.
#
# ISO ini berguna sebagai:
#   1. paket offline (image + dokumen + tools + checksum) untuk disalin/diarsip
#   2. sumber mount (`mount -o loop xe303os.iso /mnt`) di mesin mana pun
#   3. basis netinst: kalau DEBIAN_NETINST_ISO di-set, ISO resmi Debian armhf
#      ikut dimasukkan supaya install di perangkat tetap bisa jalan offline.
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STAGE="${WORK_DIR}/iso-stage"
OUT="${DIST_DIR}/${DISTRO_NAME}-${VERSION}-${BOARD}-${SUITE}.iso"

step_banner "iso: ${OUT}"
if ! command -v xorriso >/dev/null 2>&1; then
    if [ "${DRY_RUN}" = "1" ]; then
        note "dry-run: xorriso tidak terpasang - perintah tetap dicetak"
    else
        die "xorriso belum ada (apt-get install -y xorriso)"
    fi
fi

run rm -rf "$STAGE"
run mkdir -p "$STAGE"/{image,docs,tools}

# --- isi ISO -----------------------------------------------------------------
populate() {
    local img
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  kumpulkan stage ISO -> %s\n' "$STAGE"; return 0
    fi
    shopt -s nullglob
    local copied=0
    for img in "${DIST_DIR}"/*.img.xz "${DIST_DIR}"/*.img "${DIST_DIR}"/*.img.gz \
               "${DIST_DIR}"/*installer*.img.xz; do
        cp -f --link "$img" "${STAGE}/image/" && copied=$((copied+1))
    done
    [ "$copied" -gt 0 ] || die "tidak ada image di ${DIST_DIR} - jalankan 'make image' dulu"
    cp -f "${DIST_DIR}"/*.sha256 "${STAGE}/image/" 2>/dev/null || true
    cp -f "${DIST_DIR}"/*-partitions.txt "${STAGE}/" 2>/dev/null || true
    cp -f "${DIST_DIR}/build-manifest.txt" "${STAGE}/" 2>/dev/null || true
    cp -f "${ROOT_DIR}/README.md" "${STAGE}/docs/README.md"
    cp -f "${ROOT_DIR}"/docs/*.md "${STAGE}/docs/" 2>/dev/null || true
    cp -f "${ROOT_DIR}"/tools/*.sh "${STAGE}/tools/" 2>/dev/null || true
    cp -rf "${ROOT_DIR}/config" "${STAGE}/tools/config" 2>/dev/null || true
    # script penyalinan yang bisa dijalankan dari ISO langsung
    cat > "${STAGE}/flash-from-iso.sh" <<'EOF'
#!/bin/sh
# Jalankan dari ISO yang di-mount: flash image ke USB/SD.
#   sudo sh /media/*/XE303OS/flash-from-iso.sh /dev/sdX
set -e
DEV="$1"
[ -b "$DEV" ] || { echo "pakai: $0 <device>  (mis. /dev/sdb)"; exit 1; }
HERE=$(dirname "$0")
IMG=$(ls "$HERE"/image/*.img.xz "$HERE"/image/*.img 2>/dev/null | head -1)
[ -n "$IMG" ] || { echo "image tidak ketemu di $HERE/image"; exit 1; }
echo "Akan menulis ke $DEV :"
ls -l "$IMG"
echo "tekan Ctrl+C untuk batal, enter untuk lanjut"
read _
case "$IMG" in
  *.xz) xz -dc "$IMG" | dd of="$DEV" bs=4M conv=fsync status=progress ;;
  *)    dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress ;;
esac
sync
echo "selesai. safe-remove lalu boot Chromebook dengan Ctrl+U"
EOF
    chmod 755 "${STAGE}/flash-from-iso.sh"
    info "stage siap: $(du -sh "$STAGE" | cut -f1)"
}
populate

# --- netinst resmi Debian (opsional) -----------------------------------------
maybe_embed_netinst() {
    local iso="${DEBIAN_NETINST_ISO:-}"
    [ -z "$iso" ] && { note "DEBIAN_NETINST_ISO kosong - ISO Debian tidak disertakan"; return 0; }
    if [ ! -f "$iso" ]; then
        # contoh: debian-13.7.0-armhf-netinst.iso (netinst armhf resmi ADA di Debian)
        info "mengunduh netinst armhf resmi Debian..."
        run wget -q -O "$iso" "${DEBIAN_NETINST_URL:-${DEBIAN_MIRROR}/dists/${SUITE}/../cdimage/current/${ARCH}/iso-cd/$(basename "$iso")}" || {
            warn "unduh gagal; lanjut tanpa netinst"; return 0; }
    fi
    [ "${DRY_RUN}" = "1" ] || cp -f "$iso" "${STAGE}/"
    info "netinst disertakan: $(basename "$iso")"
}
maybe_embed_netinst

# --- catatan di root ISO ------------------------------------------------------
write_readme() {
    [ "${DRY_RUN}" = "1" ] && { printf 'DRY  tulis README-ISO.txt\n'; return 0; }
    cat > "${STAGE}/BACA-SAYA.txt" <<EOF
${DISTRO_LABEL} ${VERSION} - kontainer ISO
================================================================

ISO INI BUKAN MEDIA BOOT UNTUK SAMSUNG CHROMEBOOK SERIES 3 (XE303C12).

Alasannya (hardware, bukan selera):
  * XE303C12 pakai Samsung Exynos 5250 (ARMv7/armhf), bukan x86.
  * Firmware-nya fork Das U-Boot "H2C", bukan coreboot+depthcharge.
  * Ia hanya memuat image dari partisi GPT bertipe ChromeOS kernel
    FE3A2A5D-4F32-41A7-B725-ACCC3285A309 (partisi 1 / 2). ISO9660 tidak dibaca.

Yang kamu flash ke USB/SD adalah file image di folder image/ :
    $(cd "${STAGE}/image" 2>/dev/null && ls -1 *.img.xz *.img 2>/dev/null | head -3)

Cara flash (dari PC mana pun, x86 atau ARM):
    sudo sh flash-from-iso.sh /dev/sdX
atau manual:
    xz -dc image/*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

Lalu di Chromebook: developer mode (tombol Esc+Refresh+Power), boot dari
USB dengan Ctrl+U. Petunjuk lengkap + cara memindahkan ke eMMC:
docs/install.md (README.md juga ada di dalam ISO).

Login default: ${USERNAME} / ${USERPASS}   (ganti segera!)
EOF
    info "BACA-SAYA.txt ditulis"
}
write_readme

# --- bikin ISO ----------------------------------------------------------------
make_iso() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  xorriso -as mkisofs -r -J -V %s -o %s %s\n' "$ISO_LABEL" "$OUT" "$STAGE"
        return 0
    fi
    mkdir -p "$DIST_DIR"
    run xorriso -as mkisofs \
        -r -J -joliet-long -iso-level 3 \
        -V "$ISO_LABEL" \
        -publisher "${DISTRO_LABEL} Build System" \
        -p "${DISTRO_NAME}-${VERSION}" \
        -o "$OUT" "$STAGE"
    ( cd "$DIST_DIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
    local sz; sz=$(stat -c %s "$OUT")
    info "ISO: ${OUT}  ($(human "$sz"))"
    log "   verifikasi: sha256sum -c $(basename "$OUT").sha256"
    warn "ingat: ISO ini kontainer/dokumentasi. Untuk boot, pakai file .img.xz di dalamnya."
}
make_iso
