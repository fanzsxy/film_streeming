"""TMDB-first comprehensive 2015-2025 inventory, used by the local LK21 crawler.
Scan by month, recursively divide windows exceeding TMDB's 500-page cap.
Save per-month checkpoints; never claim completion on partial data.
"""
import argparse
import calendar
import json
import os
import re
import unicodedata
import time
from datetime import date, timedelta, datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
PROGRESS = Path("crawler/data/tmdb_gap_progress")
TMDB_CACHE = Path("assets/catalog/tmdb_cache.jsonl")


def tmdb_get(endpoint, params, credential):
    """Accept v3 API keys and v4 read-access tokens without logging secrets."""
    key = credential.strip()
    is_v3 = bool(re.fullmatch(r"[a-fA-F0-9]{32}", key))
    query = dict(params)
    headers = {"Accept": "application/json", "User-Agent": "FilmStreamLocal/1.0"}
    if is_v3:
        query["api_key"] = key
    else:
        headers["Authorization"] = "Bearer " + key
    url = "https://api.themoviedb.org/3/" + endpoint + "?" + urlencode(query)
    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=25) as response:
            return json.load(response)
    except HTTPError as exc:
        # Do not leak the v3 query-string API key through urllib's exception URL.
        if exc.code == 401:
            raise RuntimeError("TMDB menolak kredensial (401). Periksa API key v3 atau Read Access Token v4.") from None
        raise RuntimeError(f"TMDB HTTP {exc.code} pada {endpoint}; coba lagi nanti.") from None
    except URLError as exc:
        raise RuntimeError(f"Koneksi ke TMDB gagal: {exc.reason}") from None


def check_tmdb_auth(credential):
    """Fail once before running all 11 years if credentials are invalid."""
    tmdb_get("configuration", {}, credential)
    print("Autentikasi TMDB berhasil.", flush=True)


def identity(title, year):
    plain = unicodedata.normalize("NFKD", str(title).casefold())
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    return (re.sub(r"[^a-z0-9]", "", plain), str(year))


def known_tmdb_ids(items, cache_path=TMDB_CACHE):
    """Use existing catalog identities AND matched TMDB cache records by source URL."""
    urls = {str(x.get("url", "")).rstrip("/") for x in items
            if isinstance(x, dict) and x.get("type") == "movie"}
    ids = {int(x["tmdb_id"]) for x in items if isinstance(x, dict)
           and x.get("type") == "movie" and str(x.get("tmdb_id") or "").isdigit()}
    if cache_path.is_file():
        for line in cache_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (row.get("tmdb_type") == "movie" and row.get("match_status") == "matched"
                    and str(row.get("source_url", "")).rstrip("/") in urls
                    and str(row.get("tmdb_id") or "").isdigit()):
                ids.add(int(row["tmdb_id"]))
    return ids


def classify_movies(movies, items, year, cache_path=TMDB_CACHE):
    """Separate confirmed missing candidates from possible catalog aliases."""
    known_ids = known_tmdb_ids(items, cache_path)
    titles = set()
    nearby = set()
    for x in items:
        if not isinstance(x, dict) or x.get("type") != "movie":
            continue
        iy = str(x.get("year", ""))
        base = identity(x.get("title", ""), iy)[0]
        if base:
            titles.add((base, iy))
            if iy.isdigit():
                nearby.update((base, str(int(iy) + shift)) for shift in (-1, 1))
    missing, probable, existing = [], [], []
    for m in movies:
        names = [identity(m.get(k, ""), year) for k in ("title", "original_title")]
        record = {"tmdb_id": m["id"], "title": m.get("title"),
                  "original_title": m.get("original_title"),
                  "release_date": m.get("release_date")}
        if m["id"] in known_ids or any(n[0] and n in titles for n in names):
            existing.append(record)
        elif any(n[0] and n in nearby for n in names):
            probable.append({**record, "reason": "same title, adjacent catalog year"})
        else:
            missing.append(record)
    return missing, probable, existing


def missing_movies(movies, items, year):
    """Backward-compatible missing-only interface."""
    return classify_movies(movies, items, year)[0]


