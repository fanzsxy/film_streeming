# FilmStream Player Parser — Four Server Update

Replace only `backend/player_parser.py` in your existing GitHub repository. Keep the current `backend/main.py` endpoint `/inspect/player-html` unchanged. Vercel redeploys after commit; no APK rebuild required.

The parser accepts supplied HTML only (no website fetch or protection bypass). It inspects iframe/video/source elements plus `#player-list a` and `#player-select option` elements. It deduplicates the default P2P iframe against the P2P entry and distinguishes unverified embed vs media candidates.

Test locally: `python tests/test_parser.py` (requires beautifulsoup4). The original uploaded movie-page HTML is intentionally not included in this upload; the updated parser was also tested against it and found P2P, CAST, HYDRAX, TURBOVIP (four embeds, no directly verified media).

In Vercel Swagger, use `POST /inspect/player-html` with JSON body `{ "html": "...", "page_url": "https://example.com/page" }`. Submit the actual HTML through a local client rather than pasting large HTML by hand. Never treat an iframe as an MP4/HLS stream.
