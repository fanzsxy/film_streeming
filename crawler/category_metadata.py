"""Collect poster/rating/genre/duration from year listing cards; preserve detail cache.

Run from repository root:
  py crawler/category_metadata.py --year 2024 --pages 5 --delay 3
  py crawler/category_metadata.py --years 2026,2025,2024 --pages 100 --delay 3

Only metadata visibly available on cards is collected. Does not infer synopsis.
Stops on real access challenges; no bypass. Do not run with detail crawler simultaneously.
"""
import argparse
import re
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

from browser_catalog import BASE, next_page
from detail_metadata import OUTPUT, load, save_atomic
from detail_metadata_fast import is_verification_page

STATE = Path("crawler/data/category_metadata_state.json")
ALLOWED_HOST = urlparse(BASE).hostname
SCORE = re.compile(r"^(?:10(?:\.0)?|[0-9](?:\.[0-9])?)$")
DURATION = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b")
YEAR = re.compile(r"(?<!\d)(?:19|20)\d{2}(?!\d)")


def clean_url(value, page_url):
    if not value:
        return ""
    result = urljoin(page_url, value.strip())
    parsed = urlparse(result)
    return result if parsed.scheme == "https" and parsed.hostname else ""


def card_metadata(html, page_url):
    soup = BeautifulSoup(html, "html.parser")
    results = {}
    # Take title links rather than every link inside the card to prevent
    # accidentally treating categories, pagination, or recommendations as films.
    for a in soup.select("a[href]"):
        url = urljoin(page_url, a.get("href", ""))
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != ALLOWED_HOST:
            continue
        if not parsed.path or parsed.path.startswith(("/year/", "/genre/", "/page/", "/country/")):
            continue
        card = a.find_parent(["article", "li"]) or a.find_parent(
            class_=re.compile(r"movie|item|poster|film|card", re.I))
        if card is None:
            continue
        img = card.select_one("img")
        if img is None:
            continue
        heading = card.select_one(".title, .name, h2, h3, h4")
        title = (heading.get_text(" ", strip=True) if heading else
                 a.get("title") or img.get("alt") or a.get_text(" ", strip=True))
        title = title.strip()
        if not 1 <= len(title) <= 180:
            continue
        text = card.get_text(" ", strip=True)
        yr = YEAR.search(urlparse(url).path) or YEAR.search(text)
        # Resolve lazy-load URLs; do not use placeholder data: or blobs.
        poster = ""
        for attr in ("data-src", "data-original", "data-lazy-src", "src"):
            poster = clean_url(img.get(attr, ""), page_url)
            if poster:
                break
        rating = None
        for node in card.select(".rating-number, [data-base-rating], .rating, .rate, .imdb, .score"):
            raw = (node.get("data-base-rating") or node.get("data-rating")
                   or node.get_text(" ", strip=True)).strip().replace(",", ".")
            raw = raw.replace("★", "").replace("⭐", "").strip()
            if SCORE.fullmatch(raw):
                rating = float(raw)
                break
        # A rating might be in a short star badge such as '★ 7.5'.
        if rating is None:
            for node in card.select("[class*='rating'], [class*='vote'], [class*='star']"):
                candidate = re.fullmatch(r"\s*[★⭐]?\s*(10(?:\.0)?|[0-9](?:\.[0-9])?)\s*", node.get_text(" ", strip=True))
                if candidate:
                    rating = float(candidate.group(1))
                    break
        genres = []
        for node in card.select('a[href*="/genre/"], .genre, .genres'):
            value = node.get_text(" ", strip=True)
            for genre in value.split(","):
                genre = genre.strip()
                if genre and len(genre) < 40 and genre not in genres:
                    genres.append(genre)
        duration_match = DURATION.search(text)
        results[url] = {
            "title": title, "year": int(yr.group()) if yr else None,
            "type": "movie", "source_url": url,
            "poster_url": poster, "rating": rating,
            "rating_source": "category-card" if rating is not None else None,
            "genres": genres, "duration": duration_match.group() if duration_match else None
        }
    return results


def merge(old, data):
    result = dict(old)
    for key in ("title", "year", "type", "source_url", "poster_url", "rating",
                "rating_source", "genres", "duration"):
        value = data.get(key)
        if key == "rating":
            # A detail-page score is higher confidence; keep it.
            if result.get("rating") is None and value is not None:
                result[key] = value
                result["rating_source"] = "category-card"
        elif key == "rating_source":
            continue
        elif key in ("title", "year", "type", "source_url"):
            if not result.get(key):
                result[key] = value
        elif value not in (None, "", []):
            if not result.get(key):
                result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--year", type=int)
    parser.add_argument("--years", help="Comma-separated years")
    parser.add_argument("--pages", type=int, default=5, help="Maximum pages per year per run")
    parser.add_argument("--delay", type=float, default=3)
    args = parser.parse_args()
    if bool(args.year) == bool(args.years):
        parser.error("Specify exactly one of --year or --years")
    try:
        years = [args.year] if args.year else [int(v.strip()) for v in args.years.split(",")]
    except ValueError:
        parser.error("--years must be comma-separated integers")
    if any(year < 1900 or year > 2100 for year in years) or not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("Years must be 1900-2100, pages 1-100, delay >= 2")
    data = load(OUTPUT, {})
    state = load(STATE, {})
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for year in dict.fromkeys(years):
                key = str(year)
                saved = state.get(key, {})
                if saved.get("completed"):
                    print(f"{year}: already completed; skipping")
                    continue
                url = saved.get("next_url") or f"{BASE}/year/{year}"
                visited = set()
                for _ in range(args.pages):
                    if url in visited:
                        break
                    visited.add(url)
                    try:
                        response = page.goto(url, wait_until="domcontentloaded", timeout=25000)
                        if not response or response.status >= 400 or urlparse(page.url).hostname != ALLOWED_HOST:
                            print(f"Page unavailable: {url}")
                            return
                        page.wait_for_timeout(900)
                        html = page.content()
                        if is_verification_page(html):
                            print("Access verification requested; stopping.")
                            return
                        found = card_metadata(html, page.url)
                        if not found:
                            print(f"No cards detected on {url}; stopping without advancing checkpoint.")
                            return
                        for item_url, entry in found.items():
                            data[item_url] = merge(data.get(item_url, {}), entry)
                        # Save records before checkpoint to prevent data loss on restart.
                        save_atomic(OUTPUT, data)
                        next_url = next_page(html, page.url, key)
                        state[key] = {
                            "next_url": next_url,
                            "completed": not bool(next_url),
                        }
                        save_atomic(STATE, state)
                        with_posters = sum(bool(v["poster_url"]) for v in found.values())
                        with_ratings = sum(v["rating"] is not None for v in found.values())
                        print(f"{year}: {len(found)} cards, {with_posters} posters, {with_ratings} ratings; total cached {len(data)}")
                        if not next_url:
                            break
                        url = next_url
                        time.sleep(args.delay)
                    except Exception as exc:
                        print(f"Error on {url}: {type(exc).__name__}: {exc}")
                        return
        finally:
            browser.close()


if __name__ == "__main__":
    main()
