# FilmStream V5 – Focused Web Player

**Upload only these files to the existing repo, preserving paths:**
- `lib/main.dart` replaces existing file (based on All-Titles V4).
- `lib/web_source_page.dart` replaces existing file.
- `pubspec.yaml` has the same dependencies as the earlier WebView build (webview_flutter ^4.10.0 etc). If your existing pubspec already includes webview_flutter, it need not be replaced.

No backend changes. Existing `lib/source_manager.dart`, `android/` and GitHub workflow stay in place.

Build with existing GitHub Actions. Tap **Tonton di Web Player** on Mufasa. It loads its known exact film page, focuses the player visually, retains the original server picker, and provides toggle full page, refresh and external-browser fallback. Other films look for an exact archived `page_url` in Source Catalog; if absent they open the source site's regular search results with the film title. A search result still requires selection and does not imply playback. No invented slug or guessed embedded URL.

This is a visual focus mode on the original page, not stand-alone HYDRAX playback. An original page can change markup, refuse Android WebView, or deny playback. Toggle the full-page icon when the style hides something important. CSS style insertion doesn't spoof identities or alter the site's media requests.

Note: No Flutter SDK was available in the build environment here. Validate via your normal GitHub Actions run; share compiler logs if it fails.
