@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FilmStream TMDB + LK21 Local CMD
if not exist "assets\catalog\filmstream_catalog.json" (
 echo Jalankan BAT dari folder utama film_streeming.
 pause
 exit /b 1
)
where py >nul 2>nul
if errorlevel 1 (
 echo Python 3 belum tersedia.
 pause
 exit /b 1
)
set "START_YEAR=2015"
set "END_YEAR=2025"
set /p "START_YEAR=Tahun awal [2015]: "
set /p "END_YEAR=Tahun akhir [2025]: "
if "%START_YEAR%"=="" set "START_YEAR=2015"
if "%END_YEAR%"=="" set "END_YEAR=2025"
set "MIN_RUNTIME=70"
set "MIN_RATING=5.0"
set "MIN_VOTES=10"
echo Filter default: durasi minimal 70 menit, rating minimal 5.0, dan minimal 10 suara.
if not defined TMDB_TOKEN (
 echo Masukkan TMDB API Read Access Token untuk sesi CMD ini.
 set /p "TMDB_TOKEN=TMDB_TOKEN: "
)
if not defined TMDB_TOKEN (
 echo Token kosong.
 pause
 exit /b 1
)
py -3 -m pip install -r crawler\requirements.txt
if errorlevel 1 goto failed
echo [1/2] TMDB %START_YEAR% sampai %END_YEAR% (resume per bulan)
py -3 -m tools.tmdb_full_gap_scan --start-year %START_YEAR% --end-year %END_YEAR% --delay 0.30 --min-runtime %MIN_RUNTIME% --min-rating %MIN_RATING% --min-votes %MIN_VOTES%
if errorlevel 1 goto failed
echo [2/2] LK21 local, metadata only
py -3 -m tools.local_lk21_gap_match --report crawler/data/lk21_year_tmdb_report.json --limit 100 --delay 3
if errorlevel 1 goto failed
echo Hasil: crawler\data\local_lk21_gap_candidates.json
echo Katalog lama tidak diubah otomatis.
pause
exit /b 0
:failed
echo Ada error. Checkpoint TMDB per bulan tetap tersimpan. Coba jalankan ulang.
pause
exit /b 1
