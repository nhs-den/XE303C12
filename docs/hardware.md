# Hardware: Samsung Chromebook Series 3 (XE303C12)

Semua keputusan desain XE303OS diturunkan dari tabel ini. Kalau kamu punya
unit dengan revisi berbeda, ubah `DTB_CANDIDATES` di `config/build.conf`.

| Komponen | Isi | Konsekuensi untuk OS |
|---|---|---|
| SoC | Samsung Exynos 5250, 2× Cortex-A15 @ 1.7 GHz, L2 1 MB | **ARMv7 hard-float** → Debian `armhf`. Bukan `amd64`, bukan `arm64`. |
| RAM | 2 GB DDR3L-800, disolder | RAM tetap 2 GB → **zram wajib**, tanpa compositor, tanpa DE berbasis GL, jangan pasang `tracker`/`baloo`. |
| Storage | 16 GB eMMC iNAND (bisa dilepas/diganti pada beberapa unit) | Jangan pakai swap di eMMC (wear); pakai `noatime,commit=60`; journal dibatasi 64 MB. |
| Panel | 11.6" 1366×768 TN, backlight PWM | eDP → **LVDS bridge NXP PTN3460**: DTB salah = layar blank, bukan karena GPU. |
| GPU | ARM **Mali-T604** (Utgard, 4 shader) | **Tidak ada driver OpenGL mainline.** Pakai framebuffer `exynos-drm` (DECON/FIMD) + X `modesetting`/`fbdev`. GLX dimatikan di `10-exynos.conf`. |
| WiFi/BT | Marvell 88W8797 combo (SDIO), 802.11 a/b/g/n | Driver `mwifiex_sdio`, firmware `mrvl/sd8797_uapsta.bin` (paket Debian `firmware-libertas`). BT pakai `btmrvl_sdio`. Matikan WiFi powersave. |
| Audio | Codec **MAX98090** (rev awal kadang MAX98095) di I2S + speaker 2×1.5 W | Machine driver `SND_SOC_SNOW`. Kontrol "Left/Right Speaker Mixer …" default **mute** → ada `xe303os-alsa.service`. |
| Keyboard / EC | ChromeOS EC lewat I2C (`cros_ec`) | `cros_ec_keyb` = keyboard & tombol search/brightness; `cros_ec` = baterai. Tanpa ini keyboard mati. |
| Touchpad | Atmel maXTouch di I2C | `atmel_mxt_ts` + libinput (tapping, clickareas). |
| USB / SD | 1× USB 3.0, 1× USB 2.0, SDXC | Boot dari **SD lebih andal daripada USB** pada keluarga ini. |
| Kamera | USB-UVC internal | `uvcvideo` (built-in di `armmp`) — langsung jalan. |
| Baterai | 30 Wh Li-Po | `upower` + `tlp`; jangan pasang `power-profiles-daemon` bersamaan. |
| Firmware | Fork **Das U-Boot ("H2C")**, bukan coreboot+depthcharge | Lihat `docs/boot-chain.md`. Ini sebabnya ISO tidak bisa dipakai. |

## Dua varian yang tertukar di lapangan

Model number Samsung tidak konsisten antar region, dan komunitas melaporkan dua
revisi dengan nama XE303C12 / "Chromebook 2":

* **Exynos 5250** — dual Cortex-A15, Mali-T604, 1366×768. Ini yang tercatat
  sebagai *Series 3 XE303C12* di sebagian besar databasenya (dan yang diasumsikan
  kit ini). Board mainline: `exynos5250-snow` / `exynos5250-spring`.
* **Exynos 5800 (peach-pi)** — quad A15+A7, 1080p pada beberapa unit, board
  mainline `exynos5800-peach-pi`.

Kernel Debian `armmp` menyertakan **kedua** DTB
(`exynos5250-snow.dtb`, `exynos5800-peach-pi.dtb`), jadi XE303OS memaketkan
semua kandidat dan membiarkan U-Boot/deptcharge memilih. Cara memastikan:

```sh
# dari ChromeOS (Dev tools: Ctrl+Alt+T lalu 'shell') atau dari sistem hasil boot
cat /proc/device-tree/compatible      # harus menyebut snow / spring / peach-pi
crossystem model hwid                 # ARM-VEGA / PEACHPi / dst
grep -m1 CPU /proc/cpuinfo
```

## Kapasitas yang realistis di perangkat ini

| | Perkiraan |
|---|---|
| rootfs base + LXQt + firefox-esr | ~3.0–3.6 GB |
| idle RAM (LXQt, tanpa browser) | ~230–330 MB |
| idle RAM (Xfce) | ~330–450 MB |
| buka 4–6 tab Firefox | 1.2–1.7 GB (zram mulai bekerja) |
| boot dari cold ke login | ~25–45 s (eMMC lama), 1–3 m pada boot pertama |

Target yang masuk akal: browsing, terminal, SSH, PDF, video 720p (software
decode, kadang drop frame), office ringan. **Tidak** masuk akal: Electron berat,
Wayland compositor, build kernel besar, Android emulation, WebGL game.

## Keterbatasan yang bukan salah distro

1. Mali-T604 → tanpa WebGL/GL. `QT_OPENGL=software` diset di `/etc/profile.d`.
2. `cpufreq` Exynos 5250 di mainline: OPP 600 MHz–1.7 GHz; beberapa unit
   tidak stabil di 1.7 GHz terus-menerus → kalau layar berkedip saat beban,
   turunkan `scaling_max_freq` (lihat `docs/troubleshooting.md`).
3. HDMI out: `exynos-drm` mendukung, tapi tanpa GL & dengan 1 monitor saja
   pada kebanyakan konfigurasi.
4. Tidak ada BIOS setup; satu-satunya "boot menu" adalah kombinasi tombol
   (`Ctrl+U` USB/SD, `Ctrl+B` eMMC) di layar developer mode.
