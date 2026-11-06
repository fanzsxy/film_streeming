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
from urllib.parse import urlparse, urlencode, urljoin
import re
from bs4 import BeautifulSoup

from tools.audit_catalog_completeness import valid_url
from tools.import_local_lk21_sitemaps import identity
from tools.local_lk21_browser_search import NavigationPacer, browse, load_robots
from tools.local_lk21_gap_match import detail_title_year, poster_from_detail, poster_from_node, validated

CATALOG = Path("assets/catalog/filmstream_catalog.json")
RESULTS = Path("crawler/data/local_sitemap_detail_results.json")
TMDB_CACHE = Path("assets/catalog/tmdb_cache.jsonl")
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


def cache_posters(path):
    """Reuse old matched cache rows only; do not call TMDB or scan titles."""
    found = defaultdict(set)
    if not path.is_file():
        return found
    for line in path.open(encoding="utf-8-sig"):
        try:
            row = json.loads(line)
        except (ValueError, TypeError):
            continue
        if (not isinstance(row, dict) or row.get("match_status") != "matched"
                or not valid_url(row.get("source_url"))):
            continue
        raw = row.get("tmdb_poster_path") or row.get("poster_path") or ""
        if isinstance(raw, str) and raw.startswith("/") and not raw.startswith("//"):
            poster = "https://image.tmdb.org/t/p/w500" + raw
        else:
            poster = raw
        if good_poster(poster):
            kind = "series" if row.get("tmdb_type") == "tv" else "movie"
            found[(kind, row["source_url"].rstrip("/").casefold())].add(poster)
    return found


def catalog_missing(catalog):
    return [(index, item) for index, item in enumerate(catalog.get("items", []))
            if isinstance(item, dict) and not valid_url(item.get("poster_url"))]


def match_offline(item, by_url, by_name, cached=None):
    url = str(item.get("url") or "").strip().rstrip("/").casefold()
    matches = by_url.get(url, set())
    if len(matches) == 1:
        return next(iter(matches)), "saved_url"
    if len(matches) > 1:
        return None, "ambiguous_url_posters"
    kind = "series" if item.get("type") in ("series", "tv") else "movie"
    cached_matches = (cached or {}).get((kind, url), set())
    if len(cached_matches) == 1:
        return next(iter(cached_matches)), "matched_tmdb_cache"
    if len(cached_matches) > 1:
        return None, "ambiguous_tmdb_cache"
    key = (kind, identity(item.get("title") or "", item.get("year") or ""))
    matches = by_name.get(key, set())
    if len(matches) == 1:
        return next(iter(matches)), "saved_title_year"
    return None, "ambiguous_title_year" if len(matches) > 1 else "not_found_offline"


def extract_catalog_poster(html, url, item):
    """Reuse the original sitemap crawler's detail metadata and poster parser.

    An age-related phrase in body copy alone is NOT a reason to skip a film.
    Require actual detail heading/title/year before accepting a poster.
    """
    title, year = detail_title_year(html)
    if not title or year is None:
        return None, "missing_detail_heading_or_year"
    expected_year = str(item.get("year") or "").strip()
    if expected_year.isdigit() and year != int(expected_year):
        return None, "year_mismatch"
    catalog_title = identity(item.get("title") or "", year)[0]
    observed_title = identity(title, year)[0]
    if not catalog_title or catalog_title != observed_title:
        return None, "title_mismatch"
    poster = poster_from_detail(html, url)
    if poster and good_poster(poster):
        return poster, "found"
    return None, "no_detail_poster"


