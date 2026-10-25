# Public metadata-only LK21 crawler

Run manually with `python crawler/crawl.py --pages 10 --delay 3` or trigger the `Crawl LK21 public metadata` GitHub Action. Twice-weekly scheduled runs continue from the last successful page. Data stays in `crawler/data/catalog.json`; progress is `crawler/data/state.json`.

This tool stores **titles, years and source-page URLs only**. It does not fetch embedded players, video files, subtitles or protected media. It first checks robots.txt and stops when unavailable, disallowed, rate-limited, or blocked. It never bypasses a site restriction. The link/path selectors may need adjustment after examining accessible HTML; no successful source crawl is claimed until Actions confirms it.

The workflow commits progress into the repository. GitHub repository settings must permit Actions to write repository contents. For a large catalog use a database instead of Git-tracked JSON. Pagination path is provisional and must be validated against the real site's navigation.