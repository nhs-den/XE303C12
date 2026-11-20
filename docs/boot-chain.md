# Boot chain: kenapa bukan ISO, dan apa yang ditulis ke partisi 1

## Rantai boot XE303C12

```
EC (ChromeOS Embedded Controller)
  └─ fork Das U-Boot "H2C"  (di SPI flash; BUKAN coreboot+depthcharge)
       ├─ baca GPT disk internal / USB / SD
       ├─ cari partisi tipe  FE3A2A5D-4F32-41A7-B725-ACCC3285A309 ("ChromeOS kernel")
       │    ├─ 32 KiB pertama: preamble verified-boot (vbkernel keyblock, dll.)
       │    └─ sisanya: payload  ->  di mode dev, signature TIDAK diverifikasi
       └─ eksekusi payload di CONFIG_SYS_TEXT_BASE (Exynos5250: 0x40008000 utk kernel)
            └─ payload kita = U-Boot chainloading
                 └─ `sysboot`/extlinux: baca /extlinux/extlinux.conf di partisi BOOT
                      └─ KERNEL zImage + INITRD + FDT dtb + APPEND cmdline
                           └─ initramfs → mount root=UUID=… → systemd → lightdm
```

Konsekuensi yang penting dan sering salah dipahami:

1. **Bootloader tidak membaca ISO9660.** Tidak ada jalur "burn ISO ke flashdisk"
   pada perangkat ini. Yang dibaca cuma partisi GPT bertipe kernel ChromeOS.
   Karena itu artefak XE303OS yang di-flash adalah **`.img.xz`**, dan `make iso`
   menghasilkan kontainer/dokumentasi (lihat `docs/iso-note.md`).
2. **Developer mode wajib.** Tanpa dev mode, U-Boot hanya menerima image yang
   ditandatangani kunci Google. Di dev mode, image bertanda test-key
   (`/usr/share/vboot/devkeys`) diterima. Verifikasi `futility vbutil_kernel
   --verify` pada build ini sengaja dijalankan supaya strukturnya benar, bukan
   supaya kuncinya Google.
3. **Dua partisi kernel (KERN-A, KERN-B).** Firmware memilih dengan atribut GPT
   pada tiap entri partisi kernel: *priority*, *tries-remaining*, dan
   *successful* (dikelola dengan `cgpt show/add/prioritize`). Kita tulis image
   yang sama ke keduanya: kalau KERN-A korup, KERN-B jadi fallback.
   `cgpt add -i 1 -P 15 -T 5 -S 1` = prioritas penuh, 5 kali coba, dianggap sukses.
4. **Align 2 MiB.** Dokumen disk-format Chromium OS menyatakan partisi kernel
   dan filesystem "2MB aligned and sized"; layout XE303OS memakai `first-lba`
   2048 (1 MiB) dan semua ukuran partisi kelipatan 2 MiB, jadi aman untuk
   firmware lama maupun `ext4`/`f2fs`.
5. **root= dan `kern_guid`.** Bootstub ChromeOS menambahkan `kern_guid=<uuid>`
   dan memaknai `root=PARTUUID=%U/PARTNROFF=1` (root = partisi tepat setelah
   partisi kernel yang di-boot). Di layout kita, ROOTFS **bukan**partisi
   berikutnya (KERN-B ada di antaranya), karena itu XE303OS selalu memakai
   `root=UUID=<uuid filesystem>` yang deterministik — lihat
   `ROOTFS_UUID` di `config/build.conf`.

## Kenapa mode default `uboot-extlinux`, bukan kernel vboot langsung

Keluarga **snow / spring / peach-pi / peach-pit** (semua yang pakai U-Boot H2C)
mempunyai rekaman kegagalan yang konsisten: partisi kernel yang *valid dan
tersignatur benar* tetap **ditolak diam-diam** — 2× bip, lalu kembali ke
ChromeOS. Ini didokumentasikan di beberapa tempat:

* forum chrultrabook: laporan identik untuk **Samsung XE303C12 (Snow)**;
  dikonfirmasi MrChromebox sebagai keterbatasan firmware, belum selesai.
* pengujian ArchLinuxARM pada peach-pi (Exynos 5800): instruksi resmi
  menghasilkan `vbkernel` yang lolos `futility --verify`, tapi firmware menolak.
* proyek `velvet-os/imagebuilder` (hexdump0815) yang secara khusus menangani
  board-board ini memakai **U-Boot chainloading + extlinux**, dan
  dokumentasinya menulis: *"the peach chromebooks seem to not boot properly with
  all sd cards (and not at all from usb devices)"*.

