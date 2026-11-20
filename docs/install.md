# Install XE303OS di Samsung Chromebook Series 3 (XE303C12)

## 0. Yang kamu butuhkan

* Unit XE303C12, **kabel power**, dan SD card ≥ 8 GB **atau** USB flashdisk ≥ 8 GB
  (SD kelas 10 lebih andal daripada USB pada perangkat ini).
* PC Linux/Windows/macOS untuk menulis image (`dd` / balenaEtcher / Rufus mode DD).
* Akses WiFi (untuk update; tidak wajib saat install).
* Opsional: monitor HDMI + keyboard USB bila suatu saat layar internal bermasalah.

## 1. Bangun image-nya (butuh 20–40 menit)

```sh
git clone <repo ini> && cd XE303C12
sudo make deps            # sekali saja: pasang debootstrap, vboot-utils, dst
make check                # test statis, tanpa root/internet
make precheck             # cek host, arsip Debian, ruang disk

sudo -E make image                     # default: trixie + LXQt, image .img.xz
# varian:
sudo -E make SUITE=bookworm DESKTOP=xfce image
sudo -E make BOOT_MODE=vboot-direct image      # tanpa U-Boot (lihat catatan risiko)
sudo -E make EXTRA=yes image                   # + util tambahan
make iso                                # kontainer ISO (BUKAN utk di-flash)
```

Hasil:

```
dist/xe303os-1.0.0-snow-trixie.img.xz         <-- INI yang di-flash
dist/xe303os-1.0.0-snow-trixie.img.xz.sha256
dist/xe303os-1.0.0-snow-trixie-partitions.txt
dist/xe303os-1.0.0-snow-trixie.iso            <-- arsip offline/dokumentasi
```

Verifikasi:

```sh
cd dist && sha256sum -c xe303os-1.0.0-snow-trixie.img.xz.sha256
```

## 2. Boot chain apa yang dipakai? (baca sebelum lanjut)

Perangkat ini tidak punya BIOS/UEFI biasa. Firmware-nya fork Das U-Boot yang
hanya memuat **partisi GPT bertipe ChromeOS-kernel** di awal disk — jadi tidak
ada "boot from ISO". `make image` sudah menaruh:

```
p1 KERN-A : U-Boot chainloading (yang dijalankan firmware)
p2 KERN-B : salinan (fallback)
p3 BOOT   : kernel+initrd+DTB+extlinux.conf  (yang dibaca U-Boot)
p4 ROOTFS : Debian armhf + LXQt
```

Detail & alasan: `docs/boot-chain.md`.

## 3. Masuk Developer mode

1. Matikan Chromebook sepenuhnya (tahan Power ~10 detik).
2. Colok power. Nyalakan dengan menahan **Esc** lalu tekan **Refresh (F6)**,
   lepaskan setelah muncul layar pemulihan.
3. Muncul "OS verification is OFF" → tekan **Ctrl+D** untuk boot normal,
   atau **Ctrl+U** untuk boot dari USB/SD.
4. Kalau `Ctrl+U` tidak muncul/menolak: boot ChromeOS, `Ctrl+Alt+T` → ketik
   `shell` → `sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0`.
5. Beberapa unit menolak **menulis** ke eMMC (bukan boot USB) selama
   *hardware write protect* aktif: sekrup WP di bawah penutup belakang harus
   dilepas. Untuk boot dari SD/USB tidak perlu buka casing.

## 4. Tulis image ke SD/USB

```sh
lsblk -d -o NAME,SIZE,MODEL,TRAN          # pastikan nama target, mis. /dev/sdb
sudo umount /dev/sdb?                      # lepas partisi yang ke-mount
sudo bash tools/write-usb.sh dist/xe303os-1.0.0-snow-trixie.img.xz /dev/sdb
```

tanpa skrip:

```sh
xz -dc dist/xe303os-1.0.0-snow-trixie.img.xz \
  | sudo dd of=/dev/sdb bs=4M conv=fsync status=progress && sync
```

Windows: pakai balenaEtcher atau Rufus **mode DD** (bukan ISO).

## 5. Boot pertama

1. Colok SD/USB, nyalakan, tahan **Esc**+Refresh → **Ctrl+U**.
2. Layar "U-Boot / extlinux" tidak selalu muncul; biasanya langsung jalan.
   Boot pertama 1–3 menit (systemd grow partisi + generate SSH host key).
3. Login otomatis ke LXQt. Terminal: `sudo fdisk -l` lihat ROOTFS sudah seukuran
   kartu; `df -h /` harus ikut membesar.
4. **Ganti password:** `passwd`.
5. **Bunyi:** kalau speaker senyap, `sudo bash tools/device-status.sh --fix`
   lalu `speaker-test -c2 -t wav`.
6. WiFi: NM applet, atau `nmcli device wifi connect "SSID" password "pass"`.

## 6. Pindahkan ke eMMC internal (opsional, ini "install" sungguhan)

Boot dari USB/SD seperti di atas, lalu:

```sh
sudo apt-get update && sudo apt-get install -y gdisk   # bila perlu
git clone <repo> ~/xe303os && cd ~/xe303os
sudo bash tools/install-to-emmc.sh                      # target /dev/mmcblk0
```

Skrip ini: menulis ulang GPT di eMMC (KERN-A/B + BOOT + ROOTFS), `rsync` rootfs,
menyalin `/boot`, menulis image U-Boot ke p1/p2, `cgpt prioritize`.
Kalau gagal dengan `Read-only file system` / `Operation not permitted` →
write-protect aktif: lepas sekrup WP, atau biarkan sistem tinggal di SD
(kinerjanya cukup layak; eMMC bisa dipakai sebagai `/data`).

Setelah pindah, boot test: matikan, nyalakan, tekan **Esc+Refresh → Ctrl+B**.

## 7. Perawatan

```sh
sudo apt update && sudo apt full-upgrade        # kernel ikut ter-upgrade
sudo /usr/lib/xe303os/mkboot.sh                 # hook sudah otomatis; ini manualnya
sudo bash tools/rebuild-kernel-partition.sh     # tulis ulang KERN-A/B dari perangkat
sudo bash tools/grow-partition.sh               # bila kloning ke kartu lebih besar
sudo bash tools/unique-ids.sh                   # kalau menginstal ke 2 unit
apt-mark hold linux-image-armmp                 # opsi: tahan kernel supaya tidak
                                                # berubah diam-diam saat full-upgrade
```

Selalu **jaga satu SD/USB berisi image lama** — kalau partisi kernel tertulis
rusak, itu satu-satunya jalan masuk tanpa bongkar perangkat.

## 8. Reset total

```sh
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=64 conv=notrunc   # hapus GPT (berbahaya!)
# lalu kembalikan ChromeOS dengan recovery image + USB writer dari Google
```

Untuk kembali ke ChromeOS secara resmi: buat *ChromeOS Recovery* di PC lain
(Chrome Web Store "Chromebook Recovery Utility", model **XE303C12**),
colok USB, `Esc+Refresh+Power`, lalu `Ctrl+U`.
