@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FilmStream - Cari Judul Hilang di LK21
if not exist "crawler\data\lk21_year_tmdb_report.json" (
 echo Laporan TMDB belum ditemukan di crawler\data\lk21_year_tmdb_report.json
 echo Jalankan scan TMDB sekali dulu.
 pause
 exit /b 1
)
py -3 -m pip install -r crawler\requirements.txt
if errorlevel 1 goto fail
echo Memeriksa judul TMDB yang belum ada dalam katalog langsung lewat pencarian LK21.
echo Data TMDB tidak akan discan ulang. Katalog asli tidak diubah.
py -3 -m tools.local_lk21_gap_match --limit 100 --delay 3
if errorlevel 1 goto fail
echo.
echo Hasil di crawler\data\local_lk21_gap_candidates.json
echo Ulangi BAT ini untuk melanjutkan 100 judul berikutnya.
pause
exit /b 0
:fail
echo Terjadi kesalahan. Progres sebelumnya tetap tersimpan.
pause
exit /b 1