Karena itu XE303OS memaketkan U-Boot chainloading di KERN-A/B (jalur yang
terbukti jalan di perangkat ini) dan menyisakan `BOOT_MODE=vboot-direct`
(mkdepthcharge + vboot) untuk orang yang tahu risiko atau untuk board non-Exynos.

Nuansa yang perlu dicatat supaya tidak jadi dogma: penolakan itu **tidak
universal**. Image Kali 2019.3 "exynos chromebook" — satu partisi kernel
(vboot) + rootfs ext4 di partisi berikutnya — dilaporkan boot dan dipakai di
XE303C12 (mis. panduan Instructables Sirius38, 2020: `growpart /dev/mmcblk1 2`,
`resize2fs`, lalu `cgpt repair`). Kesimpulan yang benar bukan "vboot mustahil",
melainkan: **vboot langsung = 1 taruhan tambahan**, dan pada 2 GB RAM/16 GB eMMC
kamu tidak mau menghabiskan sore untuk mengalahkan firmware. Karena itu kedua
jalur ada di repo ini; coba `uboot-extlinux` dulu, `vboot-direct` sebagai
percobaan kedua (`make BOOT_MODE=vboot-direct image`).

## Isi tiap partisi

| # | Nama | Tipe GUID | FS | Isi |
|---|---|---|---|---|
| 1 | KERN-A | `FE3A2A5D-4F32-41A7-B725-ACCC3285A309` | raw | image U-Boot (`u-boot.kpart`, incl. preamble vboot 64 KiB) |
| 2 | KERN-B | sama | raw | salinan identik (fallback) |
| 3 | BOOT | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` | ext2 4K | `<kver>/{vmlinuz,zImage,uImage,initrd.img,uInitrd,exynos*.dtb}`, `extlinux/extlinux.conf`, `env.txt` |
| 4 | ROOTFS | `0FC63DAF-…` | ext4 (tanpa `64bit`) | Debian armhf + desktop |

Catatan pilihan GUID: ChromeOS punya tipe khusus rootfs
(`3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC`). Kita sengaja memakai **Linux data**
`0FC63DAF-8483-4772-8E79-3D69D8477DE4` supaya `update_engine` dan tooling
ChromeOS tidak mengira ada pasangan A/B untuk rootfs (kita cuma punya satu),
dan supaya semua tool partisi umum mengenalnya. Kalau kamu butuh kompatibel
dengan tool ChromeOS, ganti di `build/lib/layout.sh`.

`mke2fs -d` dipakai untuk membangun filesystem image **tanpa loop device**
(e2fsprogs ≥ 1.43) lalu `dd` ke offset partisi. Tidak ada `mount` di host build.

## Fallback `env.txt`

Beberapa prebuilt U-Boot (mis. `nv_uboot-snow.kpart`) tidak dieksekusi sebagai
`sysboot` penuh, tapi membaca `/env.txt` di partisi boot dengan variabel:
`boot_part`, `root_part`, `loadaddr`, `dtaddr`, `initrdaddr`, `kernel_path`,
`dtb_path`, `bootargs`. Karena itu XE303OS **selalu** menulis `env.txt` bersama
`extlinux.conf`, dan ikut menyediakan `uImage`/`uInitrd` (header 64 B,
`mkimage -A arm`) karena flow itu memakai `bootm`, bukan `bootz`.

Kalau U-Boot-mu adalah varian itu, lihat `docs/troubleshooting.md` §"env.txt".

## Setelah upgrade kernel

Kernel Debian di-upgrade → `/boot/vmlinuz-<baru>` dibuat, tapi **tidak ada GRUB**
yang memperbarui partisi BOOT. Karena itu ada tiga hook yang dipasang:

```
/etc/kernel/postinst.d/90-xe303os-boot      -> mkboot.sh <kver>
/etc/initramfs-tools/postinst.d/90-xe303os-boot -> mkboot.sh <kver> (lagi, setelah initrd jadi)
/etc/kernel/prerm.d/90-xe303os-boot         -> prune /boot/<kver> lama (jaga 2 terbaru)
```

`mkboot.sh` menyusun ulang `extlinux.conf` **dan**, kalau `depthcharge-tools`
ada, membuat `/boot/depthcharge/<kver>.img` untuk jalur vboot. Menulis ke
partisi KERN-A/B tetap harus eksplisit:

```sh
sudo bash tools/rebuild-kernel-partition.sh          # atau: sudo depthchargectl write --allow-current
```

Itu sebabnya panduan di `docs/install.md` menyarankan menahan kernel
(`apt-mark hold` / update terpisah) kalau kamu tidak mau repot.
