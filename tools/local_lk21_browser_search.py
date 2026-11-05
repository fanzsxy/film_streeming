"""Local visible Chromium search for already reconciled FilmStream catalog gaps.

Uses a REAL headed browser, no requests-based LK21 title-search crawler.
Only publicly accessible metadata and observed links; stops on access restrictions.
Does not bypass verification, CAPTCHAs or robots.txt. Safe, resumable output.
"""
import argparse
import json
import re
import time
from pathlib import Path
from urllib.robotparser import RobotFileParser

from playwright.sync_api import sync_playwright, TimeoutError as BrowserTimeout

from tools.auto_discover_lk21 import MOVIE_BASE, UA
from tools.local_lk21_gap_match import (
    discover_search_form, search_url, extract_matches, poster_from_detail,
    detail_title_year, validated, write_json,
)
from tools.reconcile_tmdb_gaps import reconcile
from tools.tmdb_full_gap_scan import identity

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
OUTPUT = Path("crawler/data/local_lk21_gap_candidates.json")
STATE = Path("crawler/data/local_lk21_visible_browser_progress.json")
BLOCK = re.compile(r"captcha|verify you are human|access denied", re.I)


def browse(page, robots, url, render_wait_ms=0):
    if not validated(url):
        raise RuntimeError("LK21 outside configured host; stopped")
    if not robots.can_fetch(UA, url):
        raise RuntimeError("Disallowed by robots.txt; stopped")
    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
        if render_wait_ms:
            page.wait_for_timeout(render_wait_ms)  # Search cards may finish rendering shortly after DOM ready.
    except BrowserTimeout:
        raise RuntimeError("Browser navigation timeout; stopped") from None
    if not validated(page.url):
        raise RuntimeError("Browser redirected away from configured LK21 host; stopped")
    if response is None or response.status in (401, 403, 429):
        raise RuntimeError("LK21 access restricted: " +
                           str(response.status if response else "unknown"))
    if response.status >= 400:
        raise RuntimeError("LK21 HTTP " + str(response.status))
    html = page.content()
    if BLOCK.search(html):
        raise RuntimeError("LK21 verification page detected; stopped without bypass")
    return html


def load_robots(page):
    from playwright.sync_api import TimeoutError as BrowserTimeout
    """Read robots via the visible browser itself; never use hidden HTTP bot."""
    url = MOVIE_BASE + "/robots.txt"
    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
    except BrowserTimeout:
        raise RuntimeError("robots.txt timeout; cannot establish policy") from None
    if response is None or response.status != 200:
        raise RuntimeError("Cannot read LK21 robots.txt; stopped")
    text = page.locator("body").inner_text(timeout=10000)
    if "<html" in text.lower():
        raise RuntimeError("robots.txt returned HTML; stopped")
    robot = RobotFileParser()
    robot.parse(text.splitlines())
    return robot


def find_candidate(page, robots, search_form, movie, delay):
    year = int(movie["year"])
    titles = list(dict.fromkeys(
        x.strip() for x in (movie.get("title"), movie.get("original_title"))
        if isinstance(x, str) and x.strip()))
    matches = {}
    for index, title in enumerate(titles):
        url = search_url(search_form, title)
        html = browse(page, robots, url, render_wait_ms=400)
        rows = extract_matches(html, str(year), titles, page.url)
        for row in rows:
            if validated(row["url"]):
                matches[row["url"]] = row
        print(f"  Browser search '{title}': {len(rows)} matching link(s)", flush=True)
        if matches:
            break
        if index < len(titles) - 1:
            page.wait_for_timeout(int(delay * 1000))
    if not matches:
        return "search_no_match", None
    if len(matches) != 1:
        return "ambiguous", None
    card = next(iter(matches.values()))
    page.wait_for_timeout(int(delay * 1000))
    html = browse(page, robots, card["url"])
    title, observed_year = detail_title_year(html)
    names = {identity(t, year)[0] for t in titles}
    if observed_year != year or identity(title or "", year)[0] not in names:
        return "detail_mismatch", None
    poster = poster_from_detail(html, card["url"]) or card.get("poster_url") or ""
    return "verified", {
        "title": title, "year": year, "url": card["url"],
        "type": "movie", "poster_url": poster, "tmdb_id": movie["tmdb_id"]
    }


def run(limit, delay, state_path=STATE, output=OUTPUT):
    report = json.loads(REPORT.read_text(encoding="utf-8-sig"))
    catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    queue = reconcile(report, catalog)["items"]
    print(f"Catalog -> saved TMDB: {len(queue)} title gaps queued for LK21 browser.", flush=True)
    state = {"completed": {}, "found": [], "errors": []}
    if state_path.is_file():
        state = json.loads(state_path.read_text(encoding="utf-8-sig"))
    completed = state.setdefault("completed", {})
    found = state.setdefault("found", [])
    errors = state.setdefault("errors", [])
    existing_urls = {str(m.get("url", "")).rstrip("/") for m in catalog["items"]
                     if isinstance(m, dict)}
    existing_ids = {m.get("tmdb_id") for m in catalog["items"]
                    if isinstance(m, dict) and m.get("type") == "movie"}
    seen_urls = {r["url"].rstrip("/") for r in found}
    def save():
        write_json(state_path, state)
        write_json(output, {"new": found, "new_count": len(found),
                            "checked": len(completed), "errors": errors,
                            "applied": False, "source": "visible_chromium"})
    save()
    processed = 0
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise SystemExit("Playwright belum terpasang: py -3 -m pip install playwright")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page(viewport={"width": 1280, "height": 820})
        try:
            print("Chromium lokal terbuka. Memeriksa robots.txt...", flush=True)
            robots = load_robots(page)
            print("Membuka beranda LK21 untuk menemukan form pencarian...", flush=True)
            search = discover_search_form(browse(page, robots, MOVIE_BASE + "/", render_wait_ms=400))
            if not search:
                raise RuntimeError("Search form GET not found on visible LK21 page")
            print(f"Search siap. Resume: {len(completed)} checked; {len(found)} verified.", flush=True)
            for movie in queue:
                key = str(movie["year"]) + ":" + str(movie["tmdb_id"])
                if key in completed or movie["tmdb_id"] in existing_ids:
                    continue
                print(f"[{processed+1}/{limit if limit else 'semua'}] {movie['title']} ({movie['year']})",
                      flush=True)
                try:
                    status, candidate = find_candidate(page, robots, search, movie, delay)
                except RuntimeError as exc:
                    errors.append({"key": key, "reason": str(exc)})
                    save()
                    print("BERHENTI: " + str(exc), flush=True)
                    break
                if status == "verified" and candidate:
                    if candidate["url"].rstrip("/") in existing_urls | seen_urls:
                        status = "duplicate_url"
                    else:
                        found.append(candidate)
                        seen_urls.add(candidate["url"].rstrip("/"))
                completed[key] = status
                processed += 1
                print(f"  Status: {status} | kandidat: {len(found)}", flush=True)
                save()
                if limit and processed >= limit:
                    break
                page.wait_for_timeout(int(delay * 1000))
        except RuntimeError as exc:
            errors.append({"reason": str(exc)})
            save()
            print("Browser berhenti: " + str(exc), flush=True)
        finally:
            browser.close()
    print(f"Run selesai: {processed} judul | verified {len(found)}. Katalog belum diubah.",
          flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--delay", type=float, default=2)
    args = p.parse_args()
    if args.limit < 0 or args.delay < 2:
        p.error("limit >= 0 and delay >= 2")
    run(args.limit, args.delay)


if __name__ == "__main__":
    main()
