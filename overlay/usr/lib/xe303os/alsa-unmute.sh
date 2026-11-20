#!/bin/bash
# /usr/lib/xe303os/alsa-unmute.sh - bunyi di Chromebook Exynos 5250.
#
# Codec MAX98090/MAX98095 di snow/peach keluar dari kernel dalam keadaan
# "Speaker Mixer" ter-mute. Tanpa unmute, ALSA aktif tapi speaker senyap.
# Kontrol punya 4 jalur (L/R Mixer L/R DAC); semuanya harus 'on'.
set -u
STORE=0
[ "${1:-}" = "--store" ] && STORE=1

log() { printf 'xe303os-alsa: %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
have amixer || exit 0

# daftar kontrol yang dikenal utk machine driver "Google Snow"/"Peach"
CTRLS=(
  "Left Speaker Mixer Left DAC Switch"
  "Left Speaker Mixer Right DAC Switch"
  "Right Speaker Mixer Left DAC Switch"
  "Right Speaker Mixer Right DAC Switch"
  "Speaker Playback Volume"
  "Speaker High Performance Mode"
  "Stereo DAC MIXL DAC L1 Switch"
  "Stereo DAC MIXR DAC R1 Switch"
  "SPKRB MIXBOOST Switch"
  "OUT1L Boost Switch"
  "OUT1R Boost Switch"
)

cards=()
if [ -r /proc/asound/cards ]; then
    mapfile -t cards < <(awk '/^[ ]*[0-9]+ /{print $1}' /proc/asound/cards)
fi
[ ${#cards[@]} -eq 0 ] && { log "belum ada sound card - lewati"; exit 0; }

rc=0
for c in "${cards[@]}"; do
    name=$(awk -v c="$c" '$1==c{ $1=""; sub(/^ /,""); print; exit }' /proc/asound/cards)
    log "sound card ${c}: ${name}"

    # 1) coba UCM (alsa-ucm-conf) - paling benar kalau ada profilnya
    if have alsaucm && alsaucm -c "$c" set _verb HiFi >/dev/null 2>&1; then
        log "  UCM verb HiFi aktif"
    fi

    # 2) unmute manual
    for k in "${CTRLS[@]}"; do
        if amixer -c "$c" sget "$k" >/dev/null 2>&1; then
            case "$k" in
                *"Volume")
                    amixer -c "$c" sset "$k" 90%,90% unmute >/dev/null 2>&1 && log "  $k -> 90%" ;;
                *"Switch")
                    amixer -c "$c" sset "$k" on unmute >/dev/null 2>&1 ;;
                *)
                    amixer -c "$c" sset "$k" 100% unmute >/dev/null 2>&1 ;;
            esac
        fi
    done
    # master playback
    for k in "Master" "PCM" "Playback" "DAC" "Headphone"; do
        amixer -c "$c" sget "$k" >/dev/null 2>&1 && { amixer -c "$c" sset "$k" 90% unmute >/dev/null 2>&1; break; }
    done

    if have alsactl; then
        if [ "$STORE" = "1" ]; then
            alsactl --file /var/lib/alsa/asound.state store >/dev/null 2>&1 && log "  state disimpan"
        else
            [ -f /var/lib/alsa/asound.state ] && alsactl --file /var/lib/alsa/asound.state restore >/dev/null 2>&1 || true
        fi
    fi
done

# tes bunyi singkat supaya user langsung tahu (bisa diredam lewat env)
if [ "${XE303OS_NO_TEST:-0}" = "0" ] && have aplay && [ "$STORE" = "0" ]; then
    if [ -r /usr/share/sounds/alsa/Front_Center.wav ]; then
        timeout 3 aplay -q /usr/share/sounds/alsa/Front_Center.wav >/dev/null 2>&1 || true
    fi
fi
exit $rc
