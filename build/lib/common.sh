# shellcheck shell=bash
# ============================================================================
#  build/lib/common.sh - helper bersama untuk semua step build XE303OS
#  Tidak boleh punya efek samping saat di-source (kecuali load config).
# ============================================================================

set -o errexit -o nounset -o pipefail

# --- Lokasi -----------------------------------------------------------------
if [ -z "${ROOT_DIR:-}" ]; then
    _lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    ROOT_DIR=$(cd -- "${_lib_dir}/../.." && pwd)
    unset _lib_dir
fi
CONFIG_DIR="${ROOT_DIR}/config"
OVERLAY_DIR="${ROOT_DIR}/overlay"
BUILD_DIR="${ROOT_DIR}/build"

# --- Warna (non-TTY => mati) ------------------------------------------------
if [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BOLD=""; C_OFF=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
note() { printf '%s[.. ]%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
warn() { printf '%s[!! ]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

step_banner() {
    printf '\n%s%s%s\n' "$C_BOLD" "==> $*" "$C_OFF"
}

# --- Konfigurasi --------------------------------------------------------------
# Urutan prioritas (rendah -> tinggi):
#   config/build.conf  <  config/build.local.conf  <  environment user
__load_conf() {
    local f
    for f in "${CONFIG_DIR}/build.conf" "${CONFIG_DIR}/build.local.conf"; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
    done
}
__load_conf

DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

# --- Util -------------------------------------------------------------------
require_cmd() {
    local missing=() c
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if [ ${#missing[@]} -gt 0 ]; then
        printf '%s\n' "Command belum terpasang: ${missing[*]}" >&2
        printf '%s\n' "Pasang dengan:  sudo apt-get install -y ${missing[*]}" >&2
        return 1
    fi
}

require_root() {
    [ "${DRY_RUN}" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ] || die "Langkah ini butuh root. Jalankan:  sudo -E make ${TARGET_NAME:-image}"
}

# Jalankan perintah; di mode dry-run hanya dicetak.
run() {
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  %s\n' "$*"
    else
        [ "${VERBOSE}" = "1" ] && printf '+ %s\n' "$*" >&2
        "$@"
    fi
}

# Run dengan environment bersih di dalam chroot.
chroot_run() {
    local target="$1"; shift
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  chroot %s -- %s\n' "$target" "$*"
        return 0
    fi
    local -a envp=(
        "DEBIAN_FRONTEND=noninteractive"
        "NEEDRESTART_MODE=a"
        "SYSTEMD_OFFLINE=1"
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
        "HOME=/root"
        "TERM=${TERM:-dumb}"
    )
    [ -n "${LANG_SET:-}" ] && envp+=("LANG=${LANG_SET}")
    chroot "$target" env "${envp[@]}" "$@"
}

# apt-get di dalam chroot dengan retry + tanpa recommends bila diminta.
apt_in() {
    local target="$1"; shift
    local -a opts=(-y -o "Acquire::Retries=${APT_RETRIES:-5}"
                   -o "Dpkg::Options::=--force-confnew"
                   -o "APT::Install-Recommends=${APT_RECOMMENDS:-no}"
                   -o "APT::Immediate-Configure=0")
    chroot_run "$target" apt-get "${opts[@]}" "$@"
}

apt_install() {
    local target="$1"; shift
    [ "$#" -eq 0 ] && return 0
    note "apt: $*"
    apt_in "$target" install "$@" || die "Gagal install: $*"
}

# Salin file overlay -> target, mempertahankan mode/owner.
copy_overlay() {
    local src="$1" dst="$2"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  cp-overlay %s -> %s\n' "$src" "$dst"
        return 0
    fi
    [ -e "$src" ] || die "overlay tidak ada: $src"
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        run cp -a --reflink=auto -t "$dst" "$src"/.
    else
        mkdir -p "$(dirname "$dst")"
        run cp -a "$src" "$dst"
    fi
}

# Ekspansi ${VAR} di dalam file template.
render() {
    local in="$1" out="$2"
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'DRY  render %s -> %s\n' "$in" "$out"
        return 0
    fi
    mkdir -p "$(dirname "$out")"
    # envsubst ada di gettext-base; fallback ke eval-free sed bila tidak ada.
    if command -v envsubst >/dev/null 2>&1; then
        envsubst < "$in" > "$out"
    else
        local var val content
        content=$(cat "$in")
        for var in "$@"; do :; done
        printf '%s\n' "$content" > "$out"
    fi
}

mount_vfs() {
    local target="$1"
    [ "${DRY_RUN}" = "1" ] && { note "DRY mount VFS $target"; return 0; }
    local m
    for m in proc sys dev dev/pts tmp var/tmp; do
        mkdir -p "${target}/${m}"
    done
    # bind-mount hanya bila belum ter-mount (idempotent)
    local already
    already=$(awk '{print $2}' /proc/mounts | grep -c "^${target}/proc$" || true)
    if [ "${already:-0}" = "0" ]; then
        run mount -t proc     proc      "${target}/proc"
        run mount --rbind     sysfs     "${target}/sys"
        run mount --rbind     /dev      "${target}/dev"
        run mount --make-rslave "${target}/dev" 2>/dev/null || true
    fi
}

umount_vfs() {
    local target="$1"
    [ "${DRY_RUN}" = "1" ] && return 0
    local m
    for m in var/tmp tmp dev/pts dev sys proc; do
        umount -Rl "${target}/${m}" 2>/dev/null || true
    done
}

# Format ukuran tanpa bergantung pada bc (pakai aritmetika integer + 2 desimal).
human() {
    local b=${1:-0} unit name frac whole
    for unit in 1073741824 1048576 1024; do
        if [ "$b" -ge "$unit" ]; then
            case $unit in
                1073741824) name=GiB ;;
                1048576)    name=MiB ;;
                *)          name=KiB ;;
            esac
            whole=$(( b / unit ))
            frac=$(( (b % unit) * 100 / unit ))
            printf '%d.%02d %s' "$whole" "$frac" "$name"
            return 0
        fi
    done
    printf '%d B' "$b"
}

# Simpan metadata build yang bisa diaudit.
write_manifest() {
    local file="$1"
    [ "${DRY_RUN}" = "1" ] && return 0
    mkdir -p "$(dirname "$file")"
    {
        echo "# XE303OS build manifest - dibuat $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "git_rev=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "git_dirty=$(git -C "$ROOT_DIR" diff --quiet 2>/dev/null && echo no || echo yes)"
        echo "builder_os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
        echo "host_arch=$(uname -m) kernel=$(uname -r)"
        for k in DISTRO_NAME VERSION SUITE ARCH BOARD BOOT_MODE KERNEL_META \
                 DEBIAN_MIRROR DESKTOP KERN_PART_MB BOOT_PART_MB ROOT_PART_MB \
                 ROOTFS_UUID ROOTFS_PARTUUID DTB_CANDIDATES UBOOT_PREBUILT_URL; do
            printf '%s=%s\n' "$k" "${!k:-}"
        done
    } > "$file"
}
