"""Diagnose the remaining movie poster gaps from their known catalog URLs.

Read the completed direct-URL checkpoint first; optionally inspect a small
number of pages again in visible Chromium. This is READ-ONLY: report observed
headings, OpenGraph/meta image and detail poster candidates, never auto-assign
unverified artwork or change catalog metadata.
"""
import argparse
import json
from collections import Counter
from pathlib import Path
from urllib.parse import urljoin

from bs4 import BeautifulSoup

from tools.audit_catalog_completeness import good_poster
from tools.local_lk21_browser_search import browse, load_robots, NavigationPacer
from tools.local_lk21_gap_match import validated, detail_title_year, poster_from_detail
from tools.recheck_redirect_posters import ALL_STATE
from tools.repair_catalog_missing_posters import CATALOG, write_json

REPORT = Path("crawler/data/remaining_movie_poster_diagnostics.json")


def summary_rows(catalog, state):
    completed = state.get("checked") or {}
    rows = []
    for row in catalog.get("items") or []:
        if (not isinstance(row, dict) or row.get("type") != "movie"
                or good_poster(row.get("poster_url"))):
            continue
        url = str(row.get("url") or "").rstrip("/")
        if not validated(url):
            continue
        old = completed.get(url)
        rows.append({"title": row.get("title"), "year": row.get("year"),
                     "url": url, "status": old.get("status", "not_checked")
                     if isinstance(old, dict) else "not_checked",
                     "final_url": old.get("final_url", "")
                     if isinstance(old, dict) else ""})
    return rows


def inspect_detail(html, final_url):
    soup = BeautifulSoup(html, "html.parser")
    title, year = detail_title_year(html)
    h1 = soup.select_one("h1")
    metas = {}
    for property_name in ("og:title", "og:image", "og:type"):
        node = soup.select_one('meta[property="' + property_name + '"]')
        if node:
            metas[property_name] = (node.get("content") or "")[:500]
    images = []
    # Keep all image candidates as observations, not as verified posters.
    for node in soup.select("article img, .poster img, .movie img, .film img, img[itemprop=image]"):
        raw = (node.get("data-src") or node.get("data-original")
               or node.get("src") or "").strip()
        if raw and not raw.startswith("data:"):
            url = urljoin(final_url, raw)
            if url not in images:
                images.append(url)
        if len(images) >= 8:
            break
    poster = poster_from_detail(html, final_url)
    return {"heading": h1.get_text(" ", strip=True)[:300] if h1 else "",
            "parsed_title": title, "parsed_year": year,
            "meta": metas, "detail_poster": poster if good_poster(poster) else None,
            "image_candidates": images}


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    checkpoint = (json.loads(args.state.read_text(encoding="utf-8-sig"))
                  if args.state.is_file() else {})
    rows = summary_rows(catalog, checkpoint)
    counts = Counter(row["status"] for row in rows)
    print("POSTER MOVIE TERSISA:", len(rows))
    print("STATUS PEMERIKSAAN URL LANGSUNG:")
    for status, count in counts.most_common():
        print(f"  {status}: {count}")
    inspect_rows = [row for row in rows
                    if row["status"] in args.status] if args.status else rows
    if args.inspect:
        from playwright.sync_api import sync_playwright, Error as BrowserError
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            page = browser.new_page(viewport={"width": 1280, "height": 820})
            try:
                robots = load_robots(page)
                pacer = NavigationPacer(args.delay)
                for number, row in enumerate(inspect_rows[:args.inspect], 1):
                    print(f"[{number}/{min(args.inspect, len(inspect_rows))}] "
                          f"{row['title']} ({row['year']})", flush=True)
                    try:
                        html = browse(page, robots, row["url"], pacer=pacer)
                        result = inspect_detail(html, page.url)
                        row["inspection"] = result
                        print("  Heading:", result["heading"])
                        print("  Tahun heading:", result["parsed_year"],
                              "| tahun katalog:", row["year"])
                        print("  Detail poster:", result["detail_poster"])
                        print("  OG image:", result["meta"].get("og:image"))
                        print("  Kandidat gambar:", len(result["image_candidates"]))
                    except BrowserError as exc:
                        reason = str(exc).splitlines()[0][:250]
                        row["inspection"] = {"error": reason}
                        print("  Browser:", reason, flush=True)
                        if "net::ERR_ABORTED" not in reason:
                            break
                    except RuntimeError as exc:
                        row["inspection"] = {"error": str(exc)[:250]}
                        print("  Dihentikan:", str(exc), flush=True)
                        break
            finally:
                browser.close()
    write_json(args.report, {"remaining": len(rows), "by_status": dict(counts),
                             "rows": rows})
    print("Laporan:", args.report)
    print("READ ONLY: tidak mengubah katalog atau memasang poster.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--state", type=Path, default=ALL_STATE)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--inspect", type=int, default=0,
                   help="Number of direct URL pages to open in visible Chromium")
    p.add_argument("--status", action="append", default=[],
                   help="Limit fresh inspection by saved direct URL status (repeatable)")
    p.add_argument("--delay", type=float, default=2)
    args = p.parse_args()
    if args.inspect < 0 or args.delay < 2:
        p.error("--inspect >= 0 and --delay >= 2 required")
    run(args)


if __name__ == "__main__":
    main()
