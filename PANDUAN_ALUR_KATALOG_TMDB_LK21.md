# Alur CMD: katalog utama -> TMDB -> LK21 -> katalog utama

Jalankan `Jalankan_Cari_Judul_Hilang_LK21.bat` dari folder utama repository setelah scan TMDB 2015-2025 berhasil **lengkap**. Data TMDB yang sudah tersimpan dalam `crawler/data/lk21_year_tmdb_report.json` digunakan lagi tanpa jaringan TMDB.

1. Baca `assets/catalog/filmstream_catalog.json` lebih dahulu dan cek ulang seluruh kandidat TMDB terhadap judul+tahun, ID di katalog, dan ID di `assets/catalog/tmdb_cache.jsonl`. Judul dengan tahun tetangga yang meragukan tidak dikirim untuk pencarian otomatis. Antrian lokal di `crawler/data/lk21_missing_title_queue.json`.
2. Cari **hanya** kandidat yang belum dikenali melalui form pencarian publik LK21. Periksa halaman detail dan pastikan judul serta tahun cocok. Jangan menebak URL. Hasil `crawler/data/local_lk21_gap_candidates.json` memakai `title,year,url,type,poster_url,tmdb_id`. Setiap run maks. 100 judul, progres baru di `crawler/data/local_lk21_catalog_first_progress.json`. Status `not_found` hanyalah pencarian yang tidak menemukan hasil yang diakui parser, bukan bukti ketidaktersediaan di LK21. Jika akses dibatasi, berhenti.
3. Periksa kandidat yang benar-benar cocok sebelum memasukkannya. Perintah `py -3 -m tools.merge_verified_lk21` hanya preview; `py -3 -m tools.merge_verified_lk21 --apply` membuat backup katalog, menolak URL/ID/judul duplikat, lalu menambah kandidat yang lolos. Perintah penggabungan **tidak** mengunduh ulang halaman; hanya gunakan JSON hasil crawler tepercaya yang tidak dimodifikasi manual. Backup otomatis dalam folder katalog.

Alur ini tidak perlu mengulang pemindaian TMDB dan tidak lagi menggunakan penyisiran halaman per tahun. Pembatasan robots.txt dan akses LK21 tetap dihormati.


## Pencarian melalui browser lokal (Windows)

Batch `Jalankan_Cari_Judul_Hilang_LK21.bat` sekarang memasang Playwright dan Chromium bila belum tersedia, lalu membuka jendela Chromium **yang terlihat**. Pencarian LK21 dilakukan melalui browser tersebut, bukan `requests.Session` untuk membuka halaman pencarian. Halaman pencarian memakai form GET yang terdeteksi di browser, termasuk endpoint `/search?s=...` bila memang ditampilkan situs.

Data hasil tetap `crawler/data/local_lk21_gap_candidates.json`; checkpoint browser **baru** disimpan di `crawler/data/local_lk21_visible_browser_progress.json` sehingga status `not_found` dari crawler sebelumnya tidak otomatis dipercaya. Simpan screenshot atau log bila suatu film ada secara visual tetapi ditandai `search_no_match`. Status itu hanya kegagalan pencocokan parser, bukan bukti film tidak tersedia.

Browser dikendalikan oleh skrip untuk navigasi dan membaca HTML yang telah dirender. Ini **bukan browsing manual murni**, dan tidak akan melewati pembatasan robots.txt, captcha, HTTP 403 atau 429. Katalog utama hanya diperbarui setelah hasil diverifikasi dan perintah `py -3 -m tools.merge_verified_lk21 --apply` diberikan.
