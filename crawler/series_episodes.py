"""Retired: episode detail crawling is no longer part of FilmStream's workflow.

Use crawler/series_category_metadata.py for series poster/rating/genre.
The Flutter detail screen fetches seasons and episodes from TMDB.
Existing crawler/data/detail_metadata.json is not changed by this script.
"""

if __name__ == "__main__":
    print("Episode detail crawler is retired. No requests made; no data changed.")
    print("Use: py crawler/series_category_metadata.py --year 2025 --pages 5 --delay 3")
    print("FilmStream already reads season/episode listings via TMDB in lib/main.dart.")
