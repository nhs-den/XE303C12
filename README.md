# XE303OS — Debian 13 (armhf) + desktop ringan untuk Samsung Chromebook Series 3 (XE303C12)

Build system lengkap untuk menginstal Linux modern ke **Samsung Chromebook
Series 3 XE303C12** — mesin **Exynos 5250 (ARMv7, 2 GB RAM, 16 GB eMMC,
Mali-T604)** yang tidak bisa memakai ISO installer biasa.

```
dist/xe303os-1.0.0-snow-trixie.img.xz          <-- artefak "siap install": di-dd ke SD/USB
dist/xe303os-1.0.0-snow-trixie.iso             <-- kontainer offline (bukan media boot, lihat docs/iso-note.md)
```

> **Baca ini dulu, karena mengubah seluruh pendekatan.**
> XE303C12 bukan laptop x86. Firmwarenya adalah **fork Das U-Boot ("H2C")**, bukan
> coreboot+depthcharge dan bukan BIOS/UEFI. Ia hanya memuat payload dari **partisi
> GPT bertipe ChromeOS-kernel** (`FE3A2A5D-4F32-41A7-B725-ACCC3285A309`).
> Konsekuensinya: (1) **ISO tidak dapat di-boot di perangkat ini** — yang di-flash
> adalah *disk image*; (2) menaruh kernel+vboot langsung di partisi itu pun
> sering **ditolak** firmware di keluarga snow/peach (2× bip, balik ke ChromeOS),
> jadi kit ini memakai **U-Boot chainloading + extlinux** sebagai jalur default.
> Detail: [docs/boot-chain.md](docs/boot-chain.md), [docs/iso-note.md](docs/iso-note.md).

## Mulai cepat

```sh
# di host Debian 12/13 atau Ubuntu 22.04+ (x86-64 juga bisa; bootstrap-nya cross)
sudo make deps                 # debootstrap, mmdebstrap, vboot-utils, cgpt, xorriso, ...
make check                     # test statis + unit test layout + dry-run (tanpa root)
make precheck                  # cek host, arsip Debian, ruang disk

sudo -E make image             # -> dist/xe303os-1.0.0-snow-trixie.img.xz
make iso                       # -> dist/*.iso (offline kit, opsional)

sudo bash tools/write-usb.sh dist/xe303os-1.0.0-snow-trixie.img.xz /dev/sdX
```

Lalu di Chromebook: developer mode (`Esc`+`Refresh`+`Power`), boot dari SD/USB
dengan **Ctrl+U**. Login `user` / `xe303os` (ganti!). Pindah ke eMMC internal:
`sudo bash tools/install-to-emmc.sh`. Panduan lengkap: [docs/install.md](docs/install.md).

Varian build:

```sh
sudo -E make SUITE=bookworm DESKTOP=xfce image    # Debian 12, kernel 6.1, lebih ringan
sudo -E make DESKTOP=openbox image                # ~250 MB, window manager saja
sudo -E make EXTRA=yes image                      # + util (htop, ncdu, smartmontools, ...)
sudo -E make BOOT_MODE=vboot-direct image         # tanpa U-Boot (risiko ditolak firmware)
sudo -E make UBOOT_BUILD_FROM_SOURCE=yes image    # build u-boot sendiri (reproducible)
sudo -E make installer                            # image Debian-installer + preseed (eksperimental)
```

## Apa yang ada di dalamnya

| Komponen | Pilihan | Alasan |
|---|---|---|
| Basis | Debian 13 *trixie*, `linux-image-armmp` (6.12) | armhf masih arch resmi Debian; `armmp` membawa `exynos5250-snow.dtb` + `exynos5800-peach-pi.dtb`. LTS ke ~2030. |
| Desktop | **LXQt + Openbox** (default), alternatif Xfce / openbox-only | 2 GB RAM; tanpa compositor. |
| X driver | `modesetting`/`fbdev` di atas `exynos-drm`, **GLX dimatikan** | Mali-T604 = Utgard, tidak ada driver GL mainline; GLX cuma bikin crash. |
| Audio | `snd_soc_snow` + service unmute speaker | codec MAX98090 default-nya membisukan 4 jalur "Speaker Mixer". |
| WiFi/BT | `mwifiex_sdio` + `firmware-libertas` (`mrvl/sd8797_uapsta.bin`), powersave off | Marvell 88W8797; powersave = sering putus. |
| Input | `cros_ec_keyb` (keyboard/EC), `atmel_mxt_ts` + libinput | keyboard internal ada di ChromeOS EC via I2C. |
| Daya | zram 1 GB, earlyoom, `schedutil`, noatime+commit=60, journal ≤64 MB, tanpa swap eMMC | RAM 2 GB dan eMMC 16 GB yang tak bisa cepat diganti. |
| Boot | U-Boot chainloading (p1/p2) + extlinux (p3) + rootfs ext4 (p4) | lihat catatan di atas. |
| Kernel upgrade | hook `postinst.d` + `initramfs-tools/postinst.d` → `/usr/lib/xe303os/mkboot.sh` | tidak ada GRUB, jadi partisi BOOT harus dibangun ulang atau sistem mati diam. |

