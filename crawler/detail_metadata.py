"""Enrich existing FilmStream entries from their saved detail-page URLs.

Usage:
    py crawler/detail_metadata.py --limit 20 --delay 3
    py crawler/detail_metadata.py --type series --limit 20 --delay 3

Does not change source catalogs or Flutter. Respect site access controls.
"""
import argparse
import json
import os
import re
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
    # Site SEO meta description is promotional copy, not a plot synopsis.
    # Prefer narrative text near the rating/votes in the main detail panel.
    description = ""
    candidates = []
    for node in soup.select(
        ".mvic-desc .desc, .mvic-desc p, .entry-content p, "
        ".description p, .synopsis, .desc, .wp-content p, "
        ".mvic-desc, .entry-content"
    ):
        value = node.get_text(" ", strip=True)
        if len(value) < 90 or len(value) > 4500:
            continue
        if re.search(r"^(Streaming|Nonton|Download)\b", value, re.I):
            continue
        if value not in candidates:
            candidates.append(value)
    if candidates:
        description = candidates[0]
    rating = None
    rating_source = None
    # Extract only explicit short numeric score elements; never parse arbitrary
    # numbers from large rating containers (stars, vote counts, years).
    score_re = re.compile(r"^(?:10(?:\.0)?|[0-9](?:\.[0-9])?)$")
    selectors = (
        '[itemprop="ratingValue"]', '[data-rating-value]',
        '.rating .score', '.rating .value', '.rating .num',
        '.rating-score', '.rating-number', '.rating-value',
        '.imdb-rating .value', '.imdb-rating strong',
        '.mvic-desc .rating strong',
    )
    for selector in selectors:
        for node in soup.select(selector):
            raw = (node.get("content") or node.get("data-rating-value")
                   or node.get_text(" ", strip=True)).strip().replace(",", ".")
            raw = re.sub(r"\s*/\s*10$", "", raw)
            if score_re.fullmatch(raw):
                rating = float(raw)
                rating_source = f"source-page:{selector}"
                break
        if rating is not None:
            break
    # Schema.org ratingValue can also occur inside application/ld+json.
    if rating is None:
        for script in soup.select('script[type="application/ld+json"]'):
            try:
                structured = json.loads(script.string or script.get_text())
            except (ValueError, TypeError):
                continue
            nodes = structured if isinstance(structured, list) else [structured]
            for obj in nodes:
                if not isinstance(obj, dict):
                    continue
                aggregate = obj.get("aggregateRating")
                if not isinstance(aggregate, dict):
                    continue
                value = str(aggregate.get("ratingValue", "")).replace(",", ".")
                best = str(aggregate.get("bestRating", "10"))
                if score_re.fullmatch(value) and best in ("10", "10.0"):
                    rating = float(value)
                    rating_source = "source-page:json-ld"
                    break
            if rating is not None:
                break
    genres = []
    for a in soup.select('a[href*="/genre/"]'):
        name = a.get_text(" ", strip=True)
        if name and name not in genres:
            genres.append(name)
    return {
        "poster_url": image_url(poster, page_url),
        "synopsis": description[:4000],
        "rating": rating,
        "rating_source": rating_source,
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
    parser.add_argument("--debug-rating", action="store_true", help="Show rating HTML for diagnosis")
    parser.add_argument("--retry-rating", action="store_true", help="Recheck saved ratings using strict selectors")
    parser.add_argument("--retry-synopsis", action="store_true",
                        help="Recheck saved entries for real story synopsis")
    parser.add_argument("--retry-missing-rating", action="store_true",
                        help="Revisit existing entries without a rating; keep saved poster/synopsis")
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
                if url in records and not ((args.retry_missing_rating and records[url].get("rating") is None) or args.retry_synopsis or args.retry_rating):
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
                    if args.debug_rating:
                        soup = BeautifulSoup(html, "html.parser")
                        for node in soup.select('[class*="rat"], [id*="rat"], [itemprop="ratingValue"]')[:8]:
                            print("RATING HTML:", str(node)[:350].replace(chr(10), " "))
                    previous = records.get(url, {})
                    if args.retry_rating and details["rating"] is None:
                        print("No verified rating found; previous rating cleared.")
                        previous = {**previous, "rating": None, "rating_source": None}
                    if args.retry_synopsis and not details["synopsis"]:
                        print("No story synopsis detected; existing value kept for review.")
                    records[url] = {
                        "title": item.get("title", ""),
                        "year": item.get("year"),
                        "type": kind,
                        "source_url": url,
                        **{key: (value if value not in (None, "", []) else previous.get(key, value))
                           for key, value in details.items()},
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
