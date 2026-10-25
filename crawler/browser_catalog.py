"""Local, metadata-only browser collection from accessible catalog pages.

Usage:
  pip install playwright beautifulsoup4
  python -m playwright install chromium
  python crawler/browser_catalog.py --pages 20

Does not conceal automation or bypass access checks. Stops on access denial.
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

BASE = "https://tv12.lk21official.cc"
STORE = Path("crawler/data/browser_catalog.json")
CSV = Path("crawler/data/browser_catalog.csv")
STATE = Path("crawler/data/browser_state.json")
YEAR = re.compile(r"(?<!\d)(?:19|20)\d{2}(?!\d)")


def load_json(path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return fallback


def cards_from_html(html, current):
    soup = BeautifulSoup(html, "html.parser")
    found = {}
    for a in soup.select("a[href]"):
        href = urljoin(current, a.get("href", ""))
        u = urlparse(href)
        if u.scheme != "https" or u.hostname != urlparse(BASE).hostname:
            continue
        if not u.path or u.path in ("/", "/latest", "/search") or "/page/" in u.path:
            continue
        card = a.find_parent(["article", "li"]) or a.find_parent(
            class_=re.compile(r"item|movie|poster|film", re.I)) or a
        image = card.select_one("img")
        heading = card.select_one("h2,h3,h4,.title,.poster-title")
        title = ((heading.get_text(" ", strip=True) if heading else "")
                 or a.get("title", "") or a.get_text(" ", strip=True)
                 or (image.get("alt", "") if image else "")).strip()
        if not title or len(title) > 180:
            continue
        slug = u.path.rstrip("/").split("/")[-1]
        year = YEAR.search(slug) or YEAR.search(card.get_text(" ", strip=True))
        if not year:
            continue
        # Require movie-card evidence, avoid menu/footer navigation.
        if image is None and heading is None:
            continue
        found[href] = {"title": title, "year": year.group(),
                       "url": href, "type": "movie"}
    return found


def save(items, next_url):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    STATE.write_text(json.dumps({"next_url": next_url}, indent=2) + "\n", encoding="utf-8")
    with CSV.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=["title", "year", "url", "type"])
        writer.writeheader()
        writer.writerows(sorted(items.values(), key=lambda x: (x["title"].lower(), x["year"])))


def next_page(html, current):
    """Follow actual numbered pagination links, not guessed URL patterns."""
    soup = BeautifulSoup(html, "html.parser")
    current_path = urlparse(current).path.rstrip("/")
    page_match = re.search(r"/page/(\\d+)$", current_path)
    current_number = int(page_match.group(1)) if page_match else 1
    candidates = []
    for a in soup.select("a[href]"):
        href = urljoin(current, a.get("href", ""))
        parsed = urlparse(href)
        if parsed.hostname != urlparse(BASE).hostname:
            continue
        next_match = re.fullmatch(r"/latest/page/(\\d+)/?", parsed.path)
        if not next_match:
            continue
        number = int(next_match.group(1))
        if number == current_number + 1:
            candidates.append(href)
    # The page displays numbered links (1, 2, 3, ») rather than a
    # link styled .next. Only follow a next-page URL present in the DOM.
    return candidates[0] if candidates else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3.0)
    args = parser.parse_args()
    if args.pages < 1 or args.pages > 100 or args.delay < 2:
        parser.error("--pages must be 1-100 and --delay must be >= 2")
    items = load_json(STORE, {})
    state = load_json(STATE, {})
    url = state.get("next_url", BASE + "/latest")
    visited = set()
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for _ in range(args.pages):
                if url in visited:
                    print("Pagination loop detected; stopped.")
                    break
                visited.add(url)
                response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                if response is None or response.status in (401, 403, 429):
                    print(f"Access denied/limited: {response.status if response else 'unknown'}")
                    break
                if response.status >= 400:
                    print(f"HTTP {response.status}; stopped.")
                    break
                page.wait_for_timeout(900)
                html = page.content()
                if re.search(r"captcha|verify you are human|access denied", html, re.I):
                    print("Site requests verification; stopped without attempting to bypass.")
                    break
                new = cards_from_html(html, url)
                if not new:
                    print("No movie cards found; check HTML layout, stopped.")
                    break
                items.update(new)
                following = next_page(html, url)
                save(items, following or url)
                print(f"{url}: {len(new)} cards; total unique {len(items)}")
                if not following or following in visited:
                    print("No supported next-page link. Stopped.")
                    break
                url = following
                time.sleep(args.delay)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
