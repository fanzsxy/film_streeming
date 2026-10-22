# FilmStream Personal — GitHub Actions APK build

Unggah isi folder ini ke ROOT repository GitHub PRIVAT, termasuk folder tersembunyi `.github/workflows`.

1. Buat repository GitHub Private dengan nama misalnya `filmstream-personal`.
2. Upload isi paket (bukan direktori luarnya). GitHub browser upload mungkin menyulitkan folder tersembunyi `.github`: bila tidak ikut, buat file `.github/workflows/build-apk.yml` lewat GitHub web editor dan tempel isinya.
3. Dapatkan **TMDB API Read Access Token** di https://www.themoviedb.org/settings/api
4. GitHub repo → Settings → Secrets and variables → Actions → New repository secret. Name: `TMDB_TOKEN`; Secret: token Anda.
5. Actions → Build FilmStream APK → Run workflow → main → Run workflow.
6. Setelah status success, buka run yang sama, bagian Artifacts → unduh `FilmStream-Personal-APK`, ekstrak ZIP artifact, lalu instal `app-release.apk` di HP Android.

Workflow akan membuat folder proyek Android yang belum tersedia dalam source starter dan mengompilasi APK menggunakan Flutter stable. Ini belum diuji melalui runner GitHub di sesi ini, sehingga bila gagal, periksa log step yang berwarna merah. APK build template memakai konfigurasi signing default dari template Flutter (untuk sideload/pribadi saja); sebelum distribusi rilis resmi, siapkan keystore signing produksi yang dikelola sendiri.

Penting: TMDB_TOKEN di-inject saat compile dan bisa diekstrak dari APK. Repository private dan GitHub secret hanya melindungi token dalam repo/log, bukan di APK. Jangan sebarkan APK ke publik; untuk produksi gunakan backend proxy. Aplikasi berisi katalog TMDB, input URL video MP4/HLS yang berizin, subtitle SRT HTTPS, dan buka halaman sumber di browser, BUKAN auto scraping atau native player LK21.
