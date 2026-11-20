#!/usr/bin/env bash
# tools/run-tests.sh - test statis + unit test + dry-run pipeline.
# Tidak butuh root, tidak butuh internet. Dipanggil oleh `make check`.
set -uo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR" || { echo "tidak bisa masuk $ROOT_DIR" >&2; exit 1; }

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
sk()   { printf '  \033[33mSKIP\033[0m %s\n' "$*"; skip=$((skip+1)); }
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

assert_eq() { # desc expected actual
    [ "$2" = "$3" ] && ok "$1" || no "$1 (harusnya '$2', dapat '$3')"
}
assert_has() { # desc needle haystack-file-or-string
    if printf '%s' "${3:-}" | grep -qF -- "$2"; then ok "$1"; else no "$1 (tidak ketemu: '$2')"; fi
}

# ---------------------------------------------------------------- bash -n ----
hdr "sintaks bash (bash -n)"
n=0
while IFS= read -r f; do
    n=$((n+1))
    if bash -n "$f" 2>/tmp/rt.err; then :; else no "$f: $(head -1 /tmp/rt.err)"; fi
done < <(find build tools tests overlay -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)
[ $n -gt 0 ] && ok "$n file shell terparsir"

# cari shellcheck: PATH, lalu varian python (shellcheck-py), lalu ~/.local/bin
SC_BIN=$(command -v shellcheck || true)
if [ -z "$SC_BIN" ]; then
    for c in "$HOME/.local/bin/shellcheck" "$(python3 -c 'import shellcheck_py,os;print(os.path.join(os.path.dirname(shellcheck_py.__file__),"shellcheck"))' 2>/dev/null || true)"; do
        [ -n "$c" ] && [ -x "$c" ] && { SC_BIN="$c"; break; }
    done
fi
if [ -n "${SC_BIN:-}" ]; then
    hdr "shellcheck"
    if "$SC_BIN" -S warning -e SC1091,SC2034,SC2086,SC2015,SC2155,SC2129,SC2016 \
        $(find build tools tests -name '*.sh' | sort) 2>/tmp/sc.txt; then
        ok "shellcheck bersih (level warning)"
    else
        no "shellcheck menemukan isu: $(grep -c '^In ' /tmp/sc.txt 2>/dev/null || echo '?') file - lihat /tmp/sc.txt"
    fi
else
    sk "shellcheck tidak terpasang (make deps  /  apt-get install -y shellcheck)"
fi

# ------------------------------------------------------- unit: layout math ---
hdr "unit test: layout partisi"
run_layout() {
    bash -c "ROOT_DIR='$ROOT_DIR'; CONFIG_DIR='$ROOT_DIR/config'; \
             source '$ROOT_DIR/config/build.conf'; \
             source '$ROOT_DIR/build/lib/layout.sh'; $1"
}
tbl=$(run_layout 'layout_partition_table' )
assert_eq "4 partisi" "4" "$(printf '%s\n' "$tbl" | grep -c . )"
order=$(printf '%s\n' "$tbl" | cut -f1 | tr '\n' ' ')
assert_eq "urutan partisi" "KERN-A KERN-B BOOT ROOTFS " "$order"

# alignment 1MiB
bad=$(printf '%s\n' "$tbl" | awk -F'\t' '$2 % 2048 != 0 || $3 % 2048 != 0 {print $1}' | tr '\n' ' ')
assert_eq "semua start/size 1MiB-aligned" "" "$bad"

# tidak tumpang tindih
overlap=$(printf '%s\n' "$tbl" | awk -F'\t' 'NR>1 && $2 < prev_end {print $1} {prev_end=$2+$3}')
assert_eq "tidak ada tumpang tindih partisi" "" "$overlap"

# KERN-A == KERN-B (fallback firmware)
ka=$(printf '%s\n' "$tbl" | awk -F'\t' '$1=="KERN-A"{print $3}')
kb=$(printf '%s\n' "$tbl" | awk -F'\t' '$1=="KERN-B"{print $3}')
assert_eq "KERN-A dan KERN-B sama besar" "$ka" "$kb"

# ROOTFS paling besar
biggest=$(printf '%s\n' "$tbl" | sort -t$'\t' -k3 -rn | head -1 | cut -f1)
assert_eq "ROOTFS partisi terbesar" "ROOTFS" "$biggest"

# total image = akhir ROOTFS + backup GPT
tot=$(run_layout 'layout_total_sectors')
last=$(printf '%s\n' "$tbl" | tail -1 | awk -F'\t' '{print $2+$3}')
assert_eq "total sektor = akhir rootfs + 2048" "$((last + 2048))" "$tot"

bytes=$(run_layout 'layout_image_bytes')
assert_eq "ukuran image byte = sektor*512" "$((tot * 512))" "$bytes"

