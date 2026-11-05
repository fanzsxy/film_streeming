"""TMDB-first comprehensive 2015-2025 inventory, used by the local LK21 crawler.
Scan by month, recursively divide windows exceeding TMDB's 500-page cap.
Save per-month checkpoints; never claim completion on partial data.
"""
import argparse
import calendar
import json
import os
import re
import time
from datetime import date, timedelta, datetime, timezone
from pathlib import Path
from tools.enrich_tmdb import tmdb_get

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
PROGRESS = Path("crawler/data/tmdb_gap_progress")


def identity(title, year):
    return (re.sub(r"[^a-z0-9]", "", str(title).casefold()), str(year))


def missing_movies(movies, items, year):
    known_ids = {int(x["tmdb_id"]) for x in items if isinstance(x, dict) and x.get("type") == "movie"
                 and str(x.get("tmdb_id") or "").isdigit()}
    known_titles = {identity(x.get("title", ""), x.get("year", "")) for x in items
                    if isinstance(x, dict) and x.get("type") == "movie"}
    return [{"tmdb_id": m["id"], "title": m.get("title"),
             "original_title": m.get("original_title"), "release_date": m.get("release_date")}
            for m in movies if m["id"] not in known_ids
            and identity(m.get("title", ""), year) not in known_titles
            and identity(m.get("original_title", ""), year) not in known_titles]


def months(year):
    for month in range(1, 13):
        yield date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def discover_window(start, end, token, delay, stats):
    params = {"primary_release_date.gte": start.isoformat(),
              "primary_release_date.lte": end.isoformat(),
              "sort_by": "popularity.desc", "include_adult": "false",
              "language": "en-US"}
    first = tmdb_get("discover/movie", {**params, "page": 1}, token)
    stats["requests"] += 1
    pages = int(first.get("total_pages") or 0)
    if pages > 500:
        if start == end:
            raise RuntimeError(f"TMDB >500 pages for day {start}: incomplete inventory")
        middle = start + timedelta(days=(end - start).days // 2)
        time.sleep(delay)
        left = discover_window(start, middle, token, delay, stats)
        time.sleep(delay)
        right = discover_window(middle + timedelta(days=1), end, token, delay, stats)
        left.update(right)
        return left
    movies = {}
    for page in range(1, pages + 1):
        if page == 1:
            result = first
        else:
            time.sleep(delay)
            result = tmdb_get("discover/movie", {**params, "page": page}, token)
            stats["requests"] += 1
        for movie in result.get("results", []):
            movie_id = movie.get("id")
            released = str(movie.get("release_date") or "")
            if not isinstance(movie_id, int) or not (movie.get("title") or movie.get("original_title")):
                continue
            if released and not start.isoformat() <= released <= end.isoformat():
                continue
            movies[movie_id] = movie
    return movies


def save(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def discover_year(year, token, delay):
    path = PROGRESS / f"{year}.json"
    progress = {"year": year, "completed_months": {}, "errors": {}}
    if path.exists():
        try:
            previous = json.loads(path.read_text(encoding="utf-8"))
            if previous.get("year") == year and isinstance(previous.get("completed_months"), dict):
                progress = previous
        except (OSError, ValueError):
            pass
    for start, end in months(year):
        key = start.strftime("%Y-%m")
        if key in progress["completed_months"]:
            continue
        try:
            stats = {"requests": 0}
            found = discover_window(start, end, token, delay, stats)
            progress["completed_months"][key] = list(found.values())
            progress["errors"].pop(key, None)
            save(path, progress)
            print(f"{key}: {len(found)} movies ({stats['requests']} requests)", flush=True)
            time.sleep(delay)
        except Exception as exc:
            progress["errors"][key] = str(exc)
            save(path, progress)
            print(f"{key}: error {exc}", flush=True)
            break
    by_id = {}
    for batch in progress["completed_months"].values():
        for m in batch:
            by_id[m["id"]] = m
    complete = len(progress["completed_months"]) == 12 and not progress["errors"]
    return list(by_id.values()), complete, progress["errors"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-year", type=int, default=2015)
    parser.add_argument("--end-year", type=int, default=2025)
    parser.add_argument("--delay", type=float, default=0.30)
    args = parser.parse_args()
    if not 2015 <= args.start_year <= args.end_year <= 2025 or args.delay < 0.25:
        parser.error("Use 2015..2025 and delay >= 0.25")
    token = os.getenv("TMDB_TOKEN", "").strip()
    if not token:
        parser.error("TMDB_TOKEN is missing")
    catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("Catalog is invalid or empty")
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "years": [args.start_year, args.end_year], "source": "tmdb_monthly_discover",
              "by_year": {}, "new": [], "new_count": 0, "errors": {},
              "lk21_status": "local_only", "complete": False}
    for year in range(args.end_year, args.start_year - 1, -1):
        movies, complete, errors = discover_year(year, token, args.delay)
        gaps = missing_movies(movies, items, year)
        report["by_year"][str(year)] = {
            "tmdb_found": len(movies), "not_in_catalog": len(gaps),
            "missing_tmdb_titles": gaps, "tmdb_complete": complete,
            "tmdb_errors": errors, "lk21_observed": 0,
            "confirmed_additions": 0, "lk21_errors": ["LK21 crawling is local-only"]}
        if not complete:
            report["errors"][str(year)] = errors or {"coverage": "Partial"}
        report["complete"] = not report["errors"] and len(report["by_year"]) == (
            args.end_year - args.start_year + 1)
        save(REPORT, report)
        print(f"{year}: TMDB={len(movies)} missing={len(gaps)} complete={complete}", flush=True)
    if not report["complete"]:
        raise SystemExit("Partial TMDB scan: use artifacts/checkpoints to resume")
    print("TMDB gap inventory done. Download report and run LK21 verification locally.")


if __name__ == "__main__":
    main()
