@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FilmStream - Katalog ke TMDB ke LK21
if not exist "crawler\data\lk21_year_tmdb_report.json" (
 echo Laporan TMDB belum ditemukan.
 pause
 exit /b 1
)
echo [1/3] Cocokkan data katalog utama dengan TMDB yang sudah tersimpan...
py -3 -m tools.reconcile_tmdb_gaps
if errorlevel 1 goto fail
echo [2/3] Membuka Chromium lokal untuk mencari film yang belum ada...
py -3 -m pip install "playwright>=1.55,<2"
if errorlevel 1 goto fail
py -3 -m playwright install chromium
if errorlevel 1 goto fail
py -3 -m tools.local_lk21_browser_search --limit 100 --delay 3
if errorlevel 1 goto fail
echo [3/3] Preview kandidat yang bisa ditambahkan (tidak mengubah katalog)...
py -3 -m tools.merge_verified_lk21
if errorlevel 1 goto fail
echo.
echo Lihat crawler\data\local_lk21_gap_candidates.json
echo Jika sudah dicek, untuk memasukkan ke katalog jalankan:
echo py -3 -m tools.merge_verified_lk21 --apply
echo Jalankan ulang BAT untuk memproses 100 judul berikutnya.
echo Pencarian LK21 memakai browser Chromium yang terlihat, bukan request bot.
pause
exit /b 0
:fail
echo Proses gagal atau laporan belum lengkap. Katalog asli aman.
pause
exit /b 1
