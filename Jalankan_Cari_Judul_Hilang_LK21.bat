@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FilmStream - Cari Semua Sisa Film Tahun 2025
if not exist "crawler\data\lk21_year_tmdb_report.json" (
 echo Laporan TMDB belum ditemukan.
 pause
 exit /b 1
)
echo [1/3] Cocokkan data katalog utama dengan TMDB yang sudah tersimpan...
py -3 -m tools.reconcile_tmdb_gaps
if errorlevel 1 goto fail
echo [2/3] Membuka Chromium lokal untuk mencari film yang belum ada...
py -3 -c "import playwright" >nul 2>nul
if errorlevel 1 (
 echo Playwright belum tersedia, memasang sekali...
 py -3 -m pip install "playwright>=1.55,<2"
 if errorlevel 1 goto fail
)
py -3 -m playwright install chromium
if errorlevel 1 goto fail
echo Mencari SEMUA sisa kandidat tahun 2025, tidak berhenti setelah 100 judul.
py -3 -m tools.local_lk21_browser_search --year 2025 --limit 0 --delay 2
if errorlevel 1 goto fail
echo [3/3] Preview kandidat yang bisa ditambahkan (tidak mengubah katalog)...
py -3 -m tools.merge_verified_lk21
if errorlevel 1 goto fail
echo.
echo Lihat crawler\data\local_lk21_gap_candidates.json
echo Jika sudah dicek, untuk memasukkan ke katalog jalankan:
echo py -3 -m tools.merge_verified_lk21 --apply
echo Jika terputus, jalankan ulang BAT yang sama untuk melanjutkan checkpoint.
echo Tahun 2024-2015 tidak diproses dalam mode ini.
echo Pencarian LK21 memakai browser Chromium yang terlihat, bukan request bot.
pause
exit /b 0
:fail
echo Proses gagal atau laporan belum lengkap. Katalog asli aman.
pause
exit /b 1
