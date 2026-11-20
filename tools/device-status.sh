#!/usr/bin/env bash
# tools/device-status.sh - diagnosa cepat DARI CHROMEBOOK (read-only, aman).
#
#   bash tools/device-status.sh
#
# Mencetak: SoC/revisi, state dev-mode & flag boot USB, isi partisi, DTB yang
# dipakai kernel, status WiFi/audio/baterai, ruang eMMC, dan apa yang harus
# diperbaiki kalau tidak boot. Tidak mengubah apa pun kecuali --fix.
set -uo pipefail

line() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
y() { printf '  [ok ] %s\n' "$*"; }
w() { printf '  [!! ] %s\n' "$*"; }
i() { printf '  [.. ] %s\n' "$*"; }

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

line "hardware"
if [ -r /proc/device-tree/compatible ]; then
    compat=$(tr '\0' ' ' < /proc/device-tree/compatible)
    i "compatible: $compat"
    case "$compat" in
        *snow*)   y "kernel memakai DTB exynos5250-snow (Samsung Chromebook 11.6')" ;;
        *spring*) i "DTB spring (Chromebook STETSON) - kalau layar mati, coba snow" ;;
        *peach-pit*) i "DTB peach-pit (Chromebook 2 13) - di XE303C12 biasanya SALAH (layar blank)" ;;
        *peach-pi*)  y "DTB peach-pi (Chromebook 2 11.6)" ;;
        *) w "DTB tidak dikenal: $compat" ;;
    esac
else
    w "/proc/device-tree tidak ada (x86? / DTB tidak diekspos)"
fi
[ -r /proc/cpuinfo ] && grep -m1 -E 'Hardware|model name|CPU part' /proc/cpuinfo | sed 's/^/  /'
i "machine: $(uname -m) kernel: $(uname -r)"
nproc_=$(nproc); total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
i "CPU: ${nproc_} core | RAM: $((total_kb/1024)) MiB (XE303C12 = 2048 MiB)"

line "boot state"
if command -v crossystem >/dev/null 2>&1; then
    for k in model hwid dev_mode dev_boot_usb dev_boot_legacy dev_boot_signed_only fwid; do
        printf '  %-22s %s\n' "$k" "$(crossystem "$k" 2>/dev/null || echo '-')"
    done
    [ "$(crossystem dev_mode 2>/dev/null)" = "1" ] \
        && y "developer mode ON" || w "developer mode OFF - tanpa ini tidak bisa boot image pihak ketiga"
    [ "$(crossystem dev_boot_usb 2>/dev/null)" = "1" ] \
        && y "dev_boot_usb=1 (Ctrl+U aktif)" || w "dev_boot_usb=0 -> aktifkan: sudo crossystem dev_boot_usb=1"
else
    i "crossystem tidak terpasang (apt-get install -y vboot-utils)"
    grep -qa 'cros_ec' /proc/devices 2>/dev/null && y "cros_ec ada - ini memang Chromebook"
fi
i "cmdline: $(cat /proc/cmdline)"
for p in /sys/firmware/devicetree/base/chosen/*; do :; done 2>/dev/null || true

line "partisi"
for d in /dev/mmcblk0 /dev/mmcblk1 /dev/sda; do
    [ -b "$d" ] || continue
    i "$d:"
    if command -v cgpt >/dev/null 2>&1; then
        cgpt show "$d" 2>/dev/null | sed -n '2,14p' | sed 's/^/    /'
    else
        lsblk -bno NAME,SIZE,START,TYPE "$d" 2>/dev/null | sed 's/^/    /'
    fi
done
root_src=$(findmnt -no SOURCE /) ; root_fs=$(findmnt -no FSTYPE /)
i "root: $root_src ($root_fs) ; /boot: $(findmnt -no SOURCE /boot 2>/dev/null || echo 'bagian dari rootfs')"
if command -v sfdisk >/dev/null 2>&1; then
    t1=$(sfdisk -d -o Type "$root_src" 2>/dev/null | sed -n '1p' | tr -d ' ')
    i "tipe GUID partisi ini: ${t1:-?} (rootfs harus 0FC63DAF-... ; KERN harus FE3A2A5D-...)"
fi

line "display"
if [ -d /sys/class/drm ]; then
    for c in /sys/class/drm/card*/; do
        [ -d "$c" ] || continue
        i "$(basename "$c"): $(cat "${c}enabled" 2>/dev/null || echo '?') ; connector: $(ls "$c" | grep -E '^(eDP|LVDS|DP|HDMI)' | tr '\n' ' ')"
    done
    dmesg_=$(dmesg 2>/dev/null | grep -iE 'exynos-drm|decon|fimd|bridge' | tail -4)
    [ -n "$dmesg_" ] && printf '%s\n' "$dmesg_" | sed 's/^/    /'
    if dmesg 2>/dev/null | grep -q 'Failed to send config to bridge'; then
        w "panel bridge (PTN3460 eDP->LVDS) GAGAL init - biasanya DTB salah (peach-pit vs peach-pi) atau regressi bridge-chain"
        i "coba: ganti DEFAULT di /boot/extlinux/extlinux.conf ke LABEL lain, lalu reboot"
    fi
