"""Catalog-first reconciliation of an already downloaded TMDB year inventory.

Never calls TMDB/LK21. Rechecks every old 'missing' against the CURRENT catalog,
cache IDs and year-adjacent aliases before making a queue for LK21 title searches.
"""
import argparse
import json
from pathlib import Path

from tools.tmdb_full_gap_scan import identity, known_tmdb_ids

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
QUEUE = Path("crawler/data/lk21_missing_title_queue.json")


def normalized_names(movie, year):
    return {identity(movie.get(field, ""), year)[0] for field in ("title", "original_title")
            if movie.get(field) and identity(movie.get(field, ""), year)[0]}


def reconcile(report, catalog, cache_path=None):
    if not report.get("complete") or not isinstance(report.get("by_year"), dict):
        raise ValueError("TMDB inventory incomplete; finish scan before searching LK21.")
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Main catalog missing/empty")
    movies = [x for x in items if isinstance(x, dict) and x.get("type") == "movie"]
    ids = known_tmdb_ids(movies, cache_path) if cache_path is not None else known_tmdb_ids(movies)
    titles = {}
    for item in movies:
        key = identity(item.get("title", ""), item.get("year", ""))
        if key[0]:
            titles.setdefault(key[0], set()).add(str(item.get("year", "")))
    queue, stats = [], {"already_in_catalog": 0, "possible_alias": 0, "to_search": 0}
    seen_ids = set()
    for year in sorted(report["by_year"], reverse=True):
        data = report["by_year"][year]
        if not data.get("tmdb_complete"):
            raise ValueError(f"TMDB year {year} incomplete")
        for movie in data.get("missing_tmdb_titles", []):
            if not isinstance(movie, dict) or not isinstance(movie.get("tmdb_id"), int):
                continue
            tmdb_id = movie["tmdb_id"]
            if tmdb_id in seen_ids:
                continue
            seen_ids.add(tmdb_id)
            names = normalized_names(movie, year)
            if tmdb_id in ids or any(year in titles.get(name, ()) for name in names):
                stats["already_in_catalog"] += 1
                continue
            if any(str(int(year) + shift) in titles.get(name, ())
                   for name in names for shift in (-1, 1)):
                stats["possible_alias"] += 1
                continue
            queue.append({"tmdb_id": tmdb_id, "year": int(year),
                          "title": movie.get("title") or "",
                          "original_title": movie.get("original_title") or ""})
            stats["to_search"] += 1
    return {"catalog_first": True, "years": report.get("years"),
            "stats": stats, "items": queue}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--output", type=Path, default=QUEUE)
    args = p.parse_args()
    result = reconcile(json.loads(args.report.read_text(encoding="utf-8-sig")),
                       json.loads(args.catalog.read_text(encoding="utf-8-sig")))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Current catalog reconciled against stored TMDB inventory:", result["stats"], flush=True)
    print("Only missing titles queued for LK21:", len(result["items"]), flush=True)


if __name__ == "__main__":
    main()
