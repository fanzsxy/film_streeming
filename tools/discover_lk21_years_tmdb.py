"""Discover missing FilmStream movies from TMDB first, then verify on LK21.

Metadata only. No video/player scraping, guessing source URLs, or access bypass.
"""
import argparse
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from urllib.robotparser import RobotFileParser

import requests
from tools.auto_discover_lk21 import MOVIE_BASE, UA, candidates
from tools.enrich_tmdb import tmdb_get

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
DENIAL = re.compile(r"captcha|verify you are human|access denied", re.I)


def identity(title, year):
    return (re.sub(r"[^a-z0-9]", "", str(title).casefold()), str(year))


def tmdb_titles(token, year, pages, delay):
    """Discover yearly titles using TMDB /discover/movie in descending popularity order."""
    found = {}
    for page in range(1, pages + 1):
        result = tmdb_get("discover/movie", {
            "primary_release_date.gte": f"{year}-01-01",
            "primary_release_date.lte": f"{year}-12-31",
            "sort_by": "popularity.desc",
            "include_adult": "false",
            "page": page,
            "language": "en-US",
        }, token)
        for movie in result.get("results", []):
            date = str(movie.get("release_date") or "")
            if not date.startswith(str(year)) or not isinstance(movie.get("id"), int):
                continue
            title = str(movie.get("title") or "").strip()
            if title:
                found[movie["id"]] = movie
        if page >= min(int(result.get("total_pages") or pages), 500):
            break
        time.sleep(delay)
    return list(found.values())


def missing_tmdb(movies, existing, year):
    """Exclude films already catalogued by TMDB ID or normalized title/year."""
    ids = {int(x["tmdb_id"]) for x in existing
           if x.get("type") == "movie" and str(x.get("tmdb_id") or "").isdigit()}
    titles = {identity(x.get("title", ""), x.get("year", "")) for x in existing
              if x.get("type") == "movie"}
    return [m for m in movies if m["id"] not in ids
            and identity(m.get("title", ""), year) not in titles
            and identity(m.get("original_title", ""), year) not in titles]


def lk21_year_entries(session, robot, year, pages, delay):
    """Index only visible year-card links on the allowed LK21 host."""
    rows, errors = {}, []
    for page in range(1, pages + 1):
        url = MOVIE_BASE + f"/year/{year}" + (f"/page/{page}" if page > 1 else "")
        if not robot.can_fetch(UA, url):
            errors.append("Disallowed by robots.txt: " + url)
            break
        try:
            response = session.get(url, timeout=20)
            if response.status_code in (401, 403, 429):
                errors.append(f"Access restricted HTTP {response.status_code}: {url}")
                break
            response.raise_for_status()
            if urlparse(response.url).hostname != urlparse(MOVIE_BASE).hostname:
                errors.append("Cross-host redirect: " + response.url)
                break
            if DENIAL.search(response.text):
                errors.append("Verification required: " + url)
                break
            entries = [e for e in candidates(response.text, MOVIE_BASE, "movie").values()
                       if e["year"] == year]
            if not entries:
                errors.append("No recognized cards: " + url)
                break
            rows.update({e["url"]: e for e in entries})
        except requests.RequestException as exc:
            errors.append(f"Unreachable {url}: {exc}")
            break
        if page < pages:
            time.sleep(delay)
    return list(rows.values()), errors


