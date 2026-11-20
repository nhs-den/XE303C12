#!/usr/bin/env bash
# tools/fetch-uboot.sh - dapatkan image U-Boot chainloading utk Chromebook Exynos.
#
# Kenapa ini perlu: XE303C12 (Exynos 5250) TIDAK memakai coreboot+depthcharge,
# tapi fork Das U-Boot ("H2C"). Firmware itu menolak banyak image kernel vboot
# (gejala: 2x bip lalu balik ke ChromeOS). Solusi yang terbukti di komunitas:
# taruh U-Boot chainloading di partisi KERN-A/B, biarkan ia boot Debian dari
# partisi BOOT via extlinux.
#
# Sumber yang bisa dipakai:
#   1) prebuilt non-verified u-boot untuk snow (nv_uboot-snow.kpart)
#   2) prebuilt imagebuilder velvet-os (hexdump0815)
#   3) build sendiri: tools/build-uboot.sh (snow_defconfig mainline)
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"

OUT="${WORK_DIR}/uboot"
run mkdir -p "$OUT"

basename_url() { local u="$1"; u="${u%%\?*}"; printf '%s\n' "${u##*/}"; }

fetch_prebuilt() {
    [ -n "${UBOOT_PREBUILT_URL}" ] || { warn "UBOOT_PREBUILT_URL kosong"; return 1; }
    local f dst
    f=$(basename_url "$UBOOT_PREBUILT_URL")
    dst="${OUT}/${f%.bz2}"
    if [ -s "$dst" ]; then
        info "sudah ada: $dst"
    else
        note "unduh $UBOOT_PREBUILT_URL"
        if [ "${DRY_RUN}" = "1" ]; then
            printf 'DRY  curl -o %s %s\n' "$dst" "$UBOOT_PREBUILT_URL"; return 0
        fi
        curl -fL --retry 3 -m 600 -o "${OUT}/${f}" "$UBOOT_PREBUILT_URL" || die "unduh gagal: $UBOOT_PREBUILT_URL"
        case "$f" in
            *.bz2) bunzip2 -f "${OUT}/${f}";;
            *.gz)  gunzip -f "${OUT}/${f}";;
            *.xz)  unxz -f "${OUT}/${f}";;
            *)     mv "${OUT}/${f}" "$dst";;
        esac
    fi
    [ -f "$dst" ] || die "file hasil unduh tidak ada: $dst"
    local sz; sz=$(stat -c %s "$dst")
    info "ukuran: $(human "$sz")"
    if [ -n "${UBOOT_PREBUILT_SHA256}" ]; then
        printf '%s  %s\n' "$UBOOT_PREBUILT_SHA256" "$dst" | sha256sum -c - || die "SHA256 tidak cocok!"
        ok "sha256 cocok"
    else
        warn "UBOOT_PREBUILT_SHA256 kosong. Simpan checksum ini sebagai pin:"
        ( cd "$OUT" && sha256sum "$(basename "$dst")" | sed 's/^/      /' )
        note "lalu isi di config/build.local.conf:  UBOOT_PREBUILT_SHA256=\"<hash>\""
    fi
    # u-boot kpart harus muat di partisi kernel
    local limit=$(( ${KERN_PART_MB} * 1048576 ))
    [ "$sz" -le "$limit" ] || die "u-boot $(human "$sz") > partisi KERN ($(human "$limit")) - naikkan KERN_PART_MB"
    printf '%s\n' "$dst" > "${OUT}/.path"
    return 0
}

try_sources() {
    if fetch_prebuilt; then return 0; fi
    # alternatif 2: ambil rilis velvet-os (hanya bagian u-boot kpart-nya)
    if [ -n "${UBOOT_MIRROR_URL:-}" ]; then
        UBOOT_PREBUILT_URL="$UBOOT_MIRROR_URL"
        fetch_prebuilt && return 0
    fi
    return 1
}

if [ "${UBOOT_BUILD_FROM_SOURCE}" = "yes" ]; then
    note "UBOOT_BUILD_FROM_SOURCE=yes -> build dari sumber"
    bash "${ROOT_DIR}/tools/build-uboot.sh"
    exit $?
fi

if ! try_sources; then
    err "Tidak bisa mendapatkan image U-Boot."
    err "Pilih salah satu:"
    err "  a) isi UBOOT_PREBUILT_URL / UBOOT_MIRROR_URL di config/build.local.conf"
    err "  b) UBOOT_BUILD_FROM_SOURCE=yes make deps-uboot image   (butuh gcc-arm-linux-gnueabihf)"
    err "  c) taruh file .kpart hasil unduhanmu di:  ${OUT}/"
    if [ -d "$OUT" ] && ls "$OUT"/*.kpart >/dev/null 2>&1; then
        info "tapi sudah ada file lokal di ${OUT}:"; ls -l "$OUT"/*.kpart
        exit 0
    fi
    exit 1
fi
info "image U-Boot siap: $(cat "${OUT}/.path" 2>/dev/null || echo "${OUT}/")"
