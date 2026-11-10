# Film Streaming

Aplikasi streaming untuk **Android** dan **Windows**. Unduh hasil build terbaru dari GitHub Actions:

| 📱 Android | 🖥️ Windows |
|:--|:--|
| **[⬇️ Download APK Android](https://github.com/fanzsxy/film_streeming/actions/workflows/build-apk.yml)** | **[⬇️ Download Windows (Installer / Portable)](https://github.com/fanzsxy/film_streeming/actions/workflows/build-windows.yml)** |
| File: `app-release.apk` | File: `Film-Streaming-Setup.exe` atau `Film-Streaming-Windows.zip` |

### Cara mengunduh

1. Klik **Download APK Android** atau **Download Windows** di atas.
2. Pilih **workflow run yang berhasil** (tanda centang hijau, bukan run yang gagal).
3. Gulir ke bagian **Artifacts** lalu pilih file yang sesuai:
   - **Android:** `Film-Streaming-Release-APK`. Unduh ZIP artifact GitHub, ekstrak, lalu instal `app-release.apk` di Android.
   - **Windows (installer):** `Film-Streaming-Windows-Installer` jika tersedia dan ditandatangani; atau `Film-Streaming-Windows-PERSONAL-UNSIGNED-Installer` **hanya untuk pengujian pribadi**. Ekstrak ZIP artifact, lalu jalankan `Film-Streaming-Setup.exe`.
   - **Windows (portable):** `Film-Streaming-Windows-Portable`. Ekstrak ZIP artifact, lalu ekstrak `Film-Streaming-Windows.zip` beserta semua file aplikasinya. Tersedia juga artifact `Film-Streaming-Windows-Checksums` untuk memeriksa SHA-256.

**Catatan:** Tautan di atas menuju halaman build, **bukan unduhan file langsung**. GitHub dapat meminta login untuk mengunduh Artifacts. File Artifacts punya masa simpan terbatas (installer Windows unsigned pribadi disimpan **3 hari**); jika tidak ada hasil build yang masih tersedia, buka workflow terkait dan gunakan **Run workflow** pada branch `main` untuk membuat versi baru. Installer Windows tanpa tanda tangan digital tidak untuk distribusi publik; jangan abaikan peringatan keamanan Windows.

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
