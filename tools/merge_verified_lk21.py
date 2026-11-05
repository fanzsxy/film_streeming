"""Safely preview or import locally verified LK21 candidates into the FilmStream catalog.

Default is DRY RUN. --apply creates a timestamped backup and atomically writes
the existing document with nonduplicate new items appended.
"""
import argparse
import json
import os
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.tmdb_full_gap_scan import identity, known_tmdb_ids
from tools.auto_discover_lk21 import MOVIE_BASE

CATALOG = Path("assets/catalog/filmstream_catalog.json")
PROPOSALS = Path("crawler/data/local_lk21_gap_candidates.json")


def valid_candidate(row):
    if not isinstance(row, dict) or row.get("type") != "movie":
        return False
    if not isinstance(row.get("title"), str) or not row["title"].strip():
        return False
    if not isinstance(row.get("year"), int) or not 2015 <= row["year"] <= 2025:
        return False
    url = urlparse(str(row.get("url") or ""))
    expected = urlparse(MOVIE_BASE).hostname
    if (url.scheme != "https" or url.hostname != expected or url.port is not None
            or url.username or url.password or url.query or url.fragment):
        return False
    if not isinstance(row.get("tmdb_id"), int):
        return False
    poster = row.get("poster_url") or ""
    if not isinstance(poster, str):
        return False
    if poster:
        p = urlparse(poster)
        if p.scheme != "https" or not p.hostname or p.username or p.password:
            return False
    return True


def prepare(document, proposals, cache_path=None):
    items = document.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Existing catalog empty or invalid")
    rows = proposals.get("new")
    if proposals.get("applied") is not False or not isinstance(rows, list):
        raise ValueError("Expected crawler review proposals with applied=false")
    known = [x for x in items if isinstance(x, dict) and x.get("type") == "movie"]
    urls = {str(x.get("url", "")).rstrip("/") for x in known}
    names = {identity(x.get("title", ""), x.get("year", "")) for x in known}
    ids = known_tmdb_ids(known, cache_path) if cache_path is not None else known_tmdb_ids(known)
    planned, invalid, duplicates = [], 0, 0
    for source in rows:
        if not valid_candidate(source):
            invalid += 1
            continue
        url = source["url"].rstrip("/")
        name = identity(source["title"], source["year"])
        mid = source["tmdb_id"]
        if url in urls or name in names or mid in ids:
            duplicates += 1
            continue
        row = {"title": source["title"].strip(), "year": source["year"],
               "url": source["url"], "type": "movie",
               "tmdb_id": mid}
        if source.get("poster_url"):
            row["poster_url"] = source["poster_url"]
        planned.append(row)
        urls.add(url)
        names.add(name)
        ids.add(mid)
    return planned, {"new": len(planned), "duplicates": duplicates, "invalid": invalid}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--proposals", type=Path, default=PROPOSALS)
    p.add_argument("--apply", action="store_true", help="Backup and update main catalog")
    args = p.parse_args()
    raw = args.catalog.read_bytes()
    document = json.loads(raw.decode("utf-8-sig"))
    proposals = json.loads(args.proposals.read_text(encoding="utf-8-sig"))
    additions, stats = prepare(document, proposals)
    print("Merge preview:", stats, flush=True)
    if not args.apply:
        print("DRY RUN: katalog tidak berubah. Gunakan --apply setelah periksa hasil.", flush=True)
        return
    if not additions:
        print("Tidak ada film baru yang layak ditambahkan.", flush=True)
        return
    backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
                                    datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ".json")
    backup.write_bytes(raw)
    document["items"].extend(additions)
    temp = args.catalog.with_suffix(".local_merge.tmp")
    try:
        temp.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(temp, args.catalog)
    finally:
        if temp.exists():
            temp.unlink()
    print("Added", len(additions), "movies. Backup:", backup, flush=True)


if __name__ == "__main__":
    main()
