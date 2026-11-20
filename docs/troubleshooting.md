# Troubleshooting XE303OS di XE303C12

Urutkan dari yang paling sering. Setiap bagian: **gejala → sebab → cek → fix**.

## 1. Tekan Ctrl+U: 2× bip, layar hitam, kembali ke ChromeOS

> Catatan nuansa: penolakan ini **tidak universal**. Image Kali 2019.3 exynos
> (partisi kernel tunggal + rootfs di p2) dilaporkan boot di XE303C12, dan
> panduan Instructables "Linux on XE303C12 Chromebook" (Sirius38, 2020)
> memakainya tanpa masalah. Yang banyak dilaporkan gagal adalah image peach-pi
> (Exynos 5800) dan sebagian unit snow. Karena itu kit ini menyediakan **dua**
> jalur: default `uboot-extlinux`, dan `make BOOT_MODE=vboot-direct image`
> (layout KERN-A=p1 + rootfs=p2, sama seperti image Kali itu).

**Sebab:** firmware (U-Boot H2C) menolak image partisi kernel. Ini perilaku
terdokumentasi pada keluarga snow/peach — bahkan image yang lolos
`futility vbutil_kernel --verify` bisa ditolak. Kadang juga murni soal media.

```sh
# 1. pastikan flag-nya benar (dari ChromeOS: Ctrl+Alt+T -> shell)
sudo crossystem dev_mode dev_boot_usb dev_boot_signed_only   # harus 1 1 0
sudo crossystem dev_boot_legacy=1     # aktifkan Alt-Legacy (Ctrl+Alt-L): jalur boot
                                      # teks; pada board U-Boot H2C ini sering yang
                                      # membuat payload booting terbaca
sudo crossystem hwid model            # catat, utk DTB
# 2. pastikan image di kartu memang punya partisi kernel yang benar
sudo cgpt show /dev/sdb | head
sudo futility vbutil_kernel --verify /dev/sdb1 | head -20
```

**Fix, berurutan:**
1. Ganti kartu/flashdisk (SDHC kelas 10, ≤32 GB, bukan USB-3 thumb). Ini penyebab
   nomor 1 pada perangkat ini, sesuai catatan hexdump0815:
   *"peach chromebooks seem to not boot properly with all sd cards (and not at all
   from usb devices)"*.
2. Ulang dengan `BOOT_MODE=uboot-extlinux` (default kit ini) — kalau kamu pakai
   `vboot-direct`, itulah sumbernya.
3. Coba `nv_uboot-snow.kpart` prebuilt (`UBOOT_PREBUILT_URL`) yang memang dibuat
   untuk menerima boot dari USB pada board H2C.
4. Kalau dulu pernah memasang firmware modifikasi, cek `cbms`/`futility gbb
   --show --flags` — flag GBB yang salah memaksa verifikasi.

## 2. U-Boot/Jersey jalan tapi layar tetap hitam

**Sebab paling umum: DTB salah**, bukan GPU. Panel XE303C12 lewat bridge
**NXP PTN3460 (eDP→LVDS)**; DTB peach-pit/spring mengirim timing yang salah,
dan errornya cuma muncul di dmesg:

```
[drm:drm_atomic_bridge_chain_pre_enable] *ERROR* Failed to send config to bridge (-5)
```

```sh
# dari sistem (konek SSH) - lihat DTB yang sedang aktif
cat /proc/device-tree/compatible ; ls /sys/class/backlight ; dmesg | grep -i bridge
```

**Fix:**
1. Edit partisi BOOT (p3) dari host lain:
   `sudo mkdir /mnt/b && sudo mount /dev/sdb3 /mnt/b && sudoedit /mnt/b/extlinux/extlinux.conf`
   → ganti baris `DEFAULT` ke LABEL dengan DTB lain (`exynos5250-snow`,
   `exynos5250-spring`, `exynos5800-peach-pi`). Kit ini menulis satu LABEL per DTB
   supaya berpindah cukup ganti satu baris.
