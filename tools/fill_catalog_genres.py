"""Fill genre IDs and original language IN the existing FilmStream catalog.

Uses verified TMDB cache matches first, then queries known TMDB IDs in small
batches. No new metadata data file is produced. Unverified IDs or failures
remain missing (not an empty genre array).
"""
import argparse
import json
import os
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CATALOG = Path("assets/catalog/filmstream_catalog.json")
CACHE = Path("assets/catalog/tmdb_cache.jsonl")


def valid_genres(value):
    if not isinstance(value, list) or not value:
        return None
    # TMDB search/cache uses numeric IDs, but /movie/{id} and /tv/{id}
    # detail endpoints return [{"id": 28, "name": "Action"}, ...].
    normalized = [x.get("id") if isinstance(x, dict) else x for x in value]
    if not all(type(x) is int and x > 0 for x in normalized):
        return None
    return list(dict.fromkeys(normalized))


# Official TMDB genre IDs (movie + TV), used to name cached genre_ids.
GENRE_NAMES = {
    28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
    80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
    14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
    9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
    10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    10759: "Action & Adventure", 10762: "Kids", 10763: "News",
    10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
    10767: "Talk", 10768: "War & Politics",
}


def genre_data(record):
    # TMDB detail JSON uses 'genres' objects, search/cache uses 'genre_ids'.
    raw = record.get("genres")
    ids = valid_genres(raw) if raw is not None else valid_genres(record.get("genre_ids"))
    if not ids:
        return None, None
    names = None
    if isinstance(raw, list) and all(
        isinstance(x, dict) and type(x.get("id")) is int
        and isinstance(x.get("name"), str) and x["name"].strip() for x in raw
    ):
        names = [x["name"].strip() for x in raw]
    elif all(x in GENRE_NAMES for x in ids):
        names = [GENRE_NAMES[x] for x in ids]
    return ids, names


def fill(entry, record):
    ids, names = genre_data(record)
    if ids:
        entry["genre_ids"] = ids
        # Replace sparse crawler labels only with verified, full TMDB genres.
        if names:
            entry["genres"] = names
    language = record.get("original_language")
    if isinstance(language, str) and language.strip() and not entry.get("original_language"):
        entry["original_language"] = language.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--delay", type=float, default=0.35)
    args = parser.parse_args()
    if args.limit < 0 or args.limit > 1000 or args.delay < 0.25:
        parser.error("Use 0 <= --limit <= 1000 and --delay >= 0.25")
    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    verified = {}
    if CACHE.exists():
        for line in CACHE.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("match_status") == "matched" and type(record.get("tmdb_id")) is int:
                verified[(record.get("source_url"), record.get("tmdb_type"), record.get("tmdb_id"))] = record

    for item in items:
        if item.get("type") not in ("series", "movie"):
            continue
        media = "tv" if item.get("type") == "series" else "movie"
        key = (item.get("url"), media, item.get("tmdb_id"))
        if key in verified:
            fill(item, verified[key])

    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        parser.error("TMDB_TOKEN secret is required for API requests")
    fetched = 0
    errors = 0
    for item in items:
        if fetched >= args.limit:
            break
        if item.get("type") not in ("series", "movie"):
            continue
        ids = valid_genres(item.get("genre_ids"))
        expected = [GENRE_NAMES.get(x) for x in ids] if ids else []
        if (ids and item.get("original_language") and
                expected and all(expected) and item.get("genres") == expected):
            continue
        tmdb_id = item.get("tmdb_id")
        if type(tmdb_id) is not int or tmdb_id <= 0:
            continue
        media = "tv" if item.get("type") == "series" else "movie"
        url = f"https://api.themoviedb.org/3/{media}/{tmdb_id}?language=en-US"
        request = Request(url, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/json",
            "User-Agent": "FilmStreamCatalogGenreSync/1.0",
        })
        try:
            with urlopen(request, timeout=20) as response:
                detail = json.load(response)
            fill(item, detail)
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            errors += 1
            print(f"Skipping {media}:{tmdb_id}: {exc}")
            if isinstance(exc, HTTPError) and exc.code == 429:
                print("Rate limited; stopping to avoid further requests")
                break
        fetched += 1
        time.sleep(args.delay)

    total = sum(bool(valid_genres(item.get("genre_ids"))) for item in items)
    # Atomic replace, preserving all other catalog entries and fields.
    tmp = CATALOG.with_suffix(".genres.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    tmp.replace(CATALOG)
    print(f"Genre available: {total}/{len(items)}; API requests: {fetched}; errors: {errors}")
    print("Entries without verified genre remain untouched; rerun to continue.")


if __name__ == "__main__":
    main()
