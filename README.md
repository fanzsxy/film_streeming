# FilmStream V3 — Riwayat & Lanjutkan Menonton

Unggah/ganti **dua file** ke root repo GitHub yang sama: `lib/main.dart` dan `pubspec.yaml`. Pastikan perubahan `pubspec.yaml` ikut diunggah karena versi ini menggunakan `shared_preferences`. Workflow lama menjalankan `flutter pub get` dan `flutter build apk` sehingga tidak perlu diubah.

Fitur: ikon riwayat di kanan atas, daftar tontonan dengan progress bar, durasi terakhir, simpan posisi otomatis sekitar setiap 5 detik dan pada pause/keluar/background, lanjut dari posisi tersimpan, putar ulang setelah selesai, hapus riwayat. Film memakai key type + TMDB ID; dukungan key episode sudah ada pada player untuk integrasi sumber episode kelak, tetapi V2 masih belum punya player episode.

Data hanya tersimpan di perangkat (SharedPreferences); bisa hilang bila data aplikasi dihapus/uninstall. Update APK dengan identitas paket yang sama seharusnya mempertahankan data aplikasi. Tautan URL video yang sudah kedaluwarsa mungkin gagal saat dilanjutkan; ganti URL di halaman detail. Riwayat hanya tercatat jika memutar lewat player FilmStream, tidak untuk halaman sumber yang dibuka di browser.

Belum diuji build Flutter di lingkungan pembuatan ini: jalankan Actions dan kirim log error bila ada.
