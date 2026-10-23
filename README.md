# FilmStream V5 + LK21 public metadata module

Based on the supplied FilmStream V5 source. The new backend module adds `/lk21/latest` and `/lk21/detail?path=/...` to inspect **public metadata only** from the user-supplied domain `tv12.lk21official.cc`, with domain validation, robots.txt checks, timeouts and no following redirects. This is not a stream extractor or playback API.

## Files changed
- `backend/lk21_scraper.py`: new public-page metadata reader
- `backend/main.py`: two optional LK21 research endpoints; existing `/resolve` untouched
- `backend/requirements.txt`: requests + BeautifulSoup dependencies
- All Flutter files and Android workflow from V5 are included unchanged; preserve your permanent Android/Gradle directory when applying.

## Run locally
```bash
cd backend
python -m pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```
Inspect `http://127.0.0.1:8000/docs` and `/health`. `/lk21/latest` depends on the current page's HTML and may return an empty list if markup changes, robots disallows access, or the site blocks automated access. `/lk21/detail?path=/mufasa-the-lion-king-2024` returns public metadata where permitted.

`/resolve` still reads `sources.json`, and will return `available:false` until it contains matching authorized MP4/HLS entries. Scraped metadata is NOT automatically inserted as playable media. To use on Android, deploy the backend through HTTPS and set `SOURCE_API_BASE` as documented in V5. Do not set it to the LK21 website URL.

This package has passed Python syntax checks, but live extraction and Flutter APK compilation have not been verified. Respect the site's access rules and content rights.