fi
bl=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
if [ -n "$bl" ]; then
    cur=$(cat "/sys/class/backlight/${bl}/brightness" 2>/dev/null); mx=$(cat "/sys/class/backlight/${bl}/max_brightness" 2>/dev/null)
    i "backlight ${bl}: ${cur}/${mx}"
    [ "${cur:-1}" = "0" ] && w "backlight = 0 (layar gelap bukan karena GPU!)" && [ "$FIX" = "1" ] && { echo "$mx" > "/sys/class/backlight/${bl}/brightness"; y "backlight dipulihkan"; }
fi
[ -x /usr/lib/xe303os/mkboot.sh ] && i "extlinux: $(grep -c '^LABEL' /boot/extlinux/extlinux.conf 2>/dev/null || echo 0) LABEL, DEFAULT=$(awk '/^DEFAULT/{print $2; exit}' /boot/extlinux/extlinux.conf 2>/dev/null)"

line "audio"
if [ -r /proc/asound/cards ]; then
    if grep -q . /proc/asound/cards && ! grep -q 'no soundcards' /proc/asound/cards; then
        sed -n '1,6p' /proc/asound/cards | sed 's/^/  /'
        card=$(awk '/^[ ]*[0-9]+ /{print $1; exit}' /proc/asound/cards)
        for k in "Left Speaker Mixer Left DAC Switch" "Right Speaker Mixer Right DAC Switch"; do
            st=$(amixer -c "$card" sget "$k" 2>/dev/null | grep -o '\[[onoff]*\]' | tail -1)
            [ -n "$st" ] && i "$k: $st"
            if [ "${st:-}" = "[off]" ] && [ "$FIX" = "1" ]; then
                amixer -c "$card" sset "$k" on >/dev/null 2>&1 && y "unmute $k"
            fi
        done
    else
        w "tidak ada sound card - modul snd_soc_snow / max9809x belum ke-load"
        i "cek: dmesg | grep -i -E 'i2s|max9809'"
    fi
fi

line "jaringan"
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | sed 's/^/  /'
    nmcli -t -f NAME,DEVICE,STATE connection show --active 2>/dev/null | sed 's/^[^:]*:/  active: /'
fi
if command -v iw >/dev/null 2>&1; then
    iw dev 2>/dev/null | sed -n 's/^Interface /  iface: /p'
fi
sdio_devs=()
for d in /sys/bus/sdio/devices/*; do [ -e "$d" ] && sdio_devs+=("$(basename "$d")"); done
if [ ${#sdio_devs[@]} -gt 0 ]; then
    i "SDIO: ${sdio_devs[*]}"
    read -r v < /sys/bus/sdio/devices/*/vendor 2>/dev/null || true
    i "vendor 0x${v:-?} (0x02df = Marvell -> mwifiex)"
fi
dmesg 2>/dev/null | grep -iE 'mwifiex|libertas' | tail -3 | sed 's/^/    /'
if dmesg 2>/dev/null | grep -qi 'Direct firmware load for mrvl/sd8797'; then
    w "firmware WiFi hilang -> apt-get install -y firmware-libertas"
fi

line "baterai & daya"
for ps in /sys/class/power_supply/BAT*/; do
    [ -d "$ps" ] || continue
    printf '  %s: %s%% %s (%s)\n' "$(basename "$ps")" \
        "$(cat "${ps}capacity" 2>/dev/null || echo '?')" \
        "$(cat "${ps}status" 2>/dev/null || echo '?')" \
        "$(cat "${ps}charge_full" 2>/dev/null && echo ' µAh?')"
done
[ -d /sys/class/power_supply/BAT0 ] || w "tidak ada BAT0 - EC (cros_ec) mungkin belum ke-load; cek dmesg | grep cros_ec"
i "zram: $(zramctl 2>/dev/null | sed -n '2p' || echo 'tidak aktif')"
i "swap: $(swapon --show=NAME,SIZE,USED,PRIORITY 2>/dev/null | sed -n '2,$p' | tr '\n' ' ' || echo '-')"
i "governor CPU: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '-')"

line "storage"
df -h / /boot 2>/dev/null | tail -n +1 | sed 's/^/  /'
i " tulis-eMMC (kB) sejak boot: $(awk '{s+=$1} END{print s*4}' /sys/block/mmcblk0/stat 2>/dev/null || echo '?')"
i "wear: tidak dilaporkan eMMC consumer (normal)"

printf '\n'
[ "$FIX" = "1" ] && i "--fix dipakai: perubahan kecil sudah dicoba" || i "tip: jalankan 'sudo bash tools/device-status.sh --fix' utk unmute/darkness quick-fix"
