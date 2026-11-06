"""Recheck only catalog movies with recorded redirect/missing-detail poster failures.

Visible Chromium, public LK21 pages, robots.txt and browser pacing. Logs the
observed redirect destination; by default accepts a poster only for matching movie title/year. Optional
--source-metadata accepts an exact source URL page, its title and poster,
without comparing the old catalog title/year. Never changes type or source URL.
Does not attempt age verification or circumvent access restrictions.
"""
import argparse
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from bs4 import BeautifulSoup

from tools.audit_catalog_completeness import good_poster
from tools.local_lk21_browser_search import browse, load_robots, NavigationPacer
from tools.local_lk21_gap_match import validated, poster_from_detail
from tools.triage_missing_catalog_posters import status_for, group_status
from tools.repair_catalog_missing_posters import (
    CATALOG, PROGRESS, extract_catalog_poster, save_catalog, write_json,
)

SITEMAP_PROGRESS = Path("crawler/data/local_sitemap_detail_progress.json")
STATE = Path("crawler/data/redirect_poster_recheck_progress.json")
REPORT = Path("crawler/data/redirect_poster_recheck_report.json")
ALL_STATE = Path("crawler/data/remaining_movie_poster_progress.json")
ALL_REPORT = Path("crawler/data/remaining_movie_poster_report.json")
SOURCE_STATE = Path("crawler/data/source_movie_metadata_progress.json")
SOURCE_REPORT = Path("crawler/data/source_movie_metadata_report.json")
RECHECK = {"redirect", "missing_detail_heading_or_year", "no_detail_poster"}
RESTRICTED = ("restricted", "verification", "captcha", "403", "401", "429")


def eligible_status(value, recheck=RECHECK):
    """Match triage grouping, including compound redirect status strings."""
    if isinstance(value, dict):
        value = value.get("status")
    return group_status(value) == "redirect" or value in recheck


def targets(catalog, prior, recheck=RECHECK, sitemap_state=None, all_missing=False):
    sitemap_state = sitemap_state or {}
    for index, item in enumerate(catalog.get("items") or []):
        if not isinstance(item, dict) or item.get("type") != "movie":
            continue
        if good_poster(item.get("poster_url")):
            continue
        url = str(item.get("url") or "").rstrip("/")
        if not validated(url):
            continue
        if all_missing:
            yield index, item
            continue
        reason = status_for(url, prior, sitemap_state)
        # First follow the same prioritized status that triage reported.
        # Also include detail-metadata failures that deserve a fresh check.
        if (reason["category"] == "redirect" or
                any(eligible_status(reason[key], recheck) for key in (
                    "poster_detail_status", "search_status", "sitemap_status"))):
            yield index, item


def classify(html, final_url, item):
    poster, detail_status = extract_catalog_poster(html, final_url, item)
    if poster and good_poster(poster):
        return "verified_poster", poster
    return detail_status, None


