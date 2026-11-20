# shellcheck shell=bash
# ============================================================================
#  build/lib/layout.sh - logika murni (tanpa root, tanpa efek samping)
#  Menghasilkan: script partisi sfdisk, extlinux.conf, env.txt u-boot,
#  dan validasi self-test. Fungsi-fungsi ini diuji di tests/.
# ============================================================================

# Semua ukuran dalam MiB -> sektor 512B. Mengembalikan daftar baris "name start size".
layout_partition_table() {
    local kern_mb boot_mb root_mb sector first
    kern_mb=${1:-${KERN_PART_MB:-16}}
    boot_mb=${2:-${BOOT_PART_MB:-192}}
    root_mb=${3:-${ROOT_PART_MB:-3400}}
    sector=${SECTOR:-512}
    first=${FIRST_LBA:-2048}

    local kb=$(( boot_mb * 1024 * 1024 / sector ))
    local kr=$(( root_mb * 1024 * 1024 / sector ))
    local kc=$(( kern_mb * 1024 * 1024 / sector ))

    # urutan: KERN-A, KERN-B, BOOT, ROOTFS
    local p=1 s=$first
    printf '%s\t%s\t%s\n' "KERN-A" "$s" "$kc"; s=$(( s + kc )); p=$(( p + 1 ))
    printf '%s\t%s\t%s\n' "KERN-B" "$s" "$kc"; s=$(( s + kc )); p=$(( p + 1 ))
    printf '%s\t%s\t%s\n' "BOOT"   "$s" "$kb"; s=$(( s + kb )); p=$(( p + 1 ))
    printf '%s\t%s\t%s\n' "ROOTFS" "$s" "$kr"
}

# Total ukuran image (sektor) = akhir ROOTFS + 2048 sector cadangan GPT belakang.
layout_total_sectors() {
    local last_line last size
    last_line=$(layout_partition_table "$@" | tail -1)
    last=$(awk '{print $2}' <<<"$last_line")
    size=$(awk '{print $3}' <<<"$last_line")
    echo $(( last + size + 2048 ))
}

# Script untuk `sfdisk <dev>` pada stdin.
layout_sfdisk_script() {
    local total
    total=$(layout_total_sectors "$@")
    cat <<EOF
label: gpt
label-id: 58453330-3343-4C31-2D53-453033433132
unit: sectors
first-lba: ${FIRST_LBA:-2048}
last-lba: $(( total - 2049 ))
EOF
    local name start size type uuid
    # Type GUID partisi kernel ChromeOS; sisanya "Linux filesystem data".
    local KTYPE="FE3A2A5D-4F32-41A7-B725-ACCC3285A309"
    local LTYPE="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    while IFS=$'\t' read -r name start size; do
        case "$name" in
            KERN-A|KERN-B) type=$KTYPE; uuid=$(layout_partuuid "$name");;
            BOOT)          type=$LTYPE; uuid=$BOOT_PARTUUID;;
            ROOTFS)        type=$LTYPE; uuid=$ROOTFS_PARTUUID;;
            *)             type=$LTYPE; uuid="";;
        esac
        printf 'start=%d, size=%d, type=%s, name="%s"' "$start" "$size" "$type" "$name"
        [ -n "$uuid" ] && printf ', uuid=%s' "$uuid"
        printf '\n'
    done < <(layout_partition_table "$@")
}

# PARTUUID partisi kernel. Dipakai `root=PARTUUID=%U/PARTNROFF=1` pada jalur
# depthcharge (mode vboot-direct) dan oleh tools/grow-partition.sh.
layout_partuuid() {
    case "$1" in
        1|KERN-A) echo "d1e2f3a4-1111-4222-8333-584530334f53";;
        2|KERN-B) echo "d1e2f3a4-2222-4222-8333-584530334f53";;
        *)        echo "";;
    esac
}

