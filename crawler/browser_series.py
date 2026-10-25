"""Collect public series catalog metadata using visible Playwright Chromium.

Run: py crawler/browser_series.py --pages 20 --delay 3
Series data/checkpoint are separate from movie data. No player/video extraction.
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

from browser_catalog import BASE, YEAR, load_json

START = BASE + "/latest-series"
STORE = Path("crawler/data/browser_series.json")
CSV = Path("crawler/data/browser_series.csv")
STATE = Path("crawler/data/browser_series_state.json")


def series_from_html(html, current):
    soup = BeautifulSoup(html, "html.parser")
    found = {}
    for a in soup.select("a[href]"):
        href = urljoin(current, a.get("href", ""))
        u = urlparse(href)
        if u.scheme != "https" or u.hostname != urlparse(BASE).hostname:
            continue
        if not u.path or u.path in ("/", "/latest-series", "/search") or "/page/" in u.path:
            continue
        card = a.find_parent(["article", "li"]) or a.find_parent(
            class_=re.compile(r"item|movie|poster|film|series", re.I)) or a
        image = card.select_one("img")
        heading = card.select_one("h2,h3,h4,.title,.poster-title")
        if image is None and heading is None:
            continue
        title = ((heading.get_text(" ", strip=True) if heading else "")
                 or a.get("title", "") or a.get_text(" ", strip=True)
                 or (image.get("alt", "") if image else "")).strip()
        if not title or len(title) > 180:
            continue
        slug = u.path.rstrip("/").split("/")[-1]
        match = YEAR.search(slug) or YEAR.search(card.get_text(" ", strip=True))
        if not match:
            continue
        found[href] = {"title": title, "year": match.group(), "url": href, "type": "series"}
    return found


def next_series_page(html, current):
    soup = BeautifulSoup(html, "html.parser")
    path = urlparse(current).path.rstrip("/")
    page_match = re.fullmatch(r"/latest-series/page/(\d+)", path)
    number = int(page_match.group(1)) if page_match else 1
    for a in soup.select("a[href]"):
        href = urljoin(current, a.get("href", ""))
        parsed = urlparse(href)
        if parsed.scheme != "https" or parsed.hostname != urlparse(BASE).hostname:
            continue
        candidate = re.fullmatch(r"/latest-series/page/(\d+)/?", parsed.path)
        if candidate and int(candidate.group(1)) == number + 1:
            return href
    return None


def save(items, next_url):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    STATE.write_text(json.dumps({"next_url": next_url}, indent=2) + "\n", encoding="utf-8")
    try:
        with CSV.open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=["title", "year", "url", "type"])
            writer.writeheader()
            writer.writerows(sorted(items.values(), key=lambda x: (x["title"].casefold(), x["year"])))
    except PermissionError:
        print("Series CSV is open in Excel. JSON and state saved; close Excel to export CSV on next run.")


def main():
    parser = argparse.ArgumentParser(description="Local LK21 series metadata collector")
    parser.add_argument("--pages", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3.0)
    args = parser.parse_args()
    if not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("--pages must be 1-100 and --delay must be >= 2")
    items = load_json(STORE, {})
    url = load_json(STATE, {}).get("next_url", START)
    seen = set()
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for _ in range(args.pages):
                if url in seen:
                    print("Pagination loop; stopped.")
                    break
                seen.add(url)
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                except Exception as e:
                    print(f"Navigation failed ({type(e).__name__}); stopped.")
                    break
                if response is None or response.status >= 400:
                    print(f"Page unavailable / access limited: {response.status if response else 'unknown'}; stopped.")
                    break
                page.wait_for_timeout(900)
                html = page.content()
                if re.search(r"captcha|verify you are human|access denied", html, re.I):
                    print("Verification requested; stopped without bypass.")
                    break
                cards = series_from_html(html, url)
                if not cards:
                    print("No series cards found; stopped. Check page markup.")
                    break
                items.update(cards)
                following = next_series_page(html, url)
                save(items, following or url)
                print(f"{url}: {len(cards)} cards; total unique series {len(items)}")
                if not following or following in seen:
                    print("No linked next series page; stopped.")
                    break
                url = following
                time.sleep(args.delay)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