## Isi repo

```
config/build.conf            semua keputusan build (suite, arch, partisi, user, desktop)
config/kernel-cmdline.conf   parameter kernel utk exynos5250
config/packages/*.list       daftar paket (base, hardware, 3 varian desktop, blocklist)
build/lib/common.sh          helper: log, dry-run, chroot, apt dalam chroot
build/lib/layout.sh          logika partisi + extlinux.conf + env.txt (murni, diuji)
build/10..70-*.sh            precheck → rootfs → packages → hardware → system → desktop → bootimg → image
build/75-installer.sh        image Debian-installer (eksperimental)
build/80-iso.sh              kontainer ISO 9660
build/90-verify.sh           verifikasi image + smoke test qemu
overlay/                     file yang ditanam ke rootfs (systemd unit, udev, sysctl, X11, skel)
tools/                       on-device & host: write-usb, install-to-emmc, grow-partition,
                             rebuild-kernel-partition, device-status (diagnosa), unique-ids,
                             fetch-uboot, build-uboot, show-layout (cetak layout)
tests/run-tests.sh           `make check`: bash -n, shellcheck, unit test layout, dry-run pipeline
docs/                        hardware, boot-chain, install, troubleshooting, iso-note,
                             generated-layout-example.txt (dibuat oleh `make layout`)
```

### Struktur image yang dihasilkan

```
p1 KERN-A   16 MiB  type FE3A2A5D-…  image U-Boot chainloading (vboot preamble + payload)
p2 KERN-B   16 MiB  type FE3A2A5D-…  salinan = fallback
p3 BOOT    192 MiB  ext2 4K   <kver>/{vmlinuz,zImage,uImage,initrd.img,uInitrd,exynos*.dtb}
                              extlinux/extlinux.conf + env.txt
p4 ROOTFS ~3.4 GiB   ext4      Debian 13 + LXQt; UUID deterministik dari config
                                 (diluaskan otomatis ke sisa kartu/disk saat boot pertama)
```

Semua partisi 2 MiB-aligned; `root=UUID=…` (bukan `PARTNROFF`) karena rootfs
bukan partisi setelah KERN-A. Ukuran & nama partisi diatur di `config/build.conf`.

## Status & batasan yang perlu kamu tahu

* **Belum diuji pada perangkat keras.** Pipeline-nya ditulis mengikuti dokumentasi
  resmi (Debian armhf/`armmp`, `depthcharge-tools`, Chromium OS *disk format*,
  pengalaman komunitas snow/peach) dan diverifikasi oleh `make check`
  (sintaks, shellcheck, unit test layout, dry-run setiap tahap) — tapi image
  final butuh host ber-internet ke `deb.debian.org` untuk di-*build*, dan saya
  tidak bisa menjalankannya dari lingkungan ini. Kalau suatu tahap meledak di
  hardware-mu, itu bug yang perlu dilaporkan; jangan dianggap sudah dijamin.
* **Yang teruji otomatis di repo ini:** sintaks & shellcheck semua shell,
  aritmetika layout (alignment, tumpang tindih, GUID, ukuran), isi
  `extlinux.conf`/`env.txt`, konsistensi `ARCH=armhf` (test akan gagal kalau
  seseorang mengubahnya ke amd64), dry-run tahap 60/70/80, dan kelengkapan docs.
* **Tidak ada OpenGL.** WebGL/GLX tidak akan jalan — itu keterbatasan driver, bukan
  konfigurasi. `QT_OPENGL=software` diset untuk aplikasi yang bertanya.
* **Installer d-i (`make installer`) = eksperimental.** Jalur utama: flash image
  lalu `tools/install-to-emmc.sh`.
* **Beberapa unit menolak menulis partisi kernel eMMC** selama hardware write
  protect aktif (harus buka casing). Boot dari SD tidak terpengaruh.
* Prebuilt U-Boot yang diunduh `tools/fetch-uboot.sh` tidak punya checksum pin di
  config (`UBOOT_PREBUILT_SHA256` kosong) — skrip mencetak hash-nya; catat dan isi
  supaya build berikutnya terverifikasi. Build dari sumber:
  `UBOOT_BUILD_FROM_SOURCE=yes`.