2. Pastikan `clk_ignore_unused` ada di `APPEND` — tanpanya DECON/FIMD dimatikan
   sebelum panel sempat dihidupkan. Cek: `build/60-bootimg.sh` memakai
   `config/kernel-cmdline.conf`.
3. Cek `backlight` tidak 0 (`tools/device-status.sh --fix`).
4. Kernel 6.6–6.13 punya regressi urutan `drm_atomic_bridge_chain_*` yang
   merusak pipeline display Chromebook (sudah di-revert hilir). Kalau kamu
   berada di kernel itu dan langkah 1–3 benar: pakai `SUITE=bookworm`
   (kernel 6.1) dan laporkan.

## 3. Layar berkedip / sesaat hitam saat mengetik atau di bawah beban

**Sebab:** transisi DVFS pada rail yang dipakai display. Di peach (Mali-T628 +
panfrost) ini terbukti dari devfreq GPU; di snow (Mali-T604) tidak ada driver GL,
jadi tersangkanya CPU DVFS/heat.

```sh
# kunci governor & turunkan frekuensi maksimum (uji dulu, jangan langsung persist)
for c in /sys/devices/system/cpu/cpu*/cpufreq; do echo performance | sudo tee $c/scaling_governor; done
echo 1400000 | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
# kalau hilang -> simpan persisten: aktifkan unit xe303os-cap.service (buat dari pola ini)
```

Kalau frekuensi terkunci tetap berkedip: cek kabel panel (kasus nyata di unit
berumur) — bandingkan dengan boot ChromeOS; kalau di ChromeOS juga kedip, itu
hardware.

## 4. Tidak ada bunyi (speaker senyap, tapi headset berbunyi)

**Sebab:** codec MAX98090 default-nya **mute** di 4 jalur "Speaker Mixer".
`xe303os-alsa.service` mengurusnya, tapi ia harus tahu nama kontrol yang benar.

```sh
amixer -c 0 scontrols | head -20
sudo /usr/lib/xe303os/alsa-unmute.sh --store   # simpan state ke /var/lib/alsa/asound.state
speaker-test -c2 -t wav -l1
```

Kalau nama kontrol berbeda dari daftar di `alsa-unmute.sh`, tambahkan namanya ke
array `CTRLS` (script-nya cuma memanggil `amixer sset <nama> on unmute`).
Untuk PulseAudio/PipeWire: `pactl set-sink-mute @DEFAULT_SINK@ 0`
lalu `pactl set-sink-volume @DEFAULT_SINK@ 80%`.

## 5. WiFi sering putus / tidak dapat-connect

```sh
dmesg | grep -iE 'mwifiex|firmware'          # "Direct firmware load for mrvl/sd8797_uapsta.bin failed"?
sudo apt-get install -y firmware-libertas    # dari host via mount, atau unduh .deb & dpkg -i
sudo systemctl status NetworkManager
nmcli device set wlan0 powersave off         # mwifiex + powersave = putus-putus
```

`overlay/etc/NetworkManager/conf.d/xe303os.conf` sudah men-set
`wifi.powersave = 2` dan `mwifiex_sdio ps_mode=0` (modprobe.d). Kalau kamu
memakai `iwd`/`wpa_supplicant` langsung, matikan powersave-nya juga.
5 GHz sering tidak stabil di 88W8797 — pakai 2.4 GHz saat install.

## 6. Keyboard internal mati (hanya keyboard USB yang jalan)

**Sebab:** `cros_ec_keyb` tidak ter-load (keyboard + tombol search/mirror ada di
EC ChromeOS lewat I2C).

```sh
dmesg | grep -i cros_ec
sudo modprobe cros_ec_i2c; sudo modprobe cros_ec_keyb
ls /etc/modules-load.d/xe303os.conf && sudo systemctl restart systemd-modules-load
```

