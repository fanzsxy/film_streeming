# Jalankan TMDB + LK21 sepenuhnya lewat CMD Windows

1. Pastikan Python 3.12 terpasang.
2. Dari repository `film_streeming` terbaru (PR pembetulan TMDB cache #149 juga perlu digabung), jalankan `Jalankan_Scan_Dan_Crawler_Local.bat` dengan double click atau melalui CMD.
3. Masukkan rentang 2015 sampai 2025 (uji lebih cepat: 2025 sampai 2025). Ketik TMDB API Read Access Token saat diminta; jangan commit token.
4. Script mengambil judul TMDB per bulan, melakukan perbandingan dengan katalog dan menyimpan checkpoint di `crawler/data/tmdb_gap_progress/`. Jika terputus, jalankan kembali.
5. Setelah scan TMDB sukses, skrip membaca halaman LK21 yang diizinkan robots.txt dari PC lokal, mencocokkan judul dan tahun, lalu menulis `crawler/data/local_lk21_gap_candidates.json`. Katalog asli **tidak** diubah otomatis.

Peringatan: menjalankan lokal tidak menjamin LK21 mengizinkan akses; 403/429 atau robots restrictions tetap menghentikan crawling. 20 halaman per tahun adalah sampel halaman LK21, bukan seluruh situs. Total TMDB dapat sangat besar, sehingga full scan tetap akan memerlukan banyak permintaan dan waktu.

## Filter kualitas

Scan TMDB membatasi durasi minimal **70 menit**, rating TMDB **5.0/10** atau lebih tinggi, dan minimal **10 suara**. Film dengan informasi durasi kosong tidak dijamin masuk hasil. Batas ini bisa diubah melalui opsi `--min-runtime`, `--min-rating`, `--min-votes` saat menjalankan `python -m tools.tmdb_full_gap_scan` lewat CMD. Checkpoint dipisahkan menurut nilai filter supaya hasil scan lama tanpa filter tidak tercampur. Film yang belum populer/rating belum banyak dapat terlewat; daftar ini sengaja memprioritaskan film yang lebih dikenal, bukan inventaris lengkap semua film.