# sfdisk script valid secara gramatikal
sfd=$(run_layout 'layout_sfdisk_script')
assert_has "sfdisk: label gpt"      "label: gpt"        "$sfd"
assert_has "sfdisk: unit sectors"   "unit: sectors"     "$sfd"
assert_has "sfdisk: first-lba"      "first-lba: "       "$sfd"
assert_has "sfdisk: GUID kernel"    "FE3A2A5D-4F32-41A7-B725-ACCC3285A309" "$sfd"
assert_has "sfdisk: GUID linux"     "0FC63DAF-8483-4772-8E79-3D69D8477DE4" "$sfd"
assert_eq  "sfdisk: 4 baris partisi" "4" "$(printf '%s\n' "$sfd" | grep -c '^start=')"
badlines=$(printf '%s\n' "$sfd" | grep '^start=' | grep -vE '^start=[0-9]+, size=[0-9]+, type=[0-9A-Fa-f-]+, name="[A-Z-]+"(, uuid=[0-9a-f-]+)?$')
assert_eq "sfdisk: format baris partisi rapi" "" "$badlines"

hdr "unit test: layout_validate()"
if run_layout 'layout_validate' >/dev/null 2>&1; then ok "layout valid"; else no "layout_validate menolak konfigurasi"; fi
if run_layout 'KERN_PART_MB=1 BOOT_PART_MB=192 layout_validate' >/dev/null 2>&1; then
    no "layout_validate seharusnya menolak partisi kernel 1 MiB"
else
    ok "layout_validate menolak partisi kernel yang terlalu kecil"
fi

# ------------------------------------------------ unit: extlinux & env.txt ---
hdr "unit test: extlinux.conf + env.txt"
ext=$(run_layout 'layout_extlinux_conf 6.12.94+deb13-armmp exynos5250-snow.dtb exynos5800-peach-pi.dtb')
assert_has "extlinux: ada DEFAULT"     "DEFAULT "               "$ext"
assert_has "extlinux: TIMEOUT"      "TIMEOUT 30"             "$ext"
def_lbl=$(printf '%s\n' "$ext" | awk '/^DEFAULT/{print $2; exit}')
if printf '%s\n' "$ext" | grep -q "^LABEL ${def_lbl}\$"; then ok "extlinux: DEFAULT (${def_lbl}) merujuk LABEL yang ada"; else no "extlinux: DEFAULT '${def_lbl}' tidak cocok dengan LABEL mana pun (ekstlinux jatuh ke entri pertama)"; fi
nlab=$(printf '%s\n' "$ext" | grep -c '^LABEL ')
assert_eq "extlinux: 1 LABEL per DTB" "2" "$nlab"
assert_has "extlinux: KERNEL path"  "KERNEL /6.12.94+deb13-armmp/vmlinuz" "$ext"
assert_has "extlinux: FDT snow"     "FDT /6.12.94+deb13-armmp/exynos5250-snow.dtb" "$ext"
assert_has "extlinux: root=UUID"    "root=UUID="             "$ext"
assert_has "extlinux: rootwait"     "rootwait rw"            "$ext"
assert_has "extlinux: clk_ignore_unused (kunci panel LVDS)" "clk_ignore_unused" "$ext"
nappend=$(printf '%s\n' "$ext" | grep -c '^  APPEND ')
assert_eq "extlinux: tiap LABEL punya APPEND" "$nlab" "$nappend"
# path kernel tidak boleh menunjuk /boot (partisi BOOT = root view u-boot)
badpath=$(printf '%s\n' "$ext" | grep -E '^\s+(KERNEL|INITRD|FDT) /boot/' || true)
assert_eq "extlinux: tanpa prefix /boot" "" "$badpath"

env=$(run_layout 'layout_env_txt 6.12.94+deb13-armmp exynos5250-snow.dtb')
assert_has "env.txt: boot_part=3"  "boot_part=3"   "$env"
assert_has "env.txt: root_part=4"  "root_part=4"   "$env"
assert_has "env.txt: loadaddr exynos5250" "loadaddr=0x40008000" "$env"
assert_has "env.txt: dtb_path"      "dtb_path=/6.12.94+deb13-armmp/exynos5250-snow.dtb" "$env"

# ------------------------------------------------------- konsistensi config ---
hdr "konsistensi konfigurasi vs hardware target"
arch=$(run_layout 'echo "$ARCH"')
assert_eq "ARCH harus armhf (Exynos 5250 = ARMv7)" "armhf" "$arch"
for bad in amd64 i386 x86_64 aarch64 arm64; do
    [ "$arch" != "$bad" ] && ok "bukan $bad" || no "ARCH=$bad mustahil boot di XE303C12"
done
suite=$(run_layout 'echo "$SUITE"')
case "$suite" in
    bookworm|trixie|forky|sid) ok "SUITE=$suite dikenal Debian";;
    *) no "SUITE='$suite' bukan suite Debian yang valid";;