Kalau modul tidak ada di kernel (`modinfo cros_ec_keyb` gagal), kernel Debian
`armmp` di suitemu tidak menyalakan `CONFIG_CROS_EC`; build kernel sendiri
(`exynos_defconfig` + CROS_EC) adalah jalurnya.

## 7. Touchpad tidak dikenali

```sh
sudo modprobe atmel_mxt_ts
i2cdetect -y 1 2>/dev/null | grep -E '4a|67'      # alamat maXTouch
sudo apt-get install -y i2c-tools
dmesg | grep -i maxtouch
```

Umumnya butuh DTB yang benar (lihat §2). libinput sudah distel di
`40-libinput.conf`; kalau kursor terbalik: `xinput set-prop "Atmel maXTouch" "libinput Natural Scrolling Enabled" 0`.

## 8. Sistem tidak boot setelah `apt full-upgrade`

**Sebab:** tidak ada GRUB; extlinux.conf harus dibangun ulang oleh
`/etc/kernel/postinst.d/90-xe303os-boot`. Kalau hook gagal (mis. mkimage tidak
ada), partisi BOOT masih menunjuk kernel lama yang sudah dihapus.

```sh
# boot dari SD/USB lain, lalu:
sudo mkdir /mnt/r && sudo mount /dev/mmcblk0p4 /mnt/r && sudo mount /dev/mmcblk0p3 /mnt/r/boot
for d in proc sys dev; do sudo mount --bind /$d /mnt/r/$d; done
sudo chroot /mnt/r /usr/lib/xe303os/mkboot.sh
sudo chroot /mnt/r ls /boot/extlinux/
```

Pencegahan: `sudo apt-mark hold linux-image-armmp`, atau upgrade kernel secara
sadar dan jalankan `tools/rebuild-kernel-partition.sh` sebelum reboot.

## 9. `tools/install-to-emmc.sh`: Read-only file system / Operation not permitted

Hardware write protect aktif. Untuk **boot** dari SD tidak perlu buka casing;
untuk **menulis partisi kernel eMMC** kebanyakan unit Exynos-5250 meminta sekrup
WP dilepas (tanda gembok/baut di penutup belakang) lalu `sudo cgpt` dijalankan
ulang. Alternatif tanpa bongkar: biarkan rootfs di SD, gunakan eMMC apa adanya
(ChromeOS) atau sebagai partisi data.

## 10. Ruang habis / eMMC penuh

```sh
sudo journalctl --vacuum-size=32M
sudo apt clean && sudo apt autoremove --purge
sudo ncdu -x /            # apt-get install ncdu
sudo du -xh --max-depth=2 /var | sort -h | tail
```

Image base dibuat 3.4 GiB: kalau flash ke SD 4 GiB, jalankan
`tools/grow-partition.sh` setelahnya.

## 11. Panas / batre cepat habis

```sh
sudo apt-get install -y power-profiles-daemon    # atau tlp (sudah dibundel)
powertop --calibrate                             # butuh 5-10 menit, jangan di-touch
cat /sys/class/power_supply/BAT0/capacity
```

Paling berdampak di perangkat ini: turunkan brightness (Fn+F6/F7), matikan
backlight saat idle (sudah via DPMS di `/etc/X11/Xsession.d/90xe303os-dpms`),
batasi `scaling_max_freq` 1.4 GHz, dan tutup tab (tanpa GPU decode, tiap tab
video = CPU 100%).

## 12. Kumpulkan laporan

```sh
sudo bash tools/device-status.sh > xe303os-status.txt
journalctl -b -p warning > boot.log
dmesg > dmesg.txt; lsblk -f >> xe303os-status.txt
uname -a; cat /proc/device-tree/compatible | tr '\0' ' '
```

Lampirkan ketiganya saat membuka isu. Sertakan keluaran `crossystem hwid model`
dari ChromeOS kalau masih ada — itu yang menentukan DTB.
