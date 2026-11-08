"""Audit actual genre coverage and recover ONLY entries with empty 'genres'.

This does not attempt to backfill TMDB IDs for items that already have genres.
Progress and results are stored in assets/catalog/filmstream_catalog.json only.
"""
import argparse
import json
import os
import time
from urllib.error import HTTPError, URLError

from retry_catalog_genres import CATALOG, genre_ids
from third_pass_catalog_genres import assess

FINAL = {"unmatched", "ambiguous", "no_genres", "invalid_year"}
MATCH_VERSION = "articles_v1"


def has_genres(item):
    value = item.get("genres")
    return isinstance(value, list) and any(
        isinstance(name, str) and bool(name.strip()) for name in value
    )


def counts(items):
    supported = [item for item in items if item.get("type") in ("movie", "series")]
    with_genres = sum(has_genres(item) for item in supported)
    with_ids = sum(bool(genre_ids(item.get("genre_ids"))) for item in supported)
    empty = [item for item in supported if not has_genres(item)]
    eligible = sum(not (item.get("genre_empty_status") in FINAL and item.get("genre_empty_method") == MATCH_VERSION) for item in empty)
    return len(supported), with_genres, with_ids, len(empty), eligible


def apply_only_if_empty(item, detail):
    # Do not overwrite genre names from the original source.
    if has_genres(item) or genre_ids(item.get("genre_ids")):
        return False
    raw = detail.get("genres")
    if not isinstance(raw, list) or not raw:
        return False
    ids = genre_ids(raw)
    if not ids or len(ids) != len(raw):
        return False
    names = [entry.get("name") if isinstance(entry, dict) else None for entry in raw]
    if not all(isinstance(name, str) and name.strip() for name in names):
        return False
    if type(detail.get("id")) is not int:
        return False
    item["genres"] = [name.strip() for name in names]
    item["genre_ids"] = ids
    item["tmdb_id"] = detail["id"]
    if isinstance(detail.get("original_language"), str) and not item.get("original_language"):
        item["original_language"] = detail["original_language"]
    item.pop("genre_empty_status", None)
    item.pop("genre_sync_status", None)
    item.pop("genre_retry_status", None)
    item.pop("genre_third_status", None)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0,
                        help="Maximum empty-genre entries to search (0 = report only)")
    parser.add_argument("--delay", type=float, default=0.35)
    parser.add_argument("--github-output", default="")
    args = parser.parse_args()
    if not 0 <= args.limit <= 1000 or args.delay < 0.3:
        parser.error("limit must be 0..1000 and delay >= 0.3")

    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        parser.error("TMDB_TOKEN is required when searching TMDB")

    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    before = counts(items)
    print("Catalog items:", len(items), flush=True)
    print(f"Genre audit before: supported={before[0]}; with_genres={before[1]}; "
          f"with_tmdb_ids={before[2]}; truly_empty={before[3]}; eligible={before[4]}", flush=True)

    attempted = recovered = unresolved = 0
    paused = False
    if args.limit:
        for item in items:
            if attempted >= args.limit:
                break
            if item.get("type") not in ("movie", "series"):
                continue
            if has_genres(item) or (item.get("genre_empty_status") in FINAL
                                     and item.get("genre_empty_method") == MATCH_VERSION):
                continue
            # Entries with genre IDs but no names should not be overwritten;
            # leave them for explicit metadata repair, not title re-matching.
            if genre_ids(item.get("genre_ids")):
                item["genre_empty_status"] = "ambiguous"
                item["genre_empty_method"] = MATCH_VERSION
                unresolved += 1
                attempted += 1
                continue
            media = "tv" if item["type"] == "series" else "movie"
            try:
                detail, status = assess(item, media, token, args.delay, article_mode=True)
                if detail and apply_only_if_empty(item, detail):
                    recovered += 1
                    if recovered <= 25:
                        print(f"Filled genre: {item.get('title')!r} ({item.get('year')}) -> TMDB {detail.get('id')}", flush=True)
                else:
                    item["genre_empty_status"] = status or "no_genres"
                    unresolved += 1
                    item["genre_empty_method"] = MATCH_VERSION
                    if attempted < 25:
                        print(f"Still empty: {item.get('title')!r} ({item.get('year')}), reason={status}", flush=True)
                attempted += 1
            except (HTTPError, URLError, TimeoutError, ValueError, KeyError) as exc:
                print(f"TMDB request interrupted near {item.get('title')!r}: {exc}", flush=True)
                paused = True
                break
            if attempted % 25 == 0:
                print(f"Empty-genre batch: attempted={attempted}; filled={recovered}", flush=True)

    after = counts(items)
    print(f"Genre audit after: supported={after[0]}; with_genres={after[1]}; "
          f"with_tmdb_ids={after[2]}; truly_empty={after[3]}; eligible={after[4]}", flush=True)
    print(f"Empty-genre batch: attempted={attempted}; filled={recovered}; "
          f"unresolved={unresolved}; paused={paused}", flush=True)
    if args.limit:
        # Single catalog file, unchanged order, two-space pretty-print.
        tmp = CATALOG.with_suffix(".empty.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(CATALOG)

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write(f"pending={after[4]}\n")
            output.write(f"attempted={attempted}\n")
            output.write(f"paused={str(paused).lower()}\n")
            output.write(f"empty={after[3]}\n")
            output.write(f"with_genres={after[1]}\n")


if __name__ == "__main__":
    main()
