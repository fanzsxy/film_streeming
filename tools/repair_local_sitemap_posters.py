"""Repair only missing movie posters in saved local sitemap Chromium results.

PR #165 crawler is intentionally unchanged. No TMDB and no title searches.
Default preview is completely offline; --apply uses one visible Chromium to
revisit only missing-poster URLs. Successful fixes update both saved results and
the original crawler checkpoint so future crawler runs cannot erase the repair.
Never invent an image, use a generic gate image, or bypass a restricted page.
"""
import argparse
import json
import os
import re
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from bs4 import BeautifulSoup
from tools.import_local_lk21_sitemaps import CATALOG, clean_url, identity
from tools.local_lk21_browser_search import NavigationPacer, browse, load_robots
from tools.local_lk21_gap_match import poster_url
from tools.local_lk21_sitemap_details import OUTPUT, STATE

GATE = re.compile(r"materi khusus dewasa|login gmail anda|konfirmasi umur", re.I)
IMAGE_SELECTORS = (
    ('.poster img', 'data-src'), ('.poster img', 'data-original'),
    ('.poster img', 'src'), ('.mvic-desc img', 'data-src'),
    ('.mvic-desc img', 'src'), ('.info img', 'data-src'),
    ('.info img', 'src'), ('article img', 'data-src'),
    ('article img', 'src'), ('meta[property="og:image"]', 'content'),
    ('meta[name="twitter:image"]', 'content'),
)


def missing_rows(document):
    found = {}
    for field in ("verified", "age_restricted"):
        for row in document.get(field) or []:
            if not isinstance(row, dict) or row.get("poster_url"):
                continue
            url = clean_url(row.get("url"))
            if url and url == str(row.get("url")).rstrip("/"):
                found.setdefault(url, row)
    return found


def known_poster(row, catalog):
    items = catalog.get("items", [])
    url = clean_url(row.get("url"))
    title_id = identity(row.get("title"), row.get("year"))
    for item in items:
        if not isinstance(item, dict):
            continue
        same_url = str(item.get("url", "")).rstrip("/").lower() == url.lower()
        same_name = identity(item.get("title"), item.get("year")) == title_id
        if not (same_url or (title_id[0] and same_name)):
            continue
        poster = poster_url(item.get("poster_url"), row["url"])
        if poster and not (urlparse(poster).hostname or "").endswith(".invalid"):
            return poster
    return None


def extract_detail_poster(html, url, row):
    soup = BeautifulSoup(html, "html.parser")
    body = soup.get_text(" ", strip=True)
    if GATE.search(body):
        return None, "age_gate"
    heading = soup.select_one("h1")
    if heading is None:
        return None, "missing_heading"
    heading_text = heading.get_text(" ", strip=True)
    match = re.search(r"\b(19\d{2}|20\d{2})\b", heading_text)
    if not match or int(match.group(1)) != int(row["year"]):
        return None, "year_mismatch"
    # Name can differ from URL, but must agree with original saved film metadata.
    title = re.sub(r"\s*\(?" + re.escape(match.group(1)) + r"\)?\s*$", "", heading_text).strip()
    if identity(title, row["year"])[0] != identity(row.get("title"), row["year"])[0]:
        return None, "title_mismatch"
    for selector, attr in IMAGE_SELECTORS:
        node = soup.select_one(selector)
        if not node:
            continue
        poster = poster_url(node.get(attr), url)
        if not poster:
            continue
        path = urlparse(poster).path.lower()
        if any(tag in path for tag in ("logo", "placeholder", "avatar", "favicon", "default", "no-poster", "no-image")):
            continue
        if path.endswith((".svg", ".gif", ".ico")):
            continue
        return poster, "found"
    return None, "no_poster"


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".poster_repair.tmp")
    try:
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def backup(path):
    name = path.stem + ".backup_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f") + path.suffix
    dst = path.with_name(name)
    dst.write_bytes(path.read_bytes())
    return dst