esac
bm=$(run_layout 'echo "$BOOT_MODE"')
case "$bm" in
    uboot-extlinux) ok "BOOT_MODE=uboot-extlinux (jalur andal utk U-Boot H2C)";;
    vboot-direct)   sk "BOOT_MODE=vboot-direct - firmware snow/peach sering menolak (2x bip)";;
    *) no "BOOT_MODE tak dikenal: $bm";;
esac
for f in base hardware desktop-lxqt desktop-xfce desktop-openbox recommended blocklist; do
    [ -s "config/packages/$f.list" ] && ok "daftar paket $f.list ada" || no "config/packages/$f.list hilang/kosong"
done
# tidak boleh ada nama paket kosong / spasi di tengah
badpkg=$(awk '{sub(/#.*/,"")} NF && $0 ~ /[[:space:]]/ {print FILENAME": "$0}' config/packages/*.list | grep -v '^$' || true)
assert_eq "daftar paket: satu nama per baris" "" "$badpkg"
d=1
grep -q 'DTB_CANDIDATES' config/build.conf && ok "DTB_CANDIDATES terdefinisi" || no "DTB_CANDIDATES hilang"
# kandidat DTB harus nama file .dtb
baddtb=$(grep -o 'DTB_CANDIDATES="[^"]*"' config/build.conf | sed 's/.*"\(.*\)"/\1/' | tr ' ' '\n' | grep -v '\.dtb$' || true)
assert_eq "DTB_CANDIDATES semua .dtb" "" "$baddtb"

# ------------------------------------------------- tidak ada x86/grub-ism ----
hdr "sanity: tidak ada asumsi x86/UEFI/GRUB"
for pat in 'grub-mkrescue' 'efibootmgr' 'bootx64.efi' 'syslinux.efi' 'virt-install'; do
    hit=$(grep -rIl --exclude-dir=.git "$pat" build tools config overlay 2>/dev/null || true)
    assert_eq "tidak memakai $pat" "" "$hit"
done

# ------------------------------------------------------ placeholders/TODO ----
hdr "tidak ada placeholder yang tertinggal"
todo=$(grep -rn 'TODO\|FIXME\|XXX\|ramah对新\|占' --include='*.sh' --include='*.md' --include='*.conf' --include='*.list' . 2>/dev/null | grep -v '^./tests/run-tests.sh' || true)
if [ -z "$todo" ]; then ok "bersih"; else no "ada placeholder/typo:"; printf '%s\n' "$todo" | sed 's/^/      /'; fi

# non-ASCII di file yang harus ASCII (script/config)
nonascii=$(grep -rlP '[\x{4e00}-\x{9fff}\x{3040}-\x{30ff}]' build config tools overlay 2>/dev/null || true)
assert_eq "tidak ada karakter CJK di build/config/tools" "" "$nonascii"

# ------------------------------------------------------------------- dry-run --
hdr "dry-run pipeline (harus jalan tanpa root/internet)"
if DRY_RUN=1 bash build/build-all.sh 10-precheck > /tmp/rt-pre.log 2>&1; then
    ok "10-precheck lolos (host lengkap)"
else
    if grep -qiE 'debootstrap|bootstrapper' /tmp/rt-pre.log; then
        ok "10-precheck melaporkan dependensi yang kurang dengan benar"
    else
        no "10-precheck gagal tanpa pesan yang membantu:"; tail -5 /tmp/rt-pre.log | sed 's/^/      /'
    fi
fi
for s in 60-bootimg 70-image 80-iso; do
    if DRY_RUN=1 ROOT_DIR="$ROOT_DIR" bash "build/$s.sh" >/tmp/rt-$s.log 2>&1; then
        ok "dry-run build/$s.sh"
    else
        no "dry-run build/$s.sh gagal:"; tail -6 /tmp/rt-$s.log | sed 's/^/      /'
    fi
done
for s in tools/write-usb.sh tools/grow-partition.sh tools/unique-ids.sh; do
    [ -x "$s" ] || [ -f "$s" ] && ok "$s ada" || no "$s hilang"
done
bash -n tools/write-usb.sh 2>/dev/null && ok "tools/write-usb.sh parse" || no "tools/write-usb.sh parse"

# ------------------------------------------------------------------- docs ----
hdr "dokumentasi"
for f in README.md docs/hardware.md docs/boot-chain.md docs/install.md docs/troubleshooting.md; do
    if [ -s "$f" ]; then
        lines=$(wc -l < "$f")
        [ "$lines" -gt 8 ] && ok "$f ($lines baris)" || no "$f terlalu pendek ($lines)"
    else
        no "$f hilang"
    fi
done
grep -q 'img.xz' README.md && ok "README menyebut artefak .img.xz" || no "README tidak menyebut image flashable"
grep -qiE 'developer mode|dev mode' README.md && ok "README menyebut developer mode" || no "README lupa developer mode (wajib utk boot USB)"

# ------------------------------------------------------------------ summary --
printf '\n'
printf '\033[1mhasil:\033[0m %d pass, %d fail, %d skip\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
