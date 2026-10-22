# FilmStream Personal v2

Upgrade dari v1: beranda rail trending/film/series, navigasi bawah (Beranda, Film, Series, Genre, Favorit), genre TMDB, pencarian film + TV, pagination 50 halaman, detail series dengan season & episode, favorit selama aplikasi aktif. Favorit belum persistent setelah aplikasi ditutup. Player HTTPS MP4/HLS + subtitle SRT eksternal seperti versi sebelumnya. Player LK21 belum terintegrasi otomatis.

## Upgrade repository existing
Di GitHub repository yang lama, ganti `lib/main.dart` dengan file dalam paket ini. Opsional ganti `.github/workflows/build-apk.yml` dengan workflow baru. Jangan upload seluruh ZIP dan jangan mengubah repository secrets. Secret `TMDB_TOKEN` tetap digunakan. Jalankan Actions > Build FilmStream V2 APK > Run workflow. Unduh artifact `FilmStream-V2-APK` dan ekstrak `app-release.apk`.

Apabila hanya mengganti `main.dart` dan mempertahankan workflow v1, build v1 masih bisa digunakan, hasil APK akan mempunyai antarmuka v2 karena main.dart-nya baru.

CATATAN: ini source code untuk build via GitHub Actions, bukan APK yang sudah dikompilasi. Token yang disematkan via dart-define ke APK bukan rahasia kuat, jangan distribusikan secara publik. Jika pernah terlihat di screenshot, putar kembali kredensial di TMDB.
