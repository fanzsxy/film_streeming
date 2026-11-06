"""Resumeable local Chromium detail crawler for saved LK21 post sitemaps.

Reads locally stored XML only; never downloads the sitemaps or searches TMDB.
Queues URL gaps and previously imported provisional sitemap entries, visits only
the observed detail URLs, and collects real title/year, poster, synopsis.
Default --limit 100; --limit 0 runs all remaining. DOES NOT edit catalog.
Use tools.apply_lk21_sitemap_details for reviewed catalog updates.
"""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright
from tools.import_local_lk21_sitemaps import (
    CATALOG, SITEMAPS, clean_url, identity, load_sitemap, parse_slug,
)
from tools.local_lk21_browser_search import (
    NavigationPacer, browse, load_robots,
)
from tools.local_lk21_gap_match import poster_from_detail, write_json

STATE = Path("crawler/data/local_sitemap_detail_progress.json")
OUTPUT = Path("crawler/data/local_sitemap_detail_results.json")
PROVISIONAL = "sitemap_slug_unverified"
FINAL = "sitemap_detail_verified"


def detail_metadata(html, url, expected_year=None):
    """Prefer visible detail heading; do not silently use slug as verified title."""
    soup = BeautifulSoup(html, "html.parser")
    # A restricted-access notice is not a movie detail page. Never try to
    # authenticate, bypass the age gate, or infer metadata from its heading.
    visible_text = soup.get_text(" ", strip=True).casefold()
    if (("materi khusus dewasa" in visible_text and
         ("konfirmasi umur" in visible_text or "18 tahun" in visible_text))
        or ("peringatan" in visible_text and "login gmail anda" in visible_text)):
        return None, "age_restricted"
    heading = soup.select_one("h1")
    if heading is None:
        return None, "missing_heading"
    text = heading.get_text(" ", strip=True)
    text = re.sub(r"\s+", " ", text).strip()
    match = re.search(r"(?:\(|\b)(19\d{2}|20\d{2})(?:\)|\b)", text)
    if not match:
        return None, "missing_detail_year"
    year = int(match.group(1))
    if expected_year is not None and year != expected_year:
        return None, "year_mismatch"
    title = re.sub(r"\s*\(?"+re.escape(match.group(1))+r"\)?\s*$", "", text).strip(" -|:")
    if not title or len(title) > 180:
        return None, "invalid_title"
    # Avoid cataloging a site landing page or generic error as a movie.
    if title.casefold() in {"lk21", "layarkaca21", "home", "not found"}:
        return None, "generic_heading"
    synopsis = ""
    for selector in (
        ".mvic-desc .desc", ".mvic-desc p", ".desc .entry-content",
        ".description p", ".synopsis", ".sinopsis", ".wp-content p",
        ".entry-content p", 'meta[name="description"]',
        'meta[property="og:description"]',
    ):
        node = soup.select_one(selector)
        if node is None:
            continue
        value = node.get("content", "") if node.name == "meta" else node.get_text(" ", strip=True)
        value = re.sub(r"\s+", " ", value).strip()
        if len(value) >= 35:
            synopsis = value[:3000]
            break
    poster = poster_from_detail(html, url) or ""
    if not poster or not synopsis:
        return None, "missing_poster_or_synopsis"
    return {"title": title, "year": year, "url": url, "type": "movie",
            "poster_url": poster, "synopsis": synopsis,
            "metadata_status": FINAL}, "verified"


