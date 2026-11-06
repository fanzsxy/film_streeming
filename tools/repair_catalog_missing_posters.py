"""Repair only missing/invalid FilmStream catalog posters.

No full TMDB scan. Reuse existing catalog entries and saved local crawler
results, optionally inspect only remaining URLs using visible Chromium.
Default dry run. --apply backs up catalog and saves each successful repair.
Never replace a valid poster, title, URL, synopsis, or movie/series type.
"""
import argparse
import json
import os
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.audit_catalog_completeness import valid_url
from tools.import_local_lk21_sitemaps import identity
from tools.local_lk21_browser_search import NavigationPacer, browse, load_robots
from tools.repair_local_sitemap_posters import extract_detail_poster

CATALOG = Path("assets/catalog/filmstream_catalog.json")
RESULTS = Path("crawler/data/local_sitemap_detail_results.json")
PROGRESS = Path("crawler/data/catalog_poster_repair_progress.json")
REPORT = Path("crawler/data/catalog_poster_repair_report.json")
VALID_TYPES = {"movie", "series", "tv"}


def good_poster(value):
    if not valid_url(value):
        return False
    path = urlparse(value).path.lower()
    if path.endswith((".svg", ".gif", ".ico")):
        return False
    return not any(s in path for s in ("placeholder", "no-image", "no-poster", "favicon", "avatar"))


def poster_candidates(catalog, results):
    """Offline posters verified by URL or a UNIQUE type+year+title identity."""
    by_url, by_name = defaultdict(set), defaultdict(set)
    sources = list(catalog.get("items", []))
    for field in ("verified", "age_restricted"):
        sources.extend(results.get(field, []) if isinstance(results.get(field), list) else [])
    for item in sources:
        if not isinstance(item, dict) or not good_poster(item.get("poster_url")):
            continue
        kind = "series" if item.get("type") in ("series", "tv") else "movie"
        year = str(item.get("year") or "")
        key = (kind, identity(item.get("title") or "", year))
        poster = item["poster_url"].strip()
        if valid_url(item.get("url")):
            by_url[item["url"].strip().rstrip("/").casefold()].add(poster)
        if key[1][0]:
            by_name[key].add(poster)
    return by_url, by_name


def catalog_missing(catalog):
    return [(index, item) for index, item in enumerate(catalog.get("items", []))
            if isinstance(item, dict) and not valid_url(item.get("poster_url"))]


