# FilmStream V5 — Automatic Source Manager

Pembaharuan dari FilmStream V4.1, mempertahankan katalog TMDB, genre, series, WebView opsional, Native Player, dan riwayat. Menambahkan `Tonton Otomatis` untuk film serta pada pilihan episode series. Pemutar hanya menerima URL HTTPS MP4/HLS dari backend yang dikonfigurasi.

**Belum termasuk film komersial atau integrasi stream LK21.** `backend/sources.json` sengaja kosong. Jangan memasukkan tautan halaman HTML, iframe, atau stream yang tidak berhak Anda gunakan. API tidak menyediakan atau mengekstrak video secara otomatis tanpa sumber yang dimasukkan/dikonfigurasi.

## File yang diubah
- `lib/main.dart`: tombol pencarian sumber, juga untuk episode.
- `lib/source_manager.dart`: pemanggil Source API, validasi respons, status tidak tersedia/error.
- `pubspec.yaml`: versi aplikasi V5 dan dependensi V4.1 dipertahankan.
- `.github/workflows/build-apk.yml`: menambahkan repository variable `SOURCE_API_BASE`.
- `backend/`: server contoh FastAPI dan registry JSON sumber berizin.

## Backend

```bash
cd backend
python -m pip install -r requirements.txt
uvicorn main:app --reload
```

`GET /health` dan `GET /resolve?tmdb_id=123&type=movie&season=0&episode=0`.
Sumber yang tidak tercatat mengembalikan `{ "available": false }`. Format contoh tersedia pada `sources.example.json` (placeholder, bukan video aktif). Isi `sources.json` dengan hanya URL video yang memang diizinkan dan cocok dengan TMDB ID serta episode.

Untuk digunakan APK, deploy API ke endpoint **HTTPS** yang dapat diakses HP; `localhost` di laptop tidak dapat langsung dipakai pada APK di HP. Tetapkan GitHub Repository Variables → Actions → `SOURCE_API_BASE` ke URL dasar backend, misalnya `https://api.domain-anda.com` (bukan halaman LK21). `TMDB_TOKEN` tetap berada di Secrets.

## Update repository tanpa merusak Android permanen
Upload/ganti `lib/main.dart`, `lib/source_manager.dart`, `pubspec.yaml`, `.github/workflows/build-apk.yml`. Folder `backend` opsional jika akan deploy Source API. **Jangan hapus folder android/gradle permanen**. Workflow kemudian dijalankan lewat Actions. Perhatikan bahwa browser upload Github kadang tidak mempertahankan dot-folder; edit `.github/workflows/build-apk.yml` langsung jika perlu.

## Catatan pengujian
File ZIP dan sintaks Python telah diperiksa. Flutter SDK/Android SDK tidak tersedia di lingkungan pembuatan paket; kompilasi APK belum diverifikasi. Jika ada error, ambil baris `lib/...: Error` dari Actions.
