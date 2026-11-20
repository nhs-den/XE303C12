#!/usr/bin/env bash
# build-all.sh - menjalankan seluruh tahap build berurutan, dengan state
# supaya tahap yang sudah berhasil bisa di-resume.
#   bash build/build-all.sh            # semua tahap
#   bash build/build-all.sh bootimg image
set -o errexit -o pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "${BUILD_DIR}/lib/layout.sh"

ALL_STEPS=(10-precheck 20-rootfs 30-packages 40-hardware 45-system 50-desktop 60-bootimg 70-image)
STATE_FILE="${WORK_DIR}/.state"

mkdir -p "$WORK_DIR" "$DIST_DIR"
write_manifest "${DIST_DIR}/build-manifest.txt"

chosen=("$@")
if [ ${#chosen[@]} -eq 0 ]; then chosen=("${ALL_STEPS[@]}"); fi

done_step() { [ -f "$STATE_FILE" ] && grep -qx "done $1" "$STATE_FILE"; }
mark_done() { printf 'done %s\n' "$1" >> "$STATE_FILE"; }

export TARGET_ROOTFS="${WORK_DIR}/rootfs"
export BOOT_DIR="${WORK_DIR}/boot"

if [ "${FORCE:-0}" = "1" ]; then rm -f "$STATE_FILE"; note "state dibersihkan (FORCE=1)"; fi

started=$(date +%s)
for s in "${chosen[@]}"; do
    if done_step "$s" && [ "${FORCE:-0}" != "1" ]; then
        note "lewat $s (sudah selesai) - pakai FORCE=1 atau hapus ${STATE_FILE}"
        continue
    fi
    script="${BUILD_DIR}/${s}.sh"
    [ -f "$script" ] || die "tahap tidak dikenal: $s ($script tidak ada)"
    bash "$script"
    mark_done "$s"
done

dur=$(( $(date +%s) - started ))
printf '\n'
info "build selesai dalam $(( dur / 60 ))m$(( dur % 60 ))s"
[ -f "${DIST_DIR}/${IMAGE_STEM}.img.xz" ] &&
    log "artefak: ${DIST_DIR}/${IMAGE_STEM}.img.xz"
log "langkah berikutnya: bash tools/write-usb.sh <device>  |  docs/install.md"