def source_metadata(html, final_url):
    """Extract displayed film title and poster on the existing catalog URL."""
    soup = BeautifulSoup(html, "html.parser")
    heading = soup.select_one("h1")
    if heading is None:
        return None, "missing_detail_heading"
    heading_text = heading.get_text(" ", strip=True)
    if not heading_text:
        return None, "missing_detail_heading"
    # Strip a trailing release year for clean display; do not compare years.
    title = re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", heading_text).strip()
    if title == heading_text:
        title = re.sub(r"\s+(?:19|20)\d{2}\s*$", "", heading_text).strip()
    if len(title) < 2 or title.casefold() in {
            "home", "movies", "movie", "watch online", "lk21"}:
        return None, "generic_heading"
    poster = poster_from_detail(html, final_url)
    if not good_poster(poster):
        return None, "no_detail_poster"
    return {"observed_title": title, "poster_url": poster}, "verified_source_metadata"


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    original = json.loads(args.progress.read_text(encoding="utf-8-sig"))
    sitemap = (json.loads(args.sitemap_progress.read_text(encoding="utf-8-sig"))
               if args.sitemap_progress.is_file() else {})
    queue = list(targets(catalog, original, sitemap_state=sitemap,
                         all_missing=args.all_missing))
    if args.source_metadata:
        state_path = args.state if args.state != STATE else SOURCE_STATE
        report_path = args.report if args.report != REPORT else SOURCE_REPORT
    else:
        state_path = args.state if not args.all_missing or args.state != STATE else ALL_STATE
        report_path = args.report if not args.all_missing or args.report != REPORT else ALL_REPORT
    state = (json.loads(state_path.read_text(encoding="utf-8-sig"))
             if state_path.is_file() else {"checked": {}, "matches": {}})
    checked = state.setdefault("checked", {})
    matches = state.setdefault("matches", {})
    todo = [(i, item) for i, item in queue
            if (args.recheck or
                (args.retry_status and
                 (checked.get(str(item["url"]).rstrip("/")) or {}).get("status")
                 in args.retry_status) or
                str(item["url"]).rstrip("/") not in checked)]
    if args.limit:
        todo = todo[:args.limit]
    # Counts use the same categorization as triage, rather than exact strings.
    reasons = [status_for(str(item["url"]).rstrip("/"), original, sitemap)
               for _, item in queue]
    print("Status redirect sesuai triage:", sum(
        reason["category"] == "redirect" for reason in reasons
    ), "| detail:", sum(eligible_status(reason["poster_detail_status"])
                       for reason in reasons),
        "| pencarian:", sum(eligible_status(reason["search_status"])
                           for reason in reasons),
        "| sitemap:", sum(eligible_status(reason["sitemap_status"])
                         for reason in reasons), flush=True)
    print("Kandidat redirect/detail movie:", len(queue),
          "| diperiksa sekarang:", len(todo), flush=True)
    if todo:
        from playwright.sync_api import sync_playwright, Error as BrowserError
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            page = browser.new_page(viewport={"width": 1280, "height": 820})
            try:
                robots = load_robots(page)
                pacer = NavigationPacer(args.delay)
                for number, (index, item) in enumerate(todo, 1):
                    url = str(item["url"]).rstrip("/")
                    print(f"[{number}/{len(todo)}] {item.get('title')} ({item.get('year')})",
                          flush=True)
                    try:
                        html = browse(page, robots, url, pacer=pacer)
                        final_url = page.url.rstrip("/")
                        # Redirect to the series referral path is not a movie
                        # detail page. Keep it for later series handling.
                        from tools.repair_drama_redirect_series import drama_slug
                        if drama_slug(final_url):
                            status, poster = "drama_redirect", None
                        elif final_url != url:
                            # Never associate a different page's artwork with
                            # the catalog URL, even for same-host redirects.
                            status, poster = "redirected_elsewhere", None
                        elif args.source_metadata:
                            extracted, status = source_metadata(html, final_url)
                            poster = extracted["poster_url"] if extracted else None
                            if extracted:
                                matches[url] = {"index": index, "poster_url": poster,
                                                "final_url": final_url,
                                                "original_title": item.get("title"),
                                                "observed_title": extracted["observed_title"]}
                        else:
                            status, poster = classify(html, final_url, item)
                            if poster:
                                matches[url] = {"index": index, "poster_url": poster,
                                                "final_url": final_url,
                                                "title": item.get("title"),
                                                "year": item.get("year")}
                    except BrowserError as exc:
                        msg = str(exc).splitlines()[0][:300]
                        if "net::ERR_ABORTED" in str(exc):
                            status = "navigation_aborted"
                            final_url = page.url
                            checked[url] = {"status": status, "final_url": final_url}
                            state.setdefault("errors", []).append({"url": url, "reason": msg})
                            write_json(state_path, state)
                            print("  Navigasi dibatalkan, lanjut URL berikutnya:", msg, flush=True)
                            continue
                        state.setdefault("errors", []).append({"url": url, "reason": msg})
                        write_json(state_path, state)
                        print("  Browser gagal, pemeriksaan dihentikan:", msg, flush=True)
                        break
                    except RuntimeError as exc:
                        final_url = page.url
                        error = str(exc)
                        status = ("access_restricted" if any(x in error.lower() for x in RESTRICTED)
                                  else "navigation_error")
                        print("  Akses:", error, flush=True)
                        state.setdefault("errors", []).append(
                            {"url": url, "final_url": final_url, "reason": error})
                        if status == "access_restricted":
                            checked[url] = {"status": status, "final_url": final_url}
                            write_json(state_path, state)
                            print("  Pemeriksaan dihentikan karena pembatasan akses.", flush=True)
                            break
                    checked[url] = {"status": status, "final_url": final_url}
                    print(f"  Status: {status} | tujuan: {final_url}", flush=True)
                    write_json(state_path, state)
            finally:
                browser.close()
    applicable = []
    url_counts = Counter(str(r.get("url") or "").rstrip("/")
                         for r in catalog["items"] if isinstance(r, dict))
    for url, found in matches.items():
        index = found.get("index")
        if not isinstance(index, int) or index < 0 or index >= len(catalog["items"]):
            continue
        item = catalog["items"][index]
        if (url_counts[url] != 1 or
                str(item.get("url") or "").rstrip("/") != url or
                item.get("type") != "movie" or good_poster(item.get("poster_url")) or
                not good_poster(found.get("poster_url"))):
            continue
        if args.source_metadata:
            title = found.get("observed_title")
            if (found.get("final_url") != url or
                    not isinstance(title, str) or not title.strip()):
                continue
            applicable.append((index, found["poster_url"], title))
        elif item.get("title") == found.get("title") and item.get("year") == found.get("year"):
            applicable.append((index, found["poster_url"], None))
    applied = 0
    if args.apply and applicable:
        backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
                  datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
        backup.write_bytes(args.catalog.read_bytes())
        for index, poster, observed_title in applicable:
            catalog["items"][index]["poster_url"] = poster
            if args.source_metadata:
                catalog["items"][index]["title"] = observed_title
            applied += 1
        save_catalog(args.catalog, catalog)
        print("Backup:", backup, flush=True)
    counts = Counter(x["status"] for x in checked.values() if isinstance(x, dict))
    report = {"original_candidates": len(queue), "checked": len(checked),
              "statuses": dict(counts), "verified_poster": len(applicable),
              "applied": applied, "details": checked,
              "matches": matches}
    write_json(report_path, report)
    print("Poster terverifikasi dan bisa dipasang:", len(applicable))
    print("Poster dipasang:", applied)
    print("Laporan:", report_path)
    if not args.apply:
        print("DRY RUN: tidak mengubah katalog. --apply memasang hanya poster terverifikasi.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--progress", type=Path, default=PROGRESS)
    p.add_argument("--sitemap-progress", type=Path, default=SITEMAP_PROGRESS)
    p.add_argument("--state", type=Path, default=STATE)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--recheck", action="store_true")
    p.add_argument("--retry-status", action="append", default=[],
                   help="Reinspect only completed rows with a given saved status (repeatable)")
    p.add_argument("--source-metadata", action="store_true",
                   help="Use exact catalog URL to collect its own H1 title and poster, without comparing old title/year; separate checkpoint")
    p.add_argument("--all-missing", action="store_true",
                   help="Inspect every missing movie poster by its catalog URL, not title search; use separate resumable checkpoint")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    if args.limit < 0 or args.delay < 2:
        p.error("limit must be >= 0 and delay >= 2")
    if args.source_metadata and not args.all_missing:
        p.error("--source-metadata requires --all-missing")
    run(args)


if __name__ == "__main__":
    main()