# Isi /boot/<kver>/ ... untuk partisi BOOT + extlinux.conf.
# args: <kver> <dtb1> [dtb2 ...]
layout_extlinux_conf() {
    local kver="$1"; shift
    local dtbs=("$@")
    local cmdline rootref
    if [ "${ROOT_REF:-uuid}" = "partuuid" ]; then
        rootref="root=PARTUUID=${ROOTFS_PARTUUID}"
    else
        rootref="root=UUID=${ROOTFS_UUID}"
    fi
    cmdline="$(__layout_cmdline) $rootref rootwait rw"

    # DEFAULT wajib cocok dengan salah satu LABEL; utamakan DTB yang namanya
    # menyebut BOARD (mis. snow), kalau tidak ada pakai DTB pertama.
    local default_label="" d
    for d in "${dtbs[@]}"; do
        case "$d" in *"$BOARD"*) default_label="${DISTRO_ID}-${d%.dtb}"; break;; esac
    done
    [ -n "$default_label" ] || default_label="${DISTRO_ID}-${dtbs[0]%.dtb}"
    {
        echo "DEFAULT ${default_label}"
        echo "TIMEOUT 30"
        local d
        for d in "${dtbs[@]}"; do
            local lbl="${DISTRO_ID}-${d%.dtb}"
            echo ""
            echo "LABEL ${lbl}"
            echo "  MENU LABEL ${DISTRO_LABEL} ${VERSION} (${SUITE}/${kver}, ${d%.dtb})"
            echo "  KERNEL /${kver}/vmlinuz"
            echo "  INITRD /${kver}/initrd.img"
            echo "  FDT /${kver}/${d}"
            echo "  APPEND ${cmdline}"
        done
    }
}

# env.txt untuk flow lama "nv_uboot-snow" (fallback bila sysboot/extlinux tidak jalan)
layout_env_txt() {
    local kver="$1" dtb="$2"
    local cmdline rootref
    if [ "${ROOT_REF:-uuid}" = "partuuid" ]; then
        rootref="root=PARTUUID=${ROOTFS_PARTUUID}"
    else
        rootref="root=UUID=${ROOTFS_UUID}"
    fi
    cmdline="$(__layout_cmdline) $rootref rootwait rw"
    cat <<EOF
# XE303OS - environment untuk U-Boot chainloading (flow env.txt)
boot_part=3
root_part=4
loadaddr=0x40008000
dtaddr=0x42000000
initrdaddr=0x43000000
kernel_path=/${kver}/zImage
initrd_path=/${kver}/initrd.img
dtb_path=/${kver}/${dtb}
bootargs=${cmdline}
EOF
}

__layout_cmdline() {
    local f="${CONFIG_DIR}/kernel-cmdline.conf"
    if [ -f "$f" ]; then
        grep -vE '^[[:space:]]*(#|$)' "$f" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    fi
}

# Validasi self-consistency; dipakai `make check` dan precheck.
layout_validate() {
    local errors=0
    local -a names=()
    while IFS=$'\t' read -r name start size; do
        names+=("$name")
        [ "$size" -gt 0 ]     || { err "partisi $name size=0"; errors=$((errors+1)); }
        [ $(( start % 2048 )) -eq 0 ] || warn "partisi $name tidak 1MiB-aligned (start=$start)"
    done < <(layout_partition_table)

    # KERN-A dan KERN-B harus berukuran sama (ChromeOS fallback expects symmetry)
    local ka kb
    ka=$(layout_partition_table | awk -F'\t' '$1=="KERN-A"{print $3}')
    kb=$(layout_partition_table | awk -F'\t' '$1=="KERN-B"{print $3}')
    [ "$ka" = "$kb" ] || { err "KERN-A($ka) != KERN-B($kb)"; errors=$((errors+1)); }

    # partisi kernel minimal cukup untuk u-boot (~1.5MB) dan untuk vboot (>=64MB)
    local min_kb=$(( 1536 * 1024 / SECTOR ))
    [ "$ka" -ge "$min_kb" ] || { err "KERN-A terlalu kecil untuk u-boot"; errors=$((errors+1)); }
    if [ "${BOOT_MODE}" = "vboot-direct" ] && [ "$ka" -lt $(( 64 * 2048 )) ]; then
        err "BOOT_MODE=vboot-direct butuh KERN_PART_MB >= 64 (initramfs)"
        errors=$((errors+1))
    fi

    # UUID harus bentuk 8-4-4-4-12
    local u
    for u in "$ROOTFS_UUID" "$ROOTFS_PARTUUID" "$BOOT_PARTUUID"; do
        [[ "$u" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
            || { err "UUID tidak valid: $u"; errors=$((errors+1)); }
    done

    # label partisi tidak boleh kosong / duplikat
    local dup
    dup=$(printf '%s\n' "${names[@]}" | sort | uniq -d)
    [ -z "$dup" ] || { err "nama partisi duplikat: $dup"; errors=$((errors+1)); }

    if [ "$errors" -eq 0 ]; then
        info "layout valid: ${names[*]}"
        return 0
    fi
    return 1
}

# Ukuran image (byte) untuk truncate/loop
layout_image_bytes() {
    echo $(( $(layout_total_sectors) * ${SECTOR:-512} ))
}
