# ============================================================================
#  XE303OS - Makefile
#  Perintah utama:
#    make check        -> test statis + layout (tanpa root, tanpa internet)
#    make deps         -> pasang dependensi builder (Debian/Ubuntu host)
#    make precheck     -> cek host: arsitektur, tool, akses mirror, ruang disk
#    make rootfs       -> debootstrap armhf + install paket
#    make image        -> full build: rootfs + bootimg + GPT image .img.xz
#    make iso          -> kontainer ISO offline (distribusi), lihat catatan di README
#    make installer    -> image USB berisi Debian-installer (d-i) + preseed
#    make qemu         -> smoke test boot kernel di qemu-system-arm
#    make clean        -> hapus work/ (dist/ tetap)
#  Variabel yang sering dipakai:
#    SUITE=bookworm  DESKTOP=xfce  BOOT_MODE=vboot-direct  DRY_RUN=1  VERBOSE=1
# ============================================================================

SHELL      := /bin/bash
ROOT_DIR   := $(CURDIR)
export ROOT_DIR
DISTRO     := $(shell sed -n 's/^DISTRO_NAME="\([^"]*\)".*/\1/p' config/build.conf)
VERSION    := $(shell sed -n 's/^VERSION="\([^"]*\)".*/\1/p' config/build.conf)
BOARD      ?= $(shell sed -n 's/^BOARD="\([^"]*\)".*/\1/p' config/build.conf)
SUITE      ?= trixie
DESKTOP    ?= lxqt
BOOT_MODE  ?= uboot-extlinux
IMAGE      := dist/xe303os-$(VERSION)-$(BOARD)-$(SUITE).img
IMAGE_XZ   := $(IMAGE).xz
ISO        := dist/xe303os-$(VERSION)-$(BOARD)-$(SUITE).iso
ENV        := SUITE=$(SUITE) DESKTOP=$(DESKTOP) BOOT_MODE=$(BOOT_MODE) BOARD=$(BOARD)
STEPS      := precheck rootfs packages hardware desktop bootimg image

.PHONY: all check test deps precheck rootfs packages hardware desktop bootimg \
        image installer iso qemu clean distclean help layout manifest sign

all: image

help:
	@printf 'Target: check deps precheck rootfs image installer iso qemu clean\n'
	@printf 'Config: SUITE=%s DESKTOP=%s BOOT_MODE=%s BOARD=%s\n' '$(SUITE)' '$(DESKTOP)' '$(BOOT_MODE)' '$(BOARD)'
	@printf 'Artefak: %s  +  %s\n' '$(IMAGE_XZ)' '$(ISO)'

# --- build steps -------------------------------------------------------------
precheck:
	@$(ENV) bash build/10-precheck.sh

rootfs:
	@sudo $(ENV) bash build/20-rootfs.sh

packages:
	@sudo $(ENV) bash build/30-packages.sh

hardware:
	@sudo $(ENV) bash build/40-hardware.sh

desktop:
	@sudo $(ENV) bash build/50-desktop.sh

bootimg:
	@sudo $(ENV) bash build/60-bootimg.sh

image:
	@sudo $(ENV) ROOT_DIR=$(ROOT_DIR) bash build/build-all.sh

installer:
	@$(ENV) bash build/75-installer.sh

iso:
	@$(ENV) bash build/80-iso.sh

# --- debug / util -------------------------------------------------------------
layout:
	@bash tools/show-layout.sh

layout-doc:
	@bash tools/show-layout.sh docs/generated-layout-example.txt
qemu:
	@bash build/90-verify.sh --qemu-only

manifest:
	@bash -c 'source build/lib/common.sh; write_manifest dist/build-manifest.txt; cat dist/build-manifest.txt'

# --- quality -----------------------------------------------------------------
check:
	@bash tests/run-tests.sh

test: check

deps:
	@sudo apt-get update
	@sudo apt-get install -y --no-install-recommends \
	  debootstrap mmdebstrap qemu-user-static binfmt-support \
	  dosfstools e2fsprogs fdisk util-linux rsync squashfs-tools \
	  vboot-kernel-utils vboot-utils depthcharge-tools cgpt u-boot-tools \
	  device-tree-compiler lz4 xz-utils gzip bzip2 \
	  xorriso isolinux syslinux-common gettext-base shellcheck bc curl ca-certificates git

clean:
	@rm -rf work
	@printf 'work/ dibersihkan (dist/ dibiarkan)\n'

distclean: clean
	@rm -rf dist
