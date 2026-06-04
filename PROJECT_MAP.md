# Peta Proyek (inkubator_iot)

File ini adalah indeks cepat untuk **mengubah bagian tertentu** di proyek.

## 1) Alur Aplikasi / Titik Masuk
- Entry app + inisialisasi Firebase + tema: `lib/main.dart`
- Halaman pertama (splash): `lib/pages/splash_screen.dart`
- Halaman pilih perangkat: `lib/pages/device_selector_page.dart`
- Dashboard Inkubator: `lib/pages/home_page.dart`
- Form tambah/edit tanaman: `lib/pages/add_plant_page.dart`
- Halaman Nutrimix: `lib/pages/nutrimix_page.dart`

## 2) Lokasi Ikon
### Halaman utama
- Tombol/ikon device selector (`local_florist`, `science`): `lib/pages/device_selector_page.dart`
- Ikon FAB Home (`add`): `lib/pages/home_page.dart`
- Ikon simpan/tambah di Add Plant: `lib/pages/add_plant_page.dart`
- Ikon back/power Nutrimix: `lib/pages/nutrimix_page.dart`
- Visual logo splash: `lib/pages/splash_screen.dart`

### Widget reusable (banyak ikon)
- Ikon relay (`flash_on`): `lib/widgets/relay_switch.dart`
- Ikon status ESP (`wifi`, `wifi_off`): `lib/widgets/esp_status_card.dart`
- Ikon default suhu (`thermostat`): `lib/widgets/temperature_card.dart`
- Ikon baris tanaman (`leaf`, `power`, `pencil`, `trash`): `lib/widgets/plant_tile.dart`
- Ikon tile jadwal siram (`drop`, `pencil`, `trash`): `lib/widgets/watering_time_tile.dart`
- Wrapper ikon section form: `lib/widgets/form_section_card.dart`

## 3) Lokasi Fungsi/Logika Utama
### Controller
- Logika runtime Home (timer, listener, notifikasi, jadwal manual):
  `lib/controllers/home_controller.dart`
- Model data form tanaman + mapping (`toMap`, `fromMap`):
  `lib/controllers/plant_controller.dart`

### Lapisan data/repository
- Implementasi Firebase (semua stream/tulis database):
  `lib/services/firebase_service.dart`
- Kontrak repository device:
  `lib/domain/repositories/device_repository.dart`
- Kontrak repository plant:
  `lib/domain/repositories/plant_repository.dart`

### Logika notifikasi
- Inisialisasi local notification + FCM:
  `lib/services/notification_service.dart`

## 4) Lokasi Ubah Warna/Tema
### Tema global aplikasi
- Material theme/light-dark seed:
  `lib/main.dart`

### Background halaman utama
- Gradient Home:
  `lib/pages/home_page.dart`
- Gradient Device Selector:
  `lib/pages/device_selector_page.dart`
- Gradient Add Plant:
  `lib/pages/add_plant_page.dart`
- Background + glow Splash:
  `lib/pages/splash_screen.dart`
- Gradient Nutrimix:
  `lib/pages/nutrimix_page.dart`

### Style kartu bersama
- Shell kartu industrial (dipakai lintas halaman):
  `lib/widgets/industrial_card.dart`
- Style kartu section form:
  `lib/widgets/form_section_card.dart`

### Palet warna yang saat ini dipakai
- Hijau gelap dasar: `#1B5E20`
- Hijau sedang: `#2E7D32`
- Hijau aksen: `#66BB6A`
- Hijau soft: `#81C784`
- Teks terang: `#E8F5E9`, `#F1F8E9`, `#B2DFDB`

## 5) Panduan Edit Cepat
- Ubah perilaku relay (lamp/fan/sprayer):
  `lib/controllers/home_controller.dart`
- Ubah path sensor/struktur schema database:
  `lib/services/firebase_service.dart`
- Ubah field form tambah/edit tanaman:
  `lib/pages/add_plant_page.dart`
- Ubah urutan kartu di Home:
  `lib/pages/home_page.dart`
- Ubah transisi antar halaman:
  `lib/pages/device_selector_page.dart` dan `lib/pages/splash_screen.dart`

## 6) Alur Kerja yang Disarankan untuk Perubahan UI
1. Ubah gradient/AppBar di level halaman dulu.
2. Jika ingin berlaku global, ubah widget bersama (`IndustrialCard`, `FormSectionCard`).
3. Ubah style ikon/teks di widget halaman.
4. Jalankan: `flutter analyze`

