"""Recheck only catalog movies with recorded redirect/missing-detail poster failures.

Visible Chromium, public LK21 pages, robots.txt and browser pacing. Logs the
observed redirect destination; accepts a poster only if the final public page
has exactly the same movie title AND year. Never changes type or source URL.
Does not attempt age verification or circumvent access restrictions.
"""
import argparse
import json
from collections import Counter
from datetime import datetime
from pathlib import Path

from tools.audit_catalog_completeness import good_poster
from tools.local_lk21_browser_search import browse, load_robots, NavigationPacer
from tools.local_lk21_gap_match import validated
from tools.repair_catalog_missing_posters import (
    CATALOG, PROGRESS, extract_catalog_poster, save_catalog, write_json,
)

STATE = Path("crawler/data/redirect_poster_recheck_progress.json")
REPORT = Path("crawler/data/redirect_poster_recheck_report.json")
RECHECK = {"redirect", "missing_detail_heading_or_year", "no_detail_poster"}
RESTRICTED = ("restricted", "verification", "captcha", "403", "401", "429")


def targets(catalog, prior, recheck=RECHECK):
    checked = prior.get("checked") or {}
    for index, item in enumerate(catalog.get("items") or []):
        if not isinstance(item, dict) or item.get("type") != "movie":
            continue
        if good_poster(item.get("poster_url")):
            continue
        url = str(item.get("url") or "").rstrip("/")
        if checked.get(url) in recheck and validated(url):
            yield index, item


def classify(html, final_url, item):
    poster, detail_status = extract_catalog_poster(html, final_url, item)
    if poster and good_poster(poster):
        return "verified_poster", poster
    return detail_status, None


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    original = json.loads(args.progress.read_text(encoding="utf-8-sig"))
    queue = list(targets(catalog, original))
    state = (json.loads(args.state.read_text(encoding="utf-8-sig"))
             if args.state.is_file() else {"checked": {}, "matches": {}})
    checked = state.setdefault("checked", {})
    matches = state.setdefault("matches", {})
    todo = [(i, item) for i, item in queue
            if args.recheck or str(item["url"]).rstrip("/") not in checked]
    if args.limit:
        todo = todo[:args.limit]
    print("Kandidat redirect/detail movie:", len(queue),
          "| diperiksa sekarang:", len(todo), flush=True)
    if todo:
        from playwright.sync_api import sync_playwright
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
                        status, poster = classify(html, final_url, item)
                        if poster:
                            matches[url] = {"index": index, "poster_url": poster,
                                            "final_url": final_url,
                                            "title": item.get("title"), "year": item.get("year")}
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
                            write_json(args.state, state)
                            print("  Pemeriksaan dihentikan karena pembatasan akses.", flush=True)
                            break
                    checked[url] = {"status": status, "final_url": final_url}
                    print(f"  Status: {status} | tujuan: {final_url}", flush=True)
                    write_json(args.state, state)
            finally:
                browser.close()
    applicable = []
    for url, found in matches.items():
        index = found.get("index")
        if not isinstance(index, int) or index < 0 or index >= len(catalog["items"]):
            continue
        item = catalog["items"][index]
        if (str(item.get("url") or "").rstrip("/") == url and
                item.get("title") == found.get("title") and
                item.get("year") == found.get("year") and
                item.get("type") == "movie" and not good_poster(item.get("poster_url")) and
                good_poster(found.get("poster_url"))):
            applicable.append((index, found["poster_url"]))
    applied = 0
    if args.apply and applicable:
        backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
                  datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
        backup.write_bytes(args.catalog.read_bytes())
        for index, poster in applicable:
            catalog["items"][index]["poster_url"] = poster
            applied += 1
        save_catalog(args.catalog, catalog)
        print("Backup:", backup, flush=True)
    counts = Counter(x["status"] for x in checked.values() if isinstance(x, dict))
    report = {"original_candidates": len(queue), "checked": len(checked),
              "statuses": dict(counts), "verified_poster": len(applicable),
              "applied": applied, "details": checked,
              "matches": matches}
    write_json(args.report, report)
    print("Poster terverifikasi dan bisa dipasang:", len(applicable))
    print("Poster dipasang:", applied)
    print("Laporan:", args.report)
    if not args.apply:
        print("DRY RUN: tidak mengubah katalog. --apply memasang hanya poster terverifikasi.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--progress", type=Path, default=PROGRESS)
    p.add_argument("--state", type=Path, default=STATE)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--recheck", action="store_true")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    if args.limit < 0 or args.delay < 2:
        p.error("limit must be >= 0 and delay >= 2")
    run(args)


if __name__ == "__main__":
    main()
