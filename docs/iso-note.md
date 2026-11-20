# Soal "ISO siap install" — apa yang bisa dan tidak bisa dilakukan perangkat ini

Kamu meminta *file ISO siap install*. Jawaban jujurnya, dan ini fakta
firmware/hardware (bukan preferensi):

## XE303C12 tidak bisa boot dari ISO

| | |
|---|---|
| Yang dilakukan "burn ISO" biasa | menaruh ISO9660 (+ el Torito boot catalog) di seluruh disk, lalu BIOS/UEFI membacanya |
| Yang dilakukan firmware XE303C12 | membaca **GPT**, mencari partisi tipe `FE3A2A5D-4F32-41A7-B725-ACCC3285A309` ("ChromeOS kernel"), memuat payload dari partisi itu |
| Akibat | ISO9660, tidak peduli seberapa hybrid pun ia dibuat, **tidak pernah dibuka**. Tidak ada "boot menu → pilih CD-ROM". |

Ditambah lagi: arsitekturnya **ARMv7 hard-float (armhf)**. Semua ISO netinst
amd64/i386 tidak akan pernah boot di sini, dan Debian **tidak** menerbitkan ISO
x86 yang bisa dipakai di perangkat ARM. (ISO netinst armhf resmi memang ada di
Debian — `debian-13.x-armhf-netinst.iso` — tapi ia ditujukan untuk mesin ARM
dengan UEFI/grub-mkrescue-style image, bukan untuk boot flow U-Boot H2C Chromebook;
tetap perlu dibungkus ke partisi kernel.)

Karena itu artefak "siap install" yang benar untuk XE303C12 adalah **image disk
GPT** yang ditulis dengan `dd`:

```
dist/xe303os-1.0.0-snow-trixie.img.xz        <-- flash ini (dd / balenaEtcher / Rufus DD)
dist/xe303os-1.0.0-snow-trixie.iso           <-- kontainer offline (dibuat oleh `make iso`)
```

## Jadi `make iso` menghasilkan apa?

ISO9660 (level 3, Rock Ridge + Joliet) berisi:

```
BACA-SAYA.txt            penjelasan singkat + perintah flash
flash-from-iso.sh        skrip flash: sudo sh flash-from-iso.sh /dev/sdX
image/*.img.xz           image yang benar-benar di-flash (sistem + installer)
image/*.sha256           checksum
extlinux.conf / partitions.txt   bukti layout
docs/*.md                dokumentasi ini
tools/*.sh               tools on-device
config/                  build.conf + daftar paket (reproducibility)
```

Kegunaannya: satu file untuk diarsipkan, di-mount (`mount -o loop x.iso /mnt`),
disalin ke PC tanpa internet di lokasi install, dan dibakar ke DVD untuk
distribusi fisik. Ia **bukan** media boot untuk Chromebook ini — dan file
`BACA-SAYA.txt` di root ISO mengatakan hal yang sama supaya tidak ada yang
tersesat.

## Kalau kamu tetap menginginkan "ISO bootable"

Ada tiga jalur yang masuk akal, dan ketiganya tersedia di kit ini:

1. **QEMU** (buat screenshot/test tanpa perangkat):
   `make iso` tidak membantu di sini; gunakan image:
   `qemu-system-arm -machine virt -cpu cortex-a15 -m 1024 -kernel work/boot/<kver>/zImage`
   (dipakai `build/90-verify.sh`).
2. **Mesin ARM lain dengan UEFI** (mis. Raspberry Pi 4, rock64):
   pakai ISO netinst armhf resmi Debian seperti biasa — tidak ada hubungannya
   dengan XE303C12.
3. **Debian-installer di Chromebook** (inilah "installer" yang sebenarnya):
   `make installer` membuat `dist/xe303os-1.0.0-installer-trixie.img.xz`
   = partisi kernel U-Boot + partisi BOOT berisi kernel/initrd d-i +
   `preseed.cfg` (auto-install). Status: **eksperimental**, belum diuji di
   perangkat — jalurnya masih `.img`, karena hanya itu yang bisa dibaca firmware.

## Ringkas untuk README/dokumen lain

> XE303OS menghasilkan image GPT (`.img.xz`) yang di-flash ke SD/USB dengan
> `dd`, sesuai boot chain U-Boot H2C milik XE303C12; ISO disertakan sebagai
> kontainer offline, bukan sebagai media boot.
