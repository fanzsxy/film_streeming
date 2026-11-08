"""Fill genre IDs and original language IN the existing FilmStream catalog.

Uses verified TMDB cache matches first, then queries known TMDB IDs in small
batches. No new metadata data file is produced. Unverified IDs or failures
remain missing (not an empty genre array).
"""
import argparse
import json
import os
import time
import difflib
import re
from urllib.parse import urlencode
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



def select_match(entry, results):
    wanted = re.sub(r"[^a-z0-9]+", " ", str(entry.get("title", "")).casefold()).strip()
    try:
        year = int(entry.get("year", 0))
    except (ValueError, TypeError):
        return None
    ranked = []
    for result in results:
        if not isinstance(result, dict):
            continue
        date = str(result.get("release_date") or result.get("first_air_date") or "")
        if not re.match(r"^\d{4}", date) or abs(int(date[:4]) - year) > 1:
            continue
        names = [result.get(k) for k in ("title", "original_title", "name", "original_name")]
        score = max((difflib.SequenceMatcher(
            None, wanted, re.sub(r"[^a-z0-9]+", " ", n.casefold()).strip()
        ).ratio() for n in names if isinstance(n, str) and n), default=0.0)
        if score >= 0.96:
            ranked.append((score, int(date[:4]) == year, result))
    ranked.sort(key=lambda x: (x[0], x[1]), reverse=True)
    if not ranked or (len(ranked) > 1 and ranked[0][0] - ranked[1][0] < 0.07):
        return None
    return ranked[0][2]


def fetch(endpoint, token, params=None):
    uri = "https://api.themoviedb.org/3/" + endpoint
    if params:
        uri += "?" + urlencode(params)
    request = Request(uri, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "User-Agent": "FilmStreamCatalogGenreSync/2.0",
    })
    with urlopen(request, timeout=25) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--delay", type=float, default=0.35)
    parser.add_argument("--github-output", default="")
    args = parser.parse_args()
    if not 0 <= args.limit <= 1000 or args.delay < 0.25:
        parser.error("limit must be between 0 and 1000; delay >= 0.25")
    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    cached = {}
    if CACHE.exists():
        for line in CACHE.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("match_status") == "matched" and type(record.get("tmdb_id")) is int:
                cached[(record.get("source_url"), record.get("tmdb_type"))] = record

    # Apply verified cache records without API calls.
    cache_hits = 0
    for item in items:
        if item.get("type") not in ("movie", "series"):
            continue
        media = "tv" if item["type"] == "series" else "movie"
        record = cached.get((item.get("url"), media))
        if not record or valid_genres(item.get("genre_ids")):
            continue
        known = item.get("tmdb_id")
        if known is not None and known != record["tmdb_id"]:
            continue
        item["tmdb_id"] = record["tmdb_id"]
        fill(item, record)
        if valid_genres(item.get("genre_ids")):
            cache_hits += 1
            item.pop("genre_sync_status", None)

    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        parser.error("TMDB_TOKEN secret missing")
    processed = 0
    filled = 0
    unavailable = 0
    paused = False
    for item in items:
        if processed >= args.limit:
            break
        if item.get("type") not in ("movie", "series"):
            continue
        if valid_genres(item.get("genre_ids")):
            continue
        if item.get("genre_sync_status") in ("unmatched", "no_genres", "invalid_year"):
            continue
        media = "tv" if item["type"] == "series" else "movie"
        known_id = item.get("tmdb_id")
        if type(known_id) is int and known_id > 0:
            endpoint = f"{media}/{known_id}"
            params = {"language": "en-US"}
        else:
            try:
                year = int(item.get("year", 0))
            except (TypeError, ValueError):
                year = 0
            if not 1900 <= year <= 2100:
                item["genre_sync_status"] = "invalid_year"
                unavailable += 1
                continue
            endpoint = f"search/{media}"
            params = {
                "query": str(item.get("title", "")),
                "language": "en-US", "include_adult": "false",
                ("year" if media == "movie" else "first_air_date_year"): str(year),
            }
        try:
            record = fetch(endpoint, token, params)
            time.sleep(args.delay)
            if endpoint.startswith("search/"):
                match = select_match(item, record.get("results", []))
                if match is None:
                    item["genre_sync_status"] = "unmatched"
                    unavailable += 1
                    processed += 1
                    continue
                item["tmdb_id"] = match["id"]
                record = match
            fill(item, record)
            if valid_genres(item.get("genre_ids")):
                item.pop("genre_sync_status", None)
                filled += 1
            else:
                item["genre_sync_status"] = "no_genres"
                unavailable += 1
            processed += 1
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            print(f"TMDB error for {item.get('title')!r}: {exc}", flush=True)
            paused = True
            break
        if processed % 100 == 0:
            print(f"Processed {processed} titles; verified genres for {filled}", flush=True)

    complete = sum(bool(valid_genres(x.get("genre_ids"))) for x in items)
    pending = sum(x.get("type") in ("movie", "series")
                  and not valid_genres(x.get("genre_ids"))
                  and x.get("genre_sync_status") not in
                      ("unmatched", "no_genres", "invalid_year") for x in items)
    tmp = CATALOG.with_suffix(".genres.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(CATALOG)
    print(f"Genre available: {complete}/{len(items)}")
    print(f"This batch: {processed} checked; {filled} new; {cache_hits} from cache; {unavailable} unresolved")
    print(f"Still eligible: {pending}; paused: {paused}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as report:
            report.write(f"pending={pending}\n")
            report.write(f"processed={processed}\n")
            report.write(f"paused={'true' if paused else 'false'}\n")


if __name__ == "__main__":
    main()