def match_offline(item, by_url, by_name):
    url = str(item.get("url") or "").strip().rstrip("/").casefold()
    matches = by_url.get(url, set())
    if len(matches) == 1:
        return next(iter(matches)), "saved_url"
    if len(matches) > 1:
        return None, "ambiguous_url_posters"
    kind = "series" if item.get("type") in ("series", "tv") else "movie"
    key = (kind, identity(item.get("title") or "", item.get("year") or ""))
    matches = by_name.get(key, set())
    if len(matches) == 1:
        return next(iter(matches)), "saved_title_year"
    return None, "ambiguous_title_year" if len(matches) > 1 else "not_found_offline"


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".repair.tmp")
    try:
        temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def save_catalog(path, catalog):
    temp = path.with_name(path.name + ".poster_update.tmp")
    try:
        temp.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n",
                        encoding="utf-8")
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def apply_poster(catalog, index, poster):
    item = catalog["items"][index]
    if valid_url(item.get("poster_url")) or not good_poster(poster):
        return False
    item["poster_url"] = poster
    return True


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("Katalog kosong/tidak valid")
    results = (json.loads(args.results.read_text(encoding="utf-8-sig"))
               if args.results.is_file() else {})
    missing = catalog_missing(catalog)
    by_url, by_name = poster_candidates(catalog, results)
    offline, browser_queue, reasons = [], [], Counter()
    for idx, item in missing:
        poster, source = match_offline(item, by_url, by_name)
        if poster:
            offline.append((idx, poster, source))
        else:
            reasons[source] += 1
            browser_queue.append(idx)
    print(f"Total katalog: {len(items)} | poster kosong/tidak valid: {len(missing)}", flush=True)
    print(f"Poster tersedia dari data lokal: {len(offline)}", flush=True)
    print(f"Perlu pemeriksaan lebih lanjut: {len(browser_queue)}", flush=True)
    if not args.apply:
        print("DRY RUN: katalog tidak berubah; gunakan --apply untuk menerapkan.", flush=True)
        return

    # The catalog is backed up once before any possible modification.
    backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
        datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
    backup.write_bytes(args.catalog.read_bytes())
    print("Backup katalog:", backup, flush=True)

    state = {"checked": {}, "repaired": {}}
    if args.progress.is_file():
        state = json.loads(args.progress.read_text(encoding="utf-8-sig"))
    completed = state.setdefault("checked", {})
    repaired = state.setdefault("repaired", {})
    def commit():
        save_catalog(args.catalog, catalog)
        write_json(args.progress, state)

    counters = Counter()
    for idx, poster, source in offline:
        if apply_poster(catalog, idx, poster):
            url = items[idx].get("url", "")
            repaired[url] = source
            counters["offline_repaired"] += 1
    if counters["offline_repaired"]:
        commit()
    print(f"Poster dilengkapi dari data lokal: {counters['offline_repaired']}", flush=True)

    if args.browser and browser_queue:
        from playwright.sync_api import sync_playwright
        targets = [idx for idx in browser_queue if
                   str(items[idx].get("url") or "") not in completed]
        if args.limit:
            targets = targets[:args.limit]
        if targets:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(headless=False)
                page = browser.new_page(viewport={"width": 1280, "height": 820})
                try:
                    robots = load_robots(page)
                    pacer = NavigationPacer(args.delay)
                    for n, idx in enumerate(targets, 1):
                        item = items[idx]
                        url = str(item.get("url") or "").rstrip("/")
                        if not valid_url(url) or item.get("type") not in VALID_TYPES:
                            completed[url] = "invalid_url_or_type"
                            counters["skipped"] += 1
                            write_json(args.progress, state)
                            continue
                        print(f"[{n}/{len(targets)}] {item.get('title')} ({item.get('year')})", flush=True)
                        try:
                            html = browse(page, robots, url, pacer=pacer)
                        except RuntimeError as exc:
                            state.setdefault("errors", []).append({"url": url, "reason": str(exc)})
                            write_json(args.progress, state)
                            print("Akses dihentikan:", str(exc), flush=True)
                            break
                        if page.url.rstrip("/") != url:
                            poster, status = None, "redirect"
                        else:
                            poster, status = extract_detail_poster(html, url, item)
                        if poster and apply_poster(catalog, idx, poster):
                            repaired[url] = "chromium_detail"
                            counters["browser_repaired"] += 1
                            completed[url] = "repaired"
                            commit()
                        else:
                            completed[url] = status
                            counters[status] += 1
                            write_json(args.progress, state)
                finally:
                    browser.close()
    remaining = len(catalog_missing(catalog))
    report = {"original_missing": len(missing), "offline_matches": len(offline),
              "repaired_this_run": dict(counters), "remaining_missing": remaining,
              "status_counts": dict(Counter(completed.values())),
              "backup": str(backup)}
    write_json(args.report, report)
    print("Selesai. Masih tanpa poster:", remaining, "| laporan:", args.report, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--results", type=Path, default=RESULTS)
    p.add_argument("--progress", type=Path, default=PROGRESS)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--browser", action="store_true",
                   help="Use headed Chromium for unresolved URL details; no title searches")
    p.add_argument("--limit", type=int, default=0, help="Max browser URLs in this run; 0=all")
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--apply", action="store_true", help="Backup + repair only poster_url")
    args = p.parse_args()
    if args.delay < 2 or args.limit < 0:
        p.error("--delay >= 2 and --limit >= 0 required")
    run(args)


if __name__ == "__main__":
    main()