def search_poster_from_listing(html, search_url, item):
    """Find a uniquely matched public search-result poster for the requested title/year.

    Use visible result cards only. Series/movie clues must be explicit. Never
    treat an unrelated card, a different year, or a generic site image as a poster.
    """
    soup = BeautifulSoup(html, "html.parser")
    expected = identity(item.get("title") or "", item.get("year") or "")[0]
    expected_year = str(item.get("year") or "")
    expected_kind = "series" if item.get("type") in ("series", "tv") else "movie"
    found = {}
    mismatched_types = set()
    for anchor in soup.select("a[href]"):
        href = urljoin(search_url, anchor.get("href") or "")
        if not validated(href):
            continue
        parent = anchor.find_parent(["article", "li"]) or anchor.find_parent(
            class_=re.compile(r"item|movie|series|poster|film|result", re.I))
        if parent is None:
            continue
        heading = parent.select_one("h2,h3,h4,.title,.poster-title")
        img = parent.select_one("img")
        if img is None:
            continue
        label = (heading.get_text(" ", strip=True) if heading else
                 img.get("alt") or anchor.get("title") or anchor.get_text(" ", strip=True))
        label = re.sub(r"\s+", " ", label or "").strip()
        # The card, NOT some unrelated search text, must establish title+year.
        if identity(label, expected_year)[0] != expected:
            continue
        card_text = parent.get_text(" ", strip=True)
        slug = urlparse(href).path.rstrip("/").split("/")[-1]
        year_in_slug = re.search(r"-(19\d{2}|20\d{2})$", slug)
        year_in_card = re.search(r"\b(19\d{2}|20\d{2})\b", card_text)
        observed_year = (year_in_slug or year_in_card)
        if not observed_year or observed_year.group(1) != expected_year:
            continue
        kind_labels = re.findall(r"\b(series|serial|tv series|movie|film)\b",
                                 card_text, flags=re.I)
        has_series = any(x.lower() in ("series", "serial", "tv series") for x in kind_labels)
        has_movie = any(x.lower() in ("movie", "film") for x in kind_labels)
        observed_kind = "series" if has_series and not has_movie else (
            "movie" if has_movie and not has_series else None)
        if observed_kind and observed_kind != expected_kind:
            mismatched_types.add(observed_kind)
            continue
        if observed_kind is None:
            # Search cards cannot prove kind without a distinct label.
            continue
        poster = poster_from_node(img, search_url)
        if good_poster(poster):
            found[href] = poster
    posters = set(found.values())
    if len(posters) == 1 and len(found) == 1:
        return next(iter(posters)), "search_verified"
    if len(found) > 1:
        return None, "ambiguous_search_results"
    if mismatched_types:
        return None, "catalog_type_mismatch_" + "_".join(sorted(mismatched_types))
    return None, "search_no_verified_match"


def search_redirected_poster(page, robots, pacer, item):
    """Search only public cards for matching title/year/kind on observed LK21 search."""
    from tools.auto_discover_lk21 import MOVIE_BASE
    lookup = MOVIE_BASE + "/search?" + urlencode({"s": item["title"]})
    html = browse(page, robots, lookup, pacer=pacer)
    return search_poster_from_listing(html, page.url, item)


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
    cached = cache_posters(args.cache)
    offline, browser_queue, reasons = [], [], Counter()
    for idx, item in missing:
        poster, source = match_offline(item, by_url, by_name, cached)
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
    search_checked = state.setdefault("search_checked", {})
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
        retryable = {"redirect", "year_mismatch", "title_mismatch",
                     "missing_detail_heading_or_year", "no_detail_poster"}
        targets = [idx for idx in browser_queue if
                   str(items[idx].get("url") or "") not in completed or (
                       args.retry_search and
                       completed.get(str(items[idx].get("url") or "")) in retryable and
                       str(items[idx].get("url") or "") not in search_checked)]
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
                        if not validated(url):
                            completed[url] = "unsupported_browser_host"
                            counters["skipped"] += 1
                            write_json(args.progress, state)
                            continue
                        old_reason = completed.get(url)
                        try:
                            if args.retry_search and old_reason in retryable:
                                poster, status = search_redirected_poster(page, robots, pacer, item)
                                search_checked[url] = status
                                if status in retryable and args.search_on_redirect:
                            try:
                                searched, searched_status = search_redirected_poster(
                                    page, robots, pacer, item)
                                search_checked[url] = searched_status
                                if searched:
                                    poster, status = searched, searched_status
                                else:
                                    status = searched_status
                            except RuntimeError as exc:
                                state.setdefault("errors", []).append({
                                    "url": url, "reason": "search: " + str(exc)})
                                print("Akses pencarian dihentikan:", str(exc), flush=True)
                                write_json(args.progress, state)
                                break
                        if poster and apply_poster(catalog, idx, poster):
                                    repaired[url] = "lk21_public_search"
                                    counters["search_repaired"] += 1
                                    completed[url] = "repaired"
                                    commit()
                                else:
                                    counters[status] += 1
                                    write_json(args.progress, state)
                                continue
                            html = browse(page, robots, url, pacer=pacer)
                        except RuntimeError as exc:
                            state.setdefault("errors", []).append({"url": url, "reason": str(exc)})
                            write_json(args.progress, state)
                            print("Akses dihentikan:", str(exc), flush=True)
                            break
                        if page.url.rstrip("/") != url:
                            poster, status = None, "redirect"
                        else:
                            poster, status = extract_catalog_poster(html, url, item)
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
    p.add_argument("--cache", type=Path, default=TMDB_CACHE)
    p.add_argument("--progress", type=Path, default=PROGRESS)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--retry-search", action="store_true",
                   help="Retry prior redirects/year mismatches via public LK21 search cards")
    p.add_argument("--search-on-redirect", action="store_true",
                   help="Search public cards after redirects/detail mismatch")
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
