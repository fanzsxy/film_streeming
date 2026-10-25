"""Collect public series listing metadata in a separate dataset from movies.

Usage: py crawler/series_catalog.py --pages 20 --delay 3
Only follows observed same-host next-page links; stops on denied access.
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

BASE = "https://tv9.nontondrama.my"
START = BASE + "/latest-series"
ROOT = Path("crawler/data")
STORE = ROOT / "series_catalog.json"
CSV = ROOT / "series_catalog.csv"
STATE = ROOT / "series_state.json"
YEAR = re.compile(r"(?<!\d)(?:19|20)\d{2}(?!\d)")
PAGE = re.compile(r"/latest-series/page/(\d+)/?$")


def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return default


def cards(html, current):
    soup = BeautifulSoup(html, "html.parser")
    result = {}
    for a in soup.select("a[href]"):
        url = urljoin(current, a.get("href", ""))
        u = urlparse(url)
        if u.scheme != "https" or u.hostname != urlparse(BASE).hostname:
            continue
        if u.path in ("/", "/latest-series", "/search") or "/page/" in u.path:
            continue
        card = (a.find_parent(["article", "li"]) or
                a.find_parent(class_=re.compile(r"item|series|poster|film", re.I)) or a)
        image = card.select_one("img")
        heading = card.select_one("h2,h3,h4,.title,.poster-title")
        title = ((heading.get_text(" ", strip=True) if heading else "")
                 or a.get("title", "") or a.get_text(" ", strip=True)
                 or (image.get("alt", "") if image else "")).strip()
        if not title or len(title) > 180 or (image is None and heading is None):
            continue
        year = YEAR.search(u.path.rstrip("/").split("/")[-1]) or YEAR.search(card.get_text(" ", strip=True))
        if not year:
            continue
        result[url] = {"title": title, "year": year.group(),
                       "url": url, "type": "series"}
    return result


def next_page(html, current):
    soup = BeautifulSoup(html, "html.parser")
    match = PAGE.search(urlparse(current).path)
    number = int(match.group(1)) if match else 1
    for a in soup.select("a[href]"):
        url = urljoin(current, a.get("href", ""))
        u = urlparse(url)
        m = PAGE.fullmatch(u.path)
        if u.scheme == "https" and u.hostname == urlparse(BASE).hostname and m:
            if int(m.group(1)) == number + 1:
                return url
    return None


def save(items, next_url, completed=False):
    ROOT.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    STATE.write_text(json.dumps({"next_url": next_url, "completed": completed}, indent=2) + "\n", encoding="utf-8")
    try:
        with CSV.open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=["title", "year", "url", "type"])
            writer.writeheader()
            writer.writerows(sorted(items.values(), key=lambda item: (item["title"].casefold(), item["year"])))
    except PermissionError:
        print("series_catalog.csv is open in Excel; JSON and checkpoint are safe. Close Excel before rerunning.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3)
    args = parser.parse_args()
    if not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("--pages must be 1-100; --delay must be >= 2")
    items = load(STORE, {})
    state = load(STATE, {})
    if state.get("completed"):
        print(f"Series listing already completed through last linked page. {len(items)} unique series saved.")
        return
    url = state.get("next_url", START)
    visited = set()
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for _ in range(args.pages):
                if url in visited:
                    print("Pagination loop; stopped.")
                    break
                visited.add(url)
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                except Exception as e:
                    print(f"Page load failed: {type(e).__name__}; stopped.")
                    break
                if not response or response.status >= 400:
                    print(f"HTTP {response.status if response else 'unknown'}; stopped without bypassing.")
                    break
                page.wait_for_timeout(900)
                html = page.content()
                if re.search(r"captcha|verify you are human|access denied", html, re.I):
                    print("Verification required; stopped.")
                    break
                found = cards(html, url)
                if not found:
                    print("No series cards found; check layout. Stopped.")
                    break
                before = len(items)
                items.update(found)
                following = next_page(html, url)
                save(items, following or url, completed=not bool(following))
                print(f"{url}: {len(found)} cards; {len(items)-before} new; total series {len(items)}")
                if not following:
                    print("No next-page link on this series listing; stopped.")
                    break
                url = following
                time.sleep(args.delay)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
