# Local series crawler

Collects series metadata from the public [latest series catalog](https://tv12.lk21official.cc/latest-series) in a visible Chromium browser. It only follows real same-host pagination links and stops on access limits.

Run from the repository root after installing the existing browser crawler dependencies:

```powershell
py crawler/browser_series.py --pages 20 --delay 3
```

Run the same command again to continue from the saved next-page URL. The site may show more total pages than can actually be reached through its pagination (for example, page 50). The collector does not bypass this restriction.

Separate series outputs:
- `crawler/data/browser_series.json`
- `crawler/data/browser_series.csv`
- `crawler/data/browser_series_state.json`

**Your movie files are untouched**: `browser_catalog.json`, `browser_catalog.csv` and `browser_state.json`.

Records have `type: "series"`, with title, release year and the linked detail URL. This is show-level metadata as linked by the index, **not a verified per-episode catalog**. Duplicate detail URLs are merged. Embedded video links, cookies and streams are not collected. If CSV is open in Excel, JSON and state remain saved; close Excel before running again to refresh the CSV.
