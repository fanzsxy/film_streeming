# Film Streaming

Aplikasi Film Streaming untuk **Android** dan **Windows**.

## ⬇️ Download aplikasi

| 📱 Android | 🖥️ Windows |
|:--|:--|
| **[Download APK Android (GitHub Release terbaru)](https://github.com/fanzsxy/film_streeming/releases/latest/download/Film-Streaming-Android.apk)** | **[Download Windows (lihat Installer / Portable di Releases)](https://github.com/fanzsxy/film_streeming/releases)** |
| File: `Film-Streaming-Android.apk` | File: `Film-Streaming-Setup.exe` atau `Film-Streaming-Windows.zip` |
| APK rilis ditandatangani | Installer/portable hanya dipublikasikan jika build Windows ditandatangani |

**[📦 Lihat semua versi GitHub Releases](https://github.com/fanzsxy/film_streeming/releases)**

**Status:** Repository belum memiliki Release yang diterbitkan. Tombol APK langsung akan aktif setelah Release pertama dibuat. Jika Windows belum memiliki sertifikat penandatanganan, file Windows belum tersedia di Releases.

### Alternatif: download build untuk pengujian

| Android | Windows |
|:--|:--|
| [Build Android di GitHub Actions](https://github.com/fanzsxy/film_streeming/actions/workflows/build-apk.yml) | [Build Windows di GitHub Actions](https://github.com/fanzsxy/film_streeming/actions/workflows/build-windows.yml) |

Buka **run yang berhasil → Artifacts**, unduh ZIP lalu ekstrak filenya. Artifacts tidak permanen, dan GitHub mungkin meminta login. Untuk Windows, `PERSONAL-UNSIGNED-Installer` **hanya untuk pengujian pribadi**, bukan rilis publik; jangan melewati peringatan keamanan. Periksa sumber build dan tanda tangan digital sebelum menginstal.

### Untuk pemilik repositori: menerbitkan Release

1. Jalankan **[Build FilmStream APK V5](https://github.com/fanzsxy/film_streeming/actions/workflows/build-apk.yml)** pada branch `main` hingga berhasil. Catat **run ID** dari URL hasil build.
2. Opsional, jalankan **[Build Film Streaming Windows Desktop](https://github.com/fanzsxy/film_streeming/actions/workflows/build-windows.yml)** pada commit `main` yang **sama**. Untuk memasukkan installer dan ZIP Windows ke Release publik, build harus menghasilkan artifact **`Film-Streaming-Windows-Installer`** (ditandatangani, bukan `PERSONAL-UNSIGNED-Installer`). Itu membutuhkan secret `WINDOWS_CODESIGN_PFX_BASE64` dan `WINDOWS_CODESIGN_PASSWORD` yang benar.
3. Buka **[Publish Film Streaming Release](https://github.com/fanzsxy/film_streeming/actions/workflows/publish-release.yml)** → **Run workflow** pada `main`. Isi `version` (contoh `v1.0.0`), `android_run_id`, dan `windows_run_id` jika ada build Windows yang ditandatangani. Tidak perlu mengisi Windows jika belum tersedia.
4. Workflow memeriksa bahwa build benar-benar berhasil dari `main`, memastikan kedua platform berasal dari commit yang sama, menyiapkan checksum SHA-256, dan membuat GitHub Release dengan file unduhan nyata. Gunakan **tag versi baru** untuk rilis berikutnya.

**Catatan keamanan:** Release adalah distribusi publik, sedangkan Windows installer unsigned memang belum ditujukan untuk publik. Untuk Windows publik yang lebih tepercaya, konfigurasi sertifikat penandatanganan terlebih dahulu. Jangan membagikan password maupun keystore/PFX di README atau chat.

---

<details>
<summary>Dokumentasi lama FilmStream V5 (arsip)</summary>

# FilmStream V5 – Focused Web Player

**Upload only these files to the existing repo, preserving paths:**
- `lib/main.dart` replaces existing file (based on All-Titles V4).
- `lib/web_source_page.dart` replaces existing file.
- `pubspec.yaml` has the same dependencies as the earlier WebView build (webview_flutter ^4.10.0 etc). If your existing pubspec already includes webview_flutter, it need not be replaced.

No backend changes. Existing `lib/source_manager.dart`, `android/` and GitHub workflow stay in place.

Build with existing GitHub Actions. Tap **Tonton di Web Player** on Mufasa. It loads its known exact film page, focuses the player visually, retains the original server picker, and provides toggle full page, refresh and external-browser fallback. Other films look for an exact archived `page_url` in Source Catalog; if absent they open the source site's regular search results with the film title. A search result still requires selection and does not imply playback. No invented slug or guessed embedded URL.

This is a visual focus mode on the original page, not stand-alone HYDRAX playback. An original page can change markup, refuse Android WebView, or deny playback. Toggle the full-page icon when the style hides something important. CSS style insertion doesn't spoof identities or alter the site's media requests.

Note: No Flutter SDK was available in the build environment here. Validate via your normal GitHub Actions run; share compiler logs if it fails.

</details>
