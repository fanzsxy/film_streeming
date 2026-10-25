# Local browser metadata collector

This option runs **on your own PC** and extracts the visible film cards per catalog page, rather than clicking individual films. It saves titles, years, and the linked detail-page URLs only. It is separate from the GitHub Actions crawler, which received HTTP 403.

## Two setup commands

```bash
pip install playwright beautifulsoup4
python -m playwright install chromium
```

Then run `python crawler/browser_catalog.py --pages 20 --delay 3` from the repo root. A visible Chromium window opens. Results go to `crawler/data/browser_catalog.csv` and `crawler/data/browser_catalog.json`; progress to `crawler/data/browser_state.json`. Run the same command again to resume.

**Limitations:** This is not tested against LK21's live DOM. Pagination is followed only if a next-page link is explicitly exposed. It does not alter browser fingerprints, rotate proxies, defeat CAPTCHA, or retry when blocked. Only run against pages where automated extraction is allowed by the site's terms/access rules. Stop if access is refused. The repository workflow is not changed by this script. Movie titles may need manual audit for correct year and URL. No player or video content is collected.