def apply_poster(document, state, url, poster):
    updated = False
    for field in ("verified", "age_restricted"):
        for row in document.get(field) or []:
            if isinstance(row, dict) and str(row.get("url", "")).rstrip("/") == url:
                if not row.get("poster_url"):
                    row["poster_url"] = poster
                    updated = True
    # The original PR #165 crawler reconstructs output from state["results"].
    # Keep it synchronized to prevent a subsequent crawl overwriting repairs.
    saved = state.get("results", {}).get(url)
    if isinstance(saved, dict) and not saved.get("poster_url"):
        saved["poster_url"] = poster
    return updated


def run(args):
    doc = json.loads(args.results.read_text(encoding="utf-8-sig"))
    state = json.loads(args.state.read_text(encoding="utf-8-sig"))
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    missing = missing_rows(doc)
    print(f"Poster kosong dalam hasil: {len(missing)}", flush=True)
    if not missing:
        return
    local_matches = sum(bool(known_poster(row, catalog)) for row in missing.values())
    print(f"Poster yang mungkin dapat dipulihkan dari katalog lokal: {local_matches}", flush=True)
    if not args.apply:
        for row in missing.values():
            print(f"  {row.get('title')} ({row.get('year')}): {row['url']}", flush=True)
        print("DRY RUN: tidak ada file yang diubah. --apply untuk repair.", flush=True)
        return
    if args.limit == 0:
        targets = list(missing.items())
    else:
        targets = list(missing.items())[:args.limit]
    print("Memproses hanya poster kosong, bukan 194 film ulang.", flush=True)
    print(f"Backup hasil: {backup(args.results)}", flush=True)
    print(f"Backup checkpoint: {backup(args.state)}", flush=True)
    repaired, unresolved = 0, []
    # Reuse only existing known poster metadata before opening Chrome.
    unresolved_targets = []
    for url, row in targets:
        poster = known_poster(row, catalog)
        if poster:
            if apply_poster(doc, state, url, poster):
                repaired += 1
                atomic_json(args.results, doc)
                atomic_json(args.state, state)
                print(f"  Diperbaiki dari katalog: {row['title']}", flush=True)
        else:
            unresolved_targets.append((url, row))
    if unresolved_targets:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            page = browser.new_page(viewport={"width": 1280, "height": 820})
            try:
                robots = load_robots(page)
                pacer = NavigationPacer(args.delay)
                for url, row in unresolved_targets:
                    print(f"  Memeriksa: {row.get('title')} ({row.get('year')})", flush=True)
                    try:
                        html = browse(page, robots, url, pacer=pacer)
                    except RuntimeError as exc:
                        unresolved.append({"url": url, "reason": str(exc)})
                        print("Akses ditolak/gagal, berhenti:", str(exc), flush=True)
                        break
                    if page.url.rstrip("/") != url:
                        poster, reason = None, "redirect"
                    else:
                        poster, reason = extract_detail_poster(html, url, row)
                    if poster and apply_poster(doc, state, url, poster):
                        repaired += 1
                        atomic_json(args.results, doc)
                        atomic_json(args.state, state)
                        print("    Poster ditemukan.", flush=True)
                    else:
                        unresolved.append({"url": url, "reason": reason})
                        print("    Belum ada poster:", reason, flush=True)
            finally:
                browser.close()
    report = {"repaired_this_run": repaired, "remaining": len(missing_rows(doc)),
              "unresolved_this_run": unresolved}
    atomic_json(args.report, report)
    print(f"Selesai. Diperbaiki: {repaired}, poster masih kosong: {report['remaining']}. "
          f"Laporan: {args.report}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=OUTPUT)
    parser.add_argument("--state", type=Path, default=STATE)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--report", type=Path,
                        default=Path("crawler/data/missing_sitemap_posters_report.json"))
    parser.add_argument("--limit", type=int, default=0,
                        help="Max poster gaps to check; 0 means all (default)")
    parser.add_argument("--delay", type=float, default=2.0)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.delay < 2 or args.limit < 0:
        parser.error("delay >= 2 and limit >= 0 required")
    run(args)


if __name__ == "__main__":
    main()
