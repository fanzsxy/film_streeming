# FilmStream Player Parser — Four Server Update

Replace only `backend/player_parser.py` in your existing GitHub repository. Keep the current `backend/main.py` endpoint `/inspect/player-html` unchanged. Vercel redeploys after commit; no APK rebuild required.

The parser accepts supplied HTML only (no website fetch or protection bypass). It inspects iframe/video/source elements plus `#player-list a` and `#player-select option` elements. It deduplicates the default P2P iframe against the P2P entry and distinguishes unverified embed vs media candidates.

Test locally: `python tests/test_parser.py` (requires beautifulsoup4). The original uploaded movie-page HTML is intentionally not included in this upload; the updated parser was also tested against it and found P2P, CAST, HYDRAX, TURBOVIP (four embeds, no directly verified media).

In Vercel Swagger, use `POST /inspect/player-html` with JSON body `{ "html": "...", "page_url": "https://example.com/page" }`. Submit the actual HTML through a local client rather than pasting large HTML by hand. Never treat an iframe as an MP4/HLS stream.


## Android WebView -> GitHub main catalog synchronization

The Android app scans *new* LK21 titles via its embedded WebView, then
stores title, year, movie/series, source URL, source poster, and genre labels
in the local catalog overlay. It can also submit newly discovered metadata to
the **FilmStream backend** at `POST /catalog/submit`.

**Do not put a GitHub token in the APK or a Dart source file.**
The GitHub credential belongs only in server-side Vercel environment variables:

- `FILMSTREAM_GITHUB_TOKEN`: fine-grained GitHub credential restricted to
  `fanzsxy/film_streeming`, with **Contents (read/write)** and
  **Pull requests (read/write)**. Keep it out of logs and version control.
- `FILMSTREAM_SYNC_KEY`: server-side API submission key; set the same value
  as a **GitHub Actions repository secret** named `FILMSTREAM_SYNC_KEY`.
  The existing `.github/workflows/build-apk.yml` passes that value to Flutter
  via `--dart-define` at build time. **Rebuild the APK after changing it.**
  This app-embedded key is extractable, so it is *not* a GitHub credential or
  strong proof of identity. Keep the PR review gate on the server.
- Redeploy the backend after changing Vercel environment variables or
  `backend/phone_catalog_sync.py`.

### Review workflow

1. Open the newly built Android app. Its WebView reads new movie/series
   listing cards and genre tags; it stores additions immediately on-device.
2. If the backend is configured and online, the app sends the queued additions
   to `/catalog/submit`. The server validates source URLs and genre labels
   and checks the **main catalog and open submissions** for duplicates.
3. A GitHub PR named `Review N scanned FilmStream catalog titles` is
   created on an `automation/phone-catalog-*` branch. Review and **merge**
   that PR. It contains a `crawler/imports/phone_*.json` file, not a direct
   modification of the main catalog. The app logs the PR URL.
4. Merging the review PR triggers the existing workflow
   **Unify FilmStream crawler catalog**, which automatically imports new
   titles and source genres, then opens a **second catalog PR**.
5. Review and merge that catalog PR; this updates
   `assets/catalog/filmstream_catalog.json` on main. Devices can later
   download reviewed additions via the app's GitHub catalog sync.

If the server responds `already_known`, the app clears that submission from
its retry queue. On HTTP failures, it **retains the local data and queue** for
a future launch. Incoming metadata is never automatically merged to main
without a reviewed PR.

### Troubleshooting

- `Sinkronisasi tidak aktif`: the APK did not receive `FILMSTREAM_SYNC_KEY`.
- HTTP 401: backend key mismatch. Recheck Vercel and GitHub Actions secrets.
- HTTP 503: backend token/key missing or GitHub upstream unavailable.
- No GitHub PR yet: check backend logs and Android local sync status. A source
  page denial prevents new WebView records; it is not a GitHub sync issue.
- The backend only forwards **genre labels verified by the scanner**.
  Existing blank-genre records are not modified.
