"""Run public LK21 year-listing matching locally against FilmStream TMDB gap report.

Only public metadata; respects robots.txt and stops on access denial.
Never downloads video or fabricates source URLs.
"""
import argparse
import json
import re
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.robotparser import RobotFileParser

import requests
from tools.auto_discover_lk21 import MOVIE_BASE, UA, candidates
from tools.discover_lk21_years_tmdb import confirmed_missing, identity

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
OUTPUT = Path("crawler/data/local_lk21_gap_candidates.json")
BLOCK = re.compile(r"captcha|verify you are human|access denied", re.I)


def save(data):
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def year_entries(session, robot, year, pages, delay):
    unique, errors = {}, []
    for page in range(1, pages + 1):
        url = MOVIE_BASE + f"/year/{year}" + (f"/page/{page}" if page > 1 else "")
        if not robot.can_fetch(UA, url):
            errors.append("Disallowed by robots.txt: " + url)
            break
        try:
            response = session.get(url, timeout=25)
            if response.status_code in (401, 403, 429):
                errors.append(f"Access restricted HTTP {response.status_code}: {url}")
                break
            response.raise_for_status()
            if urlparse(response.url).hostname != urlparse(MOVIE_BASE).hostname:
                errors.append("Cross-host redirect: " + response.url)
                break
            if BLOCK.search(response.text):
                errors.append("Verification page: " + url)
                break
        except requests.RequestException as exc:
            errors.append(f"Request failed: {exc}")
            break
        found = [e for e in candidates(response.text, MOVIE_BASE, "movie").values()
                 if e["year"] == year]
        if not found:
            errors.append("No recognizable cards: " + url)
            break
        unique.update({e["url"]: e for e in found})
        print(f"  page={page} observed={len(found)} unique={len(unique)}", flush=True)
        if page < pages:
            time.sleep(delay)
    return list(unique.values()), errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--pages-per-year", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3)
    args = parser.parse_args()
    if not 1 <= args.pages_per_year <= 100 or args.delay < 2:
        parser.error("pages must be 1..100, delay >= 2")
    report = json.loads(args.report.read_text(encoding="utf-8-sig"))
    years = report.get("by_year")
    if not isinstance(years, dict) or not years:
        raise SystemExit("TMDB gap report missing by_year")
    catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    existing = catalog.get("items")
    if not isinstance(existing, list) or not existing:
        raise SystemExit("Catalog missing or empty")
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    summary = {"new": [], "new_count": 0, "years": {}, "errors": [],
               "applied": False, "note": "Review only; catalog was not modified"}
    try:
        r = session.get(MOVIE_BASE + "/robots.txt", timeout=20)
        r.raise_for_status()
        if urlparse(r.url).hostname != urlparse(MOVIE_BASE).hostname:
            raise ValueError("robots.txt redirected to other host")
        robots = RobotFileParser()
        robots.parse(r.text.splitlines())
    except (requests.RequestException, ValueError) as exc:
        summary["errors"].append("LK21 access restricted; did not crawl: " + str(exc))
        save(summary)
        print("LK21 not accessible: report saved, catalog unchanged.")
        return
    found_all = []
    for year in sorted(years, reverse=True):
        if not year.isdigit() or not 2015 <= int(year) <= 2025:
            raise SystemExit("Invalid report year: " + year)
        missing = years[year].get("missing_tmdb_titles")
        if not isinstance(missing, list):
            raise SystemExit("Missing TMDB title data for " + year)
        print(f"{year}: checking {len(missing)} TMDB gaps", flush=True)
        entries, errors = year_entries(session, robots, int(year), args.pages_per_year, args.delay)
        eligible = [{"id": item["tmdb_id"], "title": item.get("title"),
                     "original_title": item.get("original_title")}
                    for item in missing if isinstance(item, dict) and isinstance(item.get("tmdb_id"), int)
                    and identity(item.get("title", ""), year) not in {
                        identity(e.get("title", ""), e.get("year", "")) for e in existing if e.get("type") == "movie"}]
        matched, ambiguous = confirmed_missing(eligible, entries, int(year))
        existing_urls = {str(e.get("url") or "").rstrip("/") for e in existing + found_all}
        matched = [m for m in matched if m["url"].rstrip("/") not in existing_urls]
        found_all.extend(matched)
        summary["years"][year] = {"tmdb_gaps": len(missing), "lk21_observed": len(entries),
                                    "verified": len(matched), "ambiguous": ambiguous,
                                    "errors": errors}
        summary["new"] = found_all
        summary["new_count"] = len(found_all)
        save(summary)
    print(f"Found {len(found_all)} review candidates. Catalog unchanged.", flush=True)


if __name__ == "__main__":
    main()
