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


def save(items, category, next_url):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    state = load_json(STATE, {})
    # Preserve the old latest-page checkpoint and any other category state.
    if category == "latest":
        state["next_url"] = next_url
    else:
        state.setdefault("categories", {})[category] = next_url
    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    try:
        with CSV.open("w", newline="", encoding="utf-8-sig") as file:
            writer = csv.DictWriter(file, fieldnames=["title", "year", "url", "type"])
            writer.writeheader()
            writer.writerows(sorted(items.values(), key=lambda x: (x["title"].lower(), x["year"])))
    except PermissionError:
        print("CSV is locked (likely Excel). JSON and progress saved; close Excel before the next run.")


def next_page(html, current, category):
    """Follow numbered links observed on the SAME catalog category."""
    soup = BeautifulSoup(html, "html.parser")
    path = urlparse(current).path.rstrip("/")
    m = re.search(r"/page/(\d+)$", path)
    current_number = int(m.group(1)) if m else 1
    base_path = "/latest" if category == "latest" else f"/year/{category}"
    found = []
    for a in soup.select("a[href]"):
        href = urljoin(current, a.get("href", ""))
        parsed = urlparse(href)
        if parsed.scheme != "https" or parsed.hostname != urlparse(BASE).hostname:
            continue
        match = re.fullmatch(re.escape(base_path) + r"/page/(\d+)/?", parsed.path)
        if match and int(match.group(1)) == current_number + 1:
            found.append(href)
    if not found:
        print(f"No next-page link found for {category} on page {current_number}.")
    return found[0] if found else None


def start_url(category, state):
    if category == "latest":
        return state.get("next_url", BASE + "/latest")
    return state.get("categories", {}).get(category, BASE + f"/year/{category}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=int, default=20, help="Maximum pages per selected category")
    parser.add_argument("--delay", type=float, default=3.0)
    parser.add_argument("--year", type=int, help="Collect a single year, e.g. 2025")
    parser.add_argument("--years", help="Comma-separated list of years, e.g. 2026,2025,2024")
    args = parser.parse_args()
    if not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("--pages must be 1-100 and --delay must be >= 2")
    if args.year and args.years:
        parser.error("Choose either --year or --years")
    categories = ["latest"]
    if args.year or args.years:
        try:
            years = [args.year] if args.year else [int(x.strip()) for x in args.years.split(",")]
        except ValueError:
            parser.error("--years must contain comma-separated years")
        if not years or any(y < 1900 or y > 2100 for y in years):
            parser.error("Year must be between 1900 and 2100")
        categories = list(dict.fromkeys(str(y) for y in years))

    items = load_json(STORE, {})
    state = load_json(STATE, {})
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for category in categories:
                url = start_url(category, state)
                visited = set()
                print(f"Collecting {category}; start: {url}; existing unique: {len(items)}")
                for _ in range(args.pages):
                    if url in visited:
                        print("Pagination loop detected; stopped.")
                        break
                    visited.add(url)
                    try:
                        response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                    except Exception as exc:
                        print(f"Page unavailable ({type(exc).__name__}); stopped.")
                        break
                    if response is None or response.status in (401, 403, 429):
                        print(f"Access denied/limited: {response.status if response else 'unknown'}")
                        break
                    if response.status >= 400:
                        print(f"HTTP {response.status}; stopped.")
                        break
                    page.wait_for_timeout(900)
                    html = page.content()
                    if re.search(r"captcha|verify you are human|access denied", html, re.I):
                        print("Site requests verification; stopped without bypassing.")
                        break
                    new = cards_from_html(html, url)
                    if not new:
                        print("No movie cards found; stopped.")
                        break
                    items.update(new)
                    following = next_page(html, url, category)
                    save(items, category, following or url)
                    print(f"{url}: {len(new)} cards; total unique {len(items)}")
                    if not following or following in visited:
                        print(f"{category} completed at the last accessible linked page.")
                        break
                    url = following
                    time.sleep(args.delay)
                state = load_json(STATE, {})
        finally:
            browser.close()


if __name__ == "__main__":
    main()
