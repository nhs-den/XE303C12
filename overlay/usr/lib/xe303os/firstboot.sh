#!/bin/bash
# /usr/lib/xe303os/firstboot.sh - dirapikan sekali saat boot pertama.
#
# Kenapa perlu: image build berukuran tetap (~3.5 GiB) supaya mudah diunduh &
# di-dd. Setelah di-flash ke SD/USB/eMMC 16 GiB, sebagian besar kapasitas masih
# kosong. Skrip ini meluaskan partisi root + filesystem, membuat host key SSH
# yang unik per unit, lalu menonaktifkan dirinya.
set -uo pipefail

STAMP=/var/lib/xe303os/firstboot.done
log() { printf 'xe303os-firstboot: %s\n' "$*"; }

[ -f "$STAMP" ] && exit 0
mkdir -p "$(dirname "$STAMP")"

# --- 1. perluas partisi root ke sisa ruang disk ------------------------------
grow_root() {
    command -v sfdisk >/dev/null 2>&1 || { log "sfdisk tidak ada, lewati grow"; return 0; }
    local src canon partno disk start size total free devsz
    src=$(findmnt -no SOURCE / 2>/dev/null || true)
    [ -n "$src" ] || { log "gagal deteksi device root"; return 0; }
    canon=$(readlink -f "$src")
    case "$canon" in
        *p[0-9]*) partno=${canon##*p} ;;
        *[0-9]*)  partno=${canon##*[a-z]} ;;
        *) log "nama partisi tak dikenali: $canon"; return 0 ;;
    esac
    disk=${canon%%[0-9]*}
    disk=${disk%p}
    [ -b "$disk" ] || { log "disk induk tak ditemukan: $disk"; return 0; }

    # total sektor disk - start partisi - 2048 sektor cadangan utk GPT backup
    devsz=$(blockdev --getsz "$disk")
    read -r start size <<<"$(lsblk -bnro START,SIZE "$canon" 2>/dev/null | head -1 | awk '{print $1, $2/512}')"
    [ -n "${start:-}" ] || { log "lsblk START gagal"; return 0; }
    free=$(( devsz - start - 2048 ))
    if [ "$free" -le "$size" ] || [ "$free" -lt 1048576 ]; then
        log "tidak ada ruang bebas berarti (${free} sektor vs ${size}) - lewati"
    else
        log "memperbesar ${canon}: ${size} -> ${free} sektor"
        if sfdisk --part-size "$disk" "$partno" "$free" 2>/tmp/xe303os-sfdisk.err; then
            partx -u "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
            partprobe "$disk" 2>/dev/null || true
            sleep 2
            if command -v resize2fs >/dev/null 2>&1 && findmnt -no FSTYPE / | grep -q ext; then
                resize2fs "$canon" 2>&1 | tail -3 || log "resize2fs perlu dijalankan manual setelah reboot"
            fi
        else
            log "sfdisk --part-size gagal: $(cat /tmp/xe303os-sfdisk.err 2>/dev/null | head -2)"
            log "jalankan manual: tools/grow-partition.sh (lihat docs/install.md)"
        fi
    fi
}
grow_root

# --- 2. host key SSH unik per unit -------------------------------------------
ssh_keys() {
    if [ -d /etc/ssh ] && ! ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
        log "generate SSH host keys"
        ssh-keygen -A >/dev/null 2>&1 || log "ssh-keygen -A gagal"
    fi
}
ssh_keys

# --- 3. machine-id -----------------------------------------------------------
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup 2>/dev/null || dbus-uuidgen > /etc/machine-id 2>/dev/null || true
fi

# --- 4. audio: simpan state supaya tidak perlu unmute tiap boot --------------
if [ -x /usr/lib/xe303os/alsa-unmute.sh ]; then
    /usr/lib/xe303os/alsa-unmute.sh --store || true
fi

# --- 5. kapalkan konfigurasi desktop ke home user pertama -------------------
for h in /home/*; do
    [ -d "$h" ] || continue
    if [ -d /etc/skel ] && [ ! -e "$h/.config/lxqt/session.conf" ]; then
        cp -a /etc/skel/. "$h/" 2>/dev/null || true
        chown -R "$(stat -c '%U:%G' "$h")" "$h/.config" "$h/.local" 2>/dev/null || true
        log "salin /etc/skel -> $h"
    fi
done

# --- 6. sinkronkan jam dari NTP sekali (RTC Chromebook sering mundur) --------
timedatectl set-ntp true 2>/dev/null || true

# --- 7. bersihkan cache apt yang tak terpakai + stamp -----------------------
apt-get -y clean >/dev/null 2>&1 || true
log "selesai"
sync
: > "$STAMP"
