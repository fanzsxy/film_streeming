# FilmStream Personal V3 — Paket lengkap

**Ini source code, bukan APK jadi.** Paket ini berisi SEMUA file utama untuk mengganti unggahan lama pada repo GitHub yang menggunakan workflow generate-scaffolding.

Struktur:
- `.github/workflows/build-apk.yml` — workflow build otomatis
- `android/app/src/main/AndroidManifest.xml` — Android internet + app config
- `lib/main.dart` — V3 katalog, series, genre, history & startup gate
- `pubspec.yaml` — dependencies & version 1.0.3+3

## Penting: upload ke PATH yang benar
File `lib/main.dart` harus berada di `lib/main.dart`, BUKAN `/main.dart`. Jangan unggah zip sebagai satu file. GitHub web uploader kadang tak mempertahankan folder `.github` ketika di-drag; buat `.github/workflows/build-apk.yml` via **Add file > Create new file** jika perlu. Jika mengunggah via Git/GitHub Desktop, replace file sesuai path lalu commit/push.

Sebelum build: set repository Action secret `TMDB_TOKEN` dengan token yang tidak pernah dipublikasikan. Build via Actions > Build FilmStream APK > Run workflow. Download artifact terbaru.

Pemutar hanya memutar URL video yang dapat Anda gunakan. Riwayat tersimpan untuk player internal saja, bukan browser eksternal. V3 belum otomatis menghubungkan player LK21.

Paket dirakit dari file startup-fix terbaru dan workflow proyek awal. Belum dilakukan build Flutter di lingkungan ini; keberhasilan APK perlu diperiksa lewat GitHub Actions.
