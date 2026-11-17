# FilmStream Player Parser — Four Server Update

Replace only `backend/player_parser.py` in your existing GitHub repository. Keep the current `backend/main.py` endpoint `/inspect/player-html` unchanged. Vercel redeploys after commit; no APK rebuild required.

The parser accepts supplied HTML only (no website fetch or protection bypass). It inspects iframe/video/source elements plus `#player-list a` and `#player-select option` elements. It deduplicates the default P2P iframe against the P2P entry and distinguishes unverified embed vs media candidates.

Test locally: `python tests/test_parser.py` (requires beautifulsoup4). The original uploaded movie-page HTML is intentionally not included in this upload; the updated parser was also tested against it and found P2P, CAST, HYDRAX, TURBOVIP (four embeds, no directly verified media).

In Vercel Swagger, use `POST /inspect/player-html` with JSON body `{ "html": "...", "page_url": "https://example.com/page" }`. Submit the actual HTML through a local client rather than pasting large HTML by hand. Never treat an iframe as an MP4/HLS stream.


## Android WebView -> GitHub catalog security (November 2026)

The app continues to scan source metadata into its **local** catalog, retain
unsent entries in `filmstream_auto_sync_pending_v1`, and download changes that
were reviewed and merged into GitHub. **Automatic uploads from APK/EXE builds
are paused**: there is no secure way to authenticate the owner with one shared
secret compiled into every install. The status dialog reports this pause, and
pending entries are not discarded or falsely marked as sent.

### Server-only administrative catalog submission

`POST /catalog/submit` still accepts reviewed metadata for manual, owner-run
submissions. It can open an **import review PR** using GitHub credentials that
stay on the server. The route is **disabled by default** and needs all three
server-side environment variables:

- `FILMSTREAM_SYNC_ENABLED=1` — explicit opt-in for authorized admin submissions.
- `FILMSTREAM_SYNC_KEY` — a **new**, randomly generated admin secret. Do not
  reuse a value that was ever embedded in an APK/EXE.
- `FILMSTREAM_GITHUB_TOKEN` — fine-grained token restricted to this repository,
  with Contents (read/write) and Pull requests (read/write) permissions.

Only send requests from a trusted, owner-controlled script/computer over HTTPS.
Keep the secret out of logs, command history, Flutter apps, GitHub Action
build arguments, and public repositories. Existing installed APKs could still
know the **old** shared secret: rotate/revoke that value on the backend and
redeploy before enabling administrative submissions. If admin submissions
are not needed, leave `FILMSTREAM_SYNC_ENABLED` unset.

The import workflow remains review-only: an authenticated submission creates a
PR containing `crawler/imports/phone_*.json`; merging that PR invokes the
catalog unification workflow, which creates a separate catalog review PR.
Only after review/merge do applications obtain the catalog update.

### User impact and recovery

- Android scanning, local data, Film/Series/Filter/Search, and remote **read**
  synchronization remain available.
- Automatic upload and automatic creation of scanner PRs are temporarily
  unavailable on new builds. The saved pending entries remain on-device.
- This change does **not** erase local data or mark pending entries as sent.
- Enabling secure automatic uploads later requires separate owner
  authentication (for example a verified GitHub login with narrowly scoped
  permissions). A new shared API key or a secret fetched without identity
  verification would **not** solve the vulnerability.
- To submit metadata now, an owner may prepare a reviewed JSON payload and
  submit it from a trusted environment using the server-only secret; the
  application does not yet expose a UI to export its pending queue.

### Regression checks

Run `python -m unittest discover -s tests -p 'test_phone_catalog_submission_dedup.py' -v`
and `python -m unittest discover -s tests -p 'test_sync_secret_build_config.py' -v`.
