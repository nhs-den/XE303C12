#!/usr/bin/env bash
# tools/show-layout.sh - cetak layout image + contoh file hasil build.
# Dipakai `make layout`, dan oleh CI untuk mengisi docs/generated-layout-example.txt.
#   bash tools/show-layout.sh [--save docs/generated-layout-example.txt]
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../build/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

out=${1:-/dev/stdout}
{
    printf 'Contoh keluaran build/lib/layout.sh (dibuat oleh `make layout`)\n'
    printf 'config: SUITE=%s ARCH=%s BOARD=%s BOOT_MODE=%s VERSION=%s\n\n' \
        "$SUITE" "$ARCH" "$BOARD" "$BOOT_MODE" "$VERSION"

    printf '== tabel partisi: nama  start(sektor)  size(sektor)\n'
    layout_partition_table | awk -F'\t' '{printf "  %-7s %10d %10d   (%6.1f MiB)\n", $1, $2, $3, $3*512/1048576}'
    tot=$(layout_total_sectors)
    printf '  total image: %d sektor = %s\n\n' "$tot" "$(human $(( tot * 512 )))"

    printf '== script partisi untuk sfdisk (stdin)\n'
    layout_sfdisk_script | sed 's/^/  /'
    printf '\n'

    printf '== extlinux/extlinux.conf (partisi BOOT; dibaca U-Boot chainloading)\n'
    layout_extlinux_conf "${KVER_EXAMPLE:-6.12.94+deb13-armmp}" $DTB_CANDIDATES | sed 's/^/  /'
    printf '\n'

    printf '== env.txt (fallback utk nv_uboot yang membaca env.txt + bootm)\n'
    layout_env_txt "${KVER_EXAMPLE:-6.12.94+deb13-armmp}" "$(echo "$DTB_CANDIDATES" | awk '{print $1}')" | sed 's/^/  /'
    printf '\n'

    printf '== validasi\n'
    layout_validate | sed 's/^/  /'
} > "$out" 2>&1
[ "$out" = "/dev/stdout" ] || info "tertulis: $out"
