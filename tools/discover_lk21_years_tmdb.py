"""Review-only LK21 movie year discovery, verified against TMDB metadata.

Fetches public year listing pages; no player links or media. Stops on access
restrictions and never invents source URLs or treats TMDB as proof of LK21 presence.
"""
import argparse
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.robotparser import RobotFileParser

import requests
from tools.auto_discover_lk21 import MOVIE_BASE, UA, candidates
from tools.enrich_tmdb import match, tmdb_get

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
DENIAL = re.compile(r"captcha|verify you are human|access denied", re.I)


def identity(title, year):
    return (re.sub(r"[^a-z0-9]", "", str(title).casefold()), str(year))


def fetch_listing(session, robot, year, page):
    path = f"/year/{year}" + (f"/page/{page}" if page > 1 else "")
    url = MOVIE_BASE + path
    if not robot.can_fetch(UA, url):
        return None, "robots.txt disallows " + url
    try:
        response = session.get(url, timeout=20)
        if response.status_code in (401, 403, 429):
            return None, f"Restricted HTTP {response.status_code}: {url}"
        response.raise_for_status()
        if urlparse(response.url).hostname != urlparse(MOVIE_BASE).hostname:
            return None, "Cross-host redirect: " + response.url
        if DENIAL.search(response.text):
            return None, "Verification page: " + url
        return response.text, None
    except requests.RequestException as exc:
        return None, f"Unreachable {url}: {exc}"


def select_missing(items, entries, year, token, session, delay):
    seen_urls = {(str(x.get("type")), str(x.get("url", "")).rstrip("/"))
                 for x in items if isinstance(x, dict)}
    seen_titles = {(str(x.get("type")), *identity(x.get("title", ""), x.get("year", "")))
                   for x in items if isinstance(x, dict)}
    new, rejected = [], []
    for entry in entries:
        key = ("movie", *identity(entry["title"], entry["year"]))
        urlkey = ("movie", entry["url"].rstrip("/"))
        if key in seen_titles or urlkey in seen_urls:
            continue
        try:
            result = tmdb_get("search/movie", {
                "query": entry["title"], "year": str(year),
                "include_adult": "false", "language": "en-US"
            }, token)
            candidate = match(entry, result.get("results", []))
        except (requests.RequestException, TimeoutError, OSError, ValueError) as exc:
            raise RuntimeError(f"TMDB failed; stopping before publishing: {exc}") from exc
        if candidate is None:
            rejected.append({"title": entry["title"], "year": year, "reason": "No unambiguous TMDB match"})
        else:
            clean = dict(entry)
            clean["tmdb_id"] = candidate["id"]
            clean["tmdb_type"] = "movie"
            # Source listing title/year/url remain authoritative.
            new.append(clean)
            seen_titles.add(key)
            seen_urls.add(urlkey)
        time.sleep(delay)
    return new, rejected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-year", type=int, default=2015)
    parser.add_argument("--end-year", type=int, default=2025)
    parser.add_argument("--pages-per-year", type=int, default=3)
    parser.add_argument("--delay", type=float, default=0.4, help="TMDB request delay")
    parser.add_argument("--listing-delay", type=float, default=3)
    args = parser.parse_args()
    if not (2015 <= args.start_year <= args.end_year <= 2025):
        parser.error("Year range must be within 2015-2025")
    if not 1 <= args.pages_per_year <= 20 or args.delay < 0.25 or args.listing_delay < 2:
        parser.error("Pages 1-20; TMDB delay >= .25s; listing delay >= 2s")
    token = os.environ.get("TMDB_TOKEN", "").strip()
    if not token:
        parser.error("TMDB_TOKEN missing")
    document = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = document.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("Invalid/empty catalog; refusing to modify")
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    robot = RobotFileParser()
    try:
        robots = session.get(MOVIE_BASE + "/robots.txt", timeout=15)
        robots.raise_for_status()
        robot.parse(robots.text.splitlines())
    except requests.RequestException as exc:
        raise SystemExit(f"robots.txt unavailable; catalog unchanged: {exc}")
    observed = {}
    errors = {}
    discovered = {}
    for year in range(args.end_year, args.start_year - 1, -1):
        unique = {}
        for page in range(1, args.pages_per_year + 1):
            html, error = fetch_listing(session, robot, year, page)
            if error:
                errors[str(year)] = error
                break
            found = [x for x in candidates(html, MOVIE_BASE, "movie").values() if x["year"] == year]
            if not found:
                errors[str(year)] = f"No recognized movie cards on page {page}"
                break
            for x in found:
                unique[x["url"]] = x
            if page < args.pages_per_year:
                time.sleep(args.listing_delay)
        observed[str(year)] = len(unique)
        discovered[year] = list(unique.values())
    pending = []
    rejected = []
    for year, entries in discovered.items():
        try:
            added, excluded = select_missing(items + pending, entries, year, token, session, args.delay)
            pending.extend(added)
            rejected.extend(excluded)
        except RuntimeError as exc:
            errors["tmdb"] = str(exc)
            break
    report = {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "years": [args.start_year, args.end_year],
        "pages_per_year": args.pages_per_year,
        "observed": observed,
        "errors": errors,
        "new_count": len(pending),
        "tmdb_unmatched_count": len(rejected),
        "new": pending,
        "tmdb_unmatched": rejected
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not any(observed.values()) or "tmdb" in errors:
        raise SystemExit("No usable LK21 data or TMDB failure; catalog unchanged. See report.")
    if pending:
        document["items"] = items + pending
        CATALOG.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Checked {args.start_year}-{args.end_year}; LK21 observed={sum(observed.values())}; new verified={len(pending)}; TMDB unmatched={len(rejected)}. Review PR before merging.")


if __name__ == "__main__":
    main()