## Dukungan per fitur (target `snow`/Exynos 5250, kernel 6.12)

| Fitur | Status | Catatan |
|---|---|---|
| Panel internal 1366×768 | seharusnya jalan | butuh DTB benar + `clk_ignore_unused` |
| Keyboard + tombol search | jalan | `cros_ec_keyb` |
| Touchpad | seharusnya jalan | `atmel_mxt_ts`, lihat troubleshooting §7 |
| Speaker / mic / jack | perlu unmute | service `xe303os-alsa` |
| WiFi 2.4/5 GHz | jalan dengan firmware | `firmware-libertas` |
| Bluetooth | seharusnya jalan | `btmrvl_sdio` (rawan; blacklist bila mengganggu) |
| Baterai / charging | jalan | `cros_ec` power_supply, `upower` |
| HDMI out | parsial | exynos-drm; tanpa GL |
| Kamera UVC | jalan | `uvcvideo` |
| GPU 3D | **tidak** | Mali-T604 tanpa driver mainline |
| Sleep (suspend-to-RAM) | bervariasi | `s2ram`/`systemctl suspend`; sering perlu `usb3_autosuspend` |

## Referensi & kerja terkait (dibaca sebelum menyalahkan kit ini)

Kit ini dibangun dari fakta yang dikumpulkan dari sini — dan beberapa
keputusan di review ulang karena mereka:

* Instructables, *Linux on XE303C12 Chromebook* (Sirius38, 2020) — bukti nyata
  bahwa jalur "image ARM exynos di-flash ke SD → dev mode → `crossystem
  dev_boot_usb=1` → `Ctrl+U`" jalan di unit ini, dan bahwa resize wajib
  ditutup dengan **`cgpt repair`** (kita sudah pakai itu di `firstboot.sh` dan
  `tools/grow-partition.sh`). Yang **tidak** bisa diambil dari sana: image-nya
  Kali 2019.3 (arsip repo sudah mati → `apt upgrade` hari ini merusak), tidak
  ada perbaikan audio/WiFi/keyboard, dan tidak ada jalur aman untuk upgrade
  kernel.
* `archlinuxarm.org/platforms/armv7/samsung/*` — sumber prosedur unmute speaker
  max98090 (4 jalur "Left/Right Speaker Mixer") yang kita otomatiskan.
* `velvet-os/imagebuilder` + `u-boot-chainloading-for-arm-chromebooks`
  (hexdump0815) — alasan `BOOT_MODE=uboot-extlinux` jadi default, dan kutipan
  "peach chromebooks seem to not boot ... not at all from usb devices".
* `github.com/alpernebbi/depthcharge-tools` (`mkdepthcharge`, `depthchargectl`)
  — dipakai untuk jalur `vboot-direct` + hook upgrade kernel.
* Chromium OS *Disk format* — GUID partisi kernel `fe3a2a5d-…`, atribut
  `cgpt`, alignment 2 MiB, `kern_guid=%U/PARTNROFF=1` (kita pakai
  `root=UUID=` karena rootfs kita bukan partisi berikutnya).
* `linux-exynos.org/wiki/Samsung_Chromebook_XE303C12` — bridge **PTN3460**
  eDP→LVDS, codec **MAX98090**, WiFi **Marvell 88W8797**, errata **773022**.
  Semuanya ada di `config/kernel-cmdline.conf`, `40-hardware.sh`,
  `config/packages/hardware.list`.

Kalau kamu datang dari guide Instructables itu dan cuma mau sistemnya jalan:
flash image hasil `make image`, lupakan langkah Kali-nya. Kalau kamu mau tahu
kenapa bentuknya begini: [docs/boot-chain.md](docs/boot-chain.md).

## Kontribusi / roadmap singkat

Dibutuhkan: (1) laporan hasil boot per HWID biar tabel DTB bisa dipadatkan;
(2) kernel config `exynos-chromebook` sendiri (lebih kecil dari `armmp`, errata
773022 aktif, `CONFIG_CROS_EC_*` built-in); (3) uji `make installer`;
(4) varian rootfs A/B seperti ChromeOS supaya upgrade kernel bisa rollback;
(5) pin checksum U-Boot prebuilt + mirror keduanya.

Lisensi skrip: MIT (lihat `LICENSE`). Debian dan nama/logonya milik
organisasinya masing-masing; proyek ini tidak berafiliasi dengan Debian, Google,
atau Samsung.