def queue_from_sitemaps(catalog, files, start_year, end_year):
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Katalog tidak valid/kosong")
    by_url = {str(row.get("url", "")).rstrip("/").lower(): row
              for row in items if isinstance(row, dict)}
    names = {identity(row.get("title", ""), row.get("year", "")) for row in items
             if isinstance(row, dict) and row.get("type") in ("movie", "tv", "series")
             and row.get("metadata_status") != PROVISIONAL}
    queue, seen = [], set()
    stats = {"sitemap_urls": 0, "skipped_catalog": 0, "skipped_ambiguous": 0,
             "provisional_existing": 0, "new_url": 0}
    for path in files:
        for raw in load_sitemap(path):
            stats["sitemap_urls"] += 1
            url = clean_url(raw)
            if not url or url in seen:
                stats["skipped_ambiguous"] += 1
                continue
            seen.add(url)
            entry = by_url.get(url)
            if entry is not None:
                if entry.get("metadata_status") != PROVISIONAL:
                    stats["skipped_catalog"] += 1
                    continue
                expected = int(entry["year"]) if str(entry.get("year", "")).isdigit() else None
                if expected is None or not start_year <= expected <= end_year:
                    stats["skipped_ambiguous"] += 1
                    continue
                stats["provisional_existing"] += 1
                queue.append({"url": url, "year": expected, "mode": "update"})
                continue
            guessed = parse_slug(url, start_year, end_year)
            if guessed is None:
                stats["skipped_ambiguous"] += 1
                continue
            if identity(guessed["title"], guessed["year"]) in names:
                stats["skipped_catalog"] += 1
                continue
            stats["new_url"] += 1
            queue.append({"url": url, "year": guessed["year"], "mode": "add"})
    return queue, stats


def run(args):
    files = [args.sitemap_dir / f"sitemap-posts-{n}.xml" for n in range(1, 9)]
    missing = [str(p) for p in files if not p.is_file()]
    if missing:
        raise SystemExit("Sitemap lokal belum lengkap: " + ", ".join(missing))
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    queue, stats = queue_from_sitemaps(catalog, files, args.start_year, args.end_year)
    print(f"Indeks sitemap: {stats}; antrian detail: {len(queue)}", flush=True)
    state = {"completed": {}, "results": {}, "errors": []}
    if args.state.is_file():
        state = json.loads(args.state.read_text(encoding="utf-8-sig"))
    completed = state.setdefault("completed", {})
    results = state.setdefault("results", {})
    errors = state.setdefault("errors", [])
    def save():
        write_json(args.state, state)
        write_json(args.output, {"source": "local_sitemap_visible_chromium",
                                 "checked": len(completed),
                                 "verified": list(results.values()),
                                 "verified_count": len(results),
                                 "errors": errors, "applied": False})
    save()
    remaining = [x for x in queue if x["url"] not in completed]
    if not remaining:
        print("Tidak ada URL baru untuk diperiksa. Katalog belum diubah.", flush=True)
        return
    processed = 0
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page(viewport={"width": 1280, "height": 820})
        try:
            robots = load_robots(page)
            pacer = NavigationPacer(args.delay)
            for target in remaining:
                url = target["url"]
                print(f"[{processed + 1}/{args.limit or 'semua'}] {url}", flush=True)
                try:
                    html = browse(page, robots, url, pacer=pacer)
                except RuntimeError as exc:
                    errors.append({"url": url, "error": str(exc)})
                    save()
                    print("BERHENTI (akses/navigasi):", str(exc), flush=True)
                    break
                # Reject redirects even when the destination is on the same host.
                if page.url.rstrip("/") != url.rstrip("/"):
                    status = "redirect_mismatch"
                    row = None
                else:
                    row, status = detail_metadata(html, url, target["year"])
                if row is not None:
                    row["mode"] = target["mode"]
                    results[url] = row
                completed[url] = status
                processed += 1
                print(f"  Status: {status} | terverifikasi: {len(results)}", flush=True)
                save()
                if args.limit and processed >= args.limit:
                    break
        finally:
            browser.close()
    print(f"Selesai sesi: {processed} URL | total terverifikasi: {len(results)}. "
          "Katalog belum diubah.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sitemap-dir", type=Path, default=SITEMAPS)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--state", type=Path, default=STATE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--delay", type=float, default=2.0)
    parser.add_argument("--start-year", type=int, default=1900)
    parser.add_argument("--end-year", type=int, default=2027)
    args = parser.parse_args()
    if args.limit < 0 or args.delay < 2 or args.start_year > args.end_year:
        parser.error("limit >= 0, delay >= 2, start-year <= end-year")
    run(args)


if __name__ == "__main__":
    main()