def confirmed_missing(missing, entries, year):
    """Exact normalized title or original title AND year; skip ambiguous matches."""
    index = {}
    for e in entries:
        index.setdefault(identity(e["title"], year), []).append(e)
    found, ambiguous = [], []
    used = set()
    for movie in missing:
        urls = {}
        for title in (movie.get("title"), movie.get("original_title")):
            for entry in index.get(identity(title, year), []):
                urls[entry["url"]] = entry
        if len(urls) == 1:
            entry = next(iter(urls.values()))
            if entry["url"] not in used:
                found.append({**entry, "tmdb_id": movie["id"], "tmdb_type": "movie"})
                used.add(entry["url"])
        elif len(urls) > 1:
            ambiguous.append({"tmdb_id": movie["id"], "title": movie.get("title"),
                              "possible_urls": list(urls)})
    return found, ambiguous


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-year", type=int, default=2015)
    parser.add_argument("--end-year", type=int, default=2025)
    parser.add_argument("--tmdb-pages-per-year", type=int, default=10)
    parser.add_argument("--lk21-pages-per-year", type=int, default=20)
    parser.add_argument("--tmdb-delay", type=float, default=0.3)
    parser.add_argument("--lk21-delay", type=float, default=2.0)
    args = parser.parse_args()
    if not (2015 <= args.start_year <= args.end_year <= 2025):
        parser.error("Years must be within 2015..2025")
    if not 1 <= args.tmdb_pages_per_year <= 500 or not 1 <= args.lk21_pages_per_year <= 100:
        parser.error("TMDB pages 1-500, LK21 pages 1-100")
    if args.tmdb_delay < .25 or args.lk21_delay < 2:
        parser.error("Minimum delays: TMDB .25 seconds, LK21 2 seconds")
    token = os.environ.get("TMDB_TOKEN", "").strip()
    if not token:
        parser.error("TMDB_TOKEN missing")
    document = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    existing = document.get("items")
    if not isinstance(existing, list) or not existing:
        raise SystemExit("Invalid/empty catalog; not modifying it")
    # TMDB analysis must be useful even if the external LK21 site is blocked.
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "years": [args.start_year, args.end_year], "by_year": {},
              "new": [], "new_count": 0, "errors": {},
              "lk21_status": "not_checked"}
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    robots = RobotFileParser()
    lk21_access = True
    try:
        response = session.get(MOVIE_BASE + "/robots.txt", timeout=15)
        response.raise_for_status()
        robots.parse(response.text.splitlines())
    except requests.RequestException as exc:
        lk21_access = False
        report["lk21_status"] = "blocked_or_unavailable"
        report["errors"]["lk21"] = (
            f"LK21 robots.txt unavailable: {exc}. No LK21 URLs will be guessed."
        )
    if lk21_access:
        report["lk21_status"] = "robots_available"

    proposals = []
    for year in range(args.end_year, args.start_year - 1, -1):
        try:
            tmdb = tmdb_titles(token, year, args.tmdb_pages_per_year, args.tmdb_delay)
        except Exception as exc:
            report["errors"][str(year)] = f"TMDB discovery failed: {exc}"
            break
        missing = missing_tmdb(tmdb, existing + proposals, year)
        # Store the missing titles regardless of LK21 access so the gap report
        # remains useful even when LK21 blocks the GitHub Actions runner.
        gaps = [
            {"tmdb_id": movie["id"], "title": movie.get("title"),
             "original_title": movie.get("original_title"),
             "release_date": movie.get("release_date")}
            for movie in missing
        ]
        lk21, errors = (lk21_year_entries(session, robots, year,
                         args.lk21_pages_per_year, args.lk21_delay)
                         if lk21_access else ([], ["LK21 robots.txt unavailable; verification skipped"]))
        confirmed, ambiguous = confirmed_missing(missing, lk21, year)
        proposals.extend(confirmed)
        report["by_year"][str(year)] = {
            "tmdb_found": len(tmdb), "not_in_catalog": len(missing),
            "missing_tmdb_titles": gaps,
            "lk21_observed": len(lk21), "confirmed_additions": len(confirmed),
            "ambiguous": ambiguous, "lk21_errors": errors,
        }
        print(f"{year}: TMDB {len(tmdb)}; missing {len(missing)}; "
              f"LK21 {len(lk21)}; verified {len(confirmed)}", flush=True)
    report["new"] = proposals
    report["new_count"] = len(proposals)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if any(key != "lk21" for key in report["errors"]):
        raise SystemExit("TMDB discovery incomplete; catalog unchanged. Download report.")
    if not lk21_access:
        print("TMDB-only gap report completed. LK21 returned access restriction; "
              "no film catalog additions. Download report artifact.", flush=True)
        return
    if not any(v["lk21_observed"] for v in report["by_year"].values()):
        print("No accessible LK21 year cards; TMDB gap report saved, catalog unchanged.")
        return
    if proposals:
        document["items"] = existing + proposals
        CATALOG.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Proposed {len(proposals)} TMDB-first, LK21-confirmed movies for review.")


if __name__ == "__main__":
    main()
