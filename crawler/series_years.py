"""Collect series metadata from observed year-category pages without resetting latest-series progress.

Run: py crawler/series_years.py --year 2025 --pages 10 --delay 3
If year URLs differ, pass the actual link from the site's Tahun menu with --url.
The original 1,200-series catalog and latest-series checkpoint are preserved.
"""
import argparse
import csv
import json
import re
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

from series_catalog import BASE, ROOT, STORE, CSV, cards, load

STATE = ROOT / "series_years_state.json"
HOST = urlparse(BASE).hostname


def next_page(html, current, category_path):
    """Only follow a visible, consecutive pagination link for this same category."""
    path = urlparse(current).path.rstrip("/")
    match = re.fullmatch(re.escape(category_path) + r"/page/(\d+)", path)
    number = int(match.group(1)) if match else 1
    for anchor in BeautifulSoup(html, "html.parser").select("a[href]"):
        candidate = urljoin(current, anchor.get("href", ""))
        parsed = urlparse(candidate)
        match = re.fullmatch(re.escape(category_path) + r"/page/(\d+)/?", parsed.path)
        if (parsed.scheme == "https" and parsed.hostname == HOST
                and match and int(match.group(1)) == number + 1):
            return candidate
    return None


def save(items, state):
    ROOT.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    try:
        with CSV.open("w", newline="", encoding="utf-8-sig") as file:
            writer = csv.DictWriter(file, fieldnames=["title", "year", "url", "type"])
            writer.writeheader()
            writer.writerows(sorted(items.values(), key=lambda x: (x["title"].casefold(), x["year"])))
    except PermissionError:
        print("CSV locked by Excel. JSON and year checkpoint saved; close Excel to update CSV.")


def main():
    parser = argparse.ArgumentParser(description="Series year-category metadata collector")
    parser.add_argument("--year", required=True, type=int, help="e.g. 2025")
    parser.add_argument("--url", help="Exact series year-category URL copied from the website")
    parser.add_argument("--pages", type=int, default=10)
    parser.add_argument("--delay", type=float, default=3)
    args = parser.parse_args()
    if not 1900 <= args.year <= 2100 or not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("year must be 1900-2100, pages 1-100, delay >= 2")
    start = args.url or f"{BASE}/year/{args.year}"
    parsed = urlparse(start)
    path = parsed.path.rstrip("/")
    if (parsed.scheme != "https" or parsed.hostname != HOST
            or parsed.query or parsed.fragment or not re.fullmatch(r"/[A-Za-z0-9/_-]+", path)
            or "/page/" in path):
        parser.error("--url must be an HTTPS year-category URL on tv9.nontondrama.my without /page/N")
    items = load(STORE, {})
    state = load(STATE, {})
    categories = state.setdefault("categories", {})
    key = str(args.year)
    entry = categories.get(key, {})
    if entry.get("completed"):
        print(f"Year {key} is marked complete. Total saved: {len(items)}")
        return
    if entry and entry.get("start") != start:
        parser.error("Saved year URL differs; review series_years_state.json before changing categories")
    url = entry.get("next_url", start)
    seen = set()
    print(f"Year {key}: starting {url}; existing unique series: {len(items)}")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for _ in range(args.pages):
                if url in seen:
                    print("Pagination loop; stopped.")
                    break
                seen.add(url)
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                except Exception as exc:
                    print(f"Navigation failed ({type(exc).__name__}); stopped.")
                    break
                if not response or response.status >= 400:
                    print(f"Page unavailable (HTTP {response.status if response else 'unknown'}); stopped.")
                    break
                if urlparse(page.url).hostname != HOST:
                    print("Redirected away from source host; stopped.")
                    break
                page.wait_for_timeout(900)
                html = page.content()
                if re.search(r"captcha|verify you are human|access denied", html, re.I):
                    print("Verification requested; stopped.")
                    break
                found = cards(html, page.url)
                # Require at least one matching-year card before saving.
                if not found or not any(x["year"] == key for x in found.values()):
                    print("No matching year series cards found; check the year URL; stopped.")
                    break
                before = len(items)
                items.update(found)
                following = next_page(html, page.url, path)
                categories[key] = {"start": start, "next_url": following or url,
                                   "completed": not bool(following)}
                save(items, state)
                print(f"{url}: {len(found)} cards; {len(items)-before} new; total {len(items)}")
                if not following or following in seen:
                    print("No next linked page in this year category; stopped.")
                    break
                url = following
                time.sleep(args.delay)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
