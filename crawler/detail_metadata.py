"""Enrich existing FilmStream entries from their saved detail-page URLs.

Usage:
    py crawler/detail_metadata.py --limit 20 --delay 3
    py crawler/detail_metadata.py --type series --limit 20 --delay 3

Does not change source catalogs or Flutter. Respect site access controls.
"""
import argparse
import json
import os
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

CATALOG = Path("assets/catalog/filmstream_catalog.json")
OUTPUT = Path("crawler/data/detail_metadata.json")
HOSTS = {"movie": "tv12.lk21official.cc", "series": "tv9.nontondrama.my"}


def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return default


def text_meta(soup, *keys):
    for key, value in keys:
        tag = soup.find("meta", attrs={key: value})
        if tag and tag.get("content", "").strip():
            return tag["content"].strip()
    return ""


def image_url(value, page_url):
    if not value:
        return ""
    url = urljoin(page_url, value.strip())
    parsed = urlparse(url)
    return url if parsed.scheme == "https" and parsed.hostname else ""


def parse_detail(html, page_url):
    soup = BeautifulSoup(html, "html.parser")
    poster = text_meta(soup, ("property", "og:image"), ("name", "twitter:image"))
    if not poster:
        img = soup.select_one(".poster img, .mvic-desc img, .info img, article img")
        poster = (img.get("data-src") or img.get("src") or "") if img else ""
    description = text_meta(soup, ("property", "og:description"), ("name", "description"))
    if not description:
        node = soup.select_one(".desc, .description, .synopsis, .entry-content, .wp-content")
        description = node.get_text(" ", strip=True) if node else ""
    rating = None
    for node in soup.select('[itemprop="ratingValue"], meta[property="video:rating"]'):
        raw = node.get("content") or node.get_text(" ", strip=True)
        try:
            candidate = float(raw.strip().replace(",", "."))
            if 0 <= candidate <= 10:
                rating = candidate
                break
        except (ValueError, AttributeError):
            continue
    genres = []
    for a in soup.select('a[href*="/genre/"]'):
        name = a.get_text(" ", strip=True)
        if name and name not in genres:
            genres.append(name)
    return {
        "poster_url": image_url(poster, page_url),
        "synopsis": description[:4000],
        "rating": rating,
        "rating_source": "source-page" if rating is not None else None,
        "genres": genres[:20],
    }


def save_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3)
    parser.add_argument("--type", choices=["movie", "series", "all"], default="all")
    args = parser.parse_args()
    if args.limit < 1 or args.delay < 2:
        parser.error("--limit >= 1 and --delay >= 2 required")
    catalog = load(CATALOG, {}).get("items", [])
    records = load(OUTPUT, {})
    completed = 0
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for item in catalog:
                kind = item.get("type")
                if kind not in HOSTS or (args.type != "all" and args.type != kind):
                    continue
                url = item.get("url", "")
                parsed = urlparse(url)
                if parsed.scheme != "https" or parsed.hostname != HOSTS[kind]:
                    continue
                if url in records:
                    continue
                if completed >= args.limit:
                    break
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=25000)
                    if not response or response.status >= 400 or urlparse(page.url).hostname != parsed.hostname:
                        print(f"Skipped unavailable/redirect: {url}")
                        continue
                    page.wait_for_timeout(800)
                    html = page.content()
                    lowered = html.lower()
                    if any(marker in lowered for marker in ("verify you are human", "access denied", "captcha")):
                        print("Access verification requested; stopping.")
                        break
                    details = parse_detail(html, page.url)
                    records[url] = {
                        "title": item.get("title", ""),
                        "year": item.get("year"),
                        "type": kind,
                        "source_url": url,
                        **details,
                    }
                    save_atomic(OUTPUT, records)
                    completed += 1
                    print(f"{completed}: {item.get('title')} - poster={bool(details['poster_url'])}, synopsis={bool(details['synopsis'])}, rating={details['rating']}")
                except Exception as exc:
                    print(f"Error ({type(exc).__name__}) on {url}; will retry next run.")
                if completed < args.limit:
                    time.sleep(args.delay)
        finally:
            browser.close()
    print(f"Added {completed} detail records; total cached {len(records)}")


if __name__ == "__main__":
    main()