def months(year):
    for month in range(1, 13):
        yield date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def discover_window(start, end, token, delay, stats, filters=None):
    params = {"primary_release_date.gte": start.isoformat(),
              "primary_release_date.lte": end.isoformat(),
              "sort_by": "popularity.desc", "include_adult": "false",
              "language": "en-US"}
    params.update(filters or {})
    first = tmdb_get("discover/movie", {**params, "page": 1}, token)
    stats["requests"] += 1
    pages = int(first.get("total_pages") or 0)
    if pages > 500:
        if start == end:
            raise RuntimeError(f"TMDB >500 pages for day {start}: incomplete inventory")
        middle = start + timedelta(days=(end - start).days // 2)
        time.sleep(delay)
        left = discover_window(start, middle, token, delay, stats, filters)
        time.sleep(delay)
        right = discover_window(middle + timedelta(days=1), end, token, delay, stats, filters)
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


def discover_year(year, token, delay, filters=None):
    filters = filters or {}
    # Filter-specific checkpoints prevent reusing the previous unfiltered scan.
    tag = f"r{filters.get('with_runtime.gte', 'all')}_a{str(filters.get('vote_average.gte', 'all')).replace('.', 'p')}_v{filters.get('vote_count.gte', 'all')}"
    path = PROGRESS / f"{year}_{tag}.json"
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
            found = discover_window(start, end, token, delay, stats, filters)
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
    parser.add_argument("--min-runtime", type=int, default=70, help="Minimum runtime in minutes")
    parser.add_argument("--min-rating", type=float, default=5.0, help="Minimum TMDB vote average")
    parser.add_argument("--min-votes", type=int, default=10, help="Minimum number of TMDB votes")
    args = parser.parse_args()
    if not 2015 <= args.start_year <= args.end_year <= 2025 or args.delay < 0.25:
        parser.error("Use 2015..2025 and delay >= 0.25")
    if not (0 <= args.min_runtime <= 600 and 0 <= args.min_rating <= 10 and args.min_votes >= 0):
        parser.error("Filter out of range: runtime 0..600, rating 0..10, votes >= 0")
    filters = {"with_runtime.gte": str(args.min_runtime),
               "vote_average.gte": str(args.min_rating),
               "vote_count.gte": str(args.min_votes)}
    token = os.getenv("TMDB_TOKEN", "").strip()
    if not token:
        parser.error("TMDB_TOKEN is missing")
    try:
        check_tmdb_auth(token)
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from None
    catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("Catalog is invalid or empty")
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "years": [args.start_year, args.end_year], "source": "tmdb_monthly_discover",
              "by_year": {}, "new": [], "new_count": 0, "errors": {},
              "tmdb_filters": {"min_runtime_minutes": args.min_runtime,
                               "min_rating": args.min_rating, "min_votes": args.min_votes},
              "lk21_status": "local_only", "complete": False}
    for year in range(args.end_year, args.start_year - 1, -1):
        movies, complete, errors = discover_year(year, token, args.delay, filters)
        gaps, probable, existing_matches = classify_movies(movies, items, year)
        report["by_year"][str(year)] = {
            "tmdb_found": len(movies), "not_in_catalog": len(gaps),
            "missing_tmdb_titles": gaps, "tmdb_complete": complete,
            "already_in_catalog": len(existing_matches),
            "possible_catalog_aliases": probable,
            "possible_catalog_aliases_count": len(probable),
            "tmdb_errors": errors, "lk21_observed": 0,
            "confirmed_additions": 0, "lk21_errors": ["LK21 crawling is local-only"]}
        if not complete:
            report["errors"][str(year)] = errors or {"coverage": "Partial"}
        report["complete"] = not report["errors"] and len(report["by_year"]) == (
            args.end_year - args.start_year + 1)
        save(REPORT, report)
        print(f"{year}: TMDB={len(movies)} already={len(existing_matches)} aliases={len(probable)} missing_candidates={len(gaps)} complete={complete}", flush=True)
    if not report["complete"]:
        raise SystemExit("Partial TMDB scan: use artifacts/checkpoints to resume")
    print("TMDB gap inventory done. Download report and run LK21 verification locally.")


if __name__ == "__main__":
    main()
