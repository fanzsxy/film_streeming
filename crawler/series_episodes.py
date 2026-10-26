"""Inspect series detail pages for real season/episode links.

Usage:
  py crawler/series_episodes.py --limit 3 --delay 3
  py crawler/series_episodes.py --limit 100 --delay 3

Saves episode fields into existing crawler/data/detail_metadata.json.
Only stores episode URLs explicitly present in HTML. Never guesses URLs.
"""
import argparse
import json
import re
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

from detail_metadata import CATALOG, load, save_atomic

from detail_metadata import OUTPUT
HOST = "tv9.nontondrama.my"
SEASON = re.compile(r"(?:season|musim|saison|s)\s*[-:#.]?\s*(\d{1,2})", re.I)
EPISODE = re.compile(r"(?:episode|episod|ep|e)\s*[-:#.]?\s*(\d{1,4})", re.I)


def parse_episodes(html, page_url):
    soup = BeautifulSoup(html, "html.parser")
    for unwanted in soup.select("header, footer, nav, script, style"):
        unwanted.decompose()
    found = {}
    for node in soup.select("a[href]"):
        raw = node.get("href", "")
        url = urljoin(page_url, raw)
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != HOST:
            continue
        label = " ".join(filter(None, [
            node.get_text(" ", strip=True), node.get("title", ""),
            node.get("aria-label", "")
        ]))
        parent = node.find_parent(class_=re.compile(r"episode|episod|season|playlist|listing", re.I))
        context = parent.get_text(" ", strip=True)[:150] if parent else ""
        episode = EPISODE.search(label)
        if episode is None:
            episode = EPISODE.search(parsed.path.replace("-", " "))
        if episode is None:
            continue
        season = SEASON.search(label) or SEASON.search(parsed.path.replace("-", " "))
        if season is None and context:
            season = SEASON.search(context)
        # Unknown season stays unknown; never default to season 1.
        sn = int(season.group(1)) if season else None
        en = int(episode.group(1))
        if not 1 <= en <= 2000:
            continue
        key = (sn, en, url)
        found[key] = {"season": sn, "episode": en, "url": url,
                      "label": label[:120]}
    return sorted(found.values(), key=lambda x: (x["season"] is None, x["season"] or 0, x["episode"], x["url"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=3)
    ap.add_argument("--delay", type=float, default=3)
    args = ap.parse_args()
    if args.limit < 1 or args.delay < 2:
        ap.error("limit >= 1 and delay >= 2 required")
    existing = load(OUTPUT, {})
    catalog = load(CATALOG, {}).get("items", [])
    pending = [x for x in catalog if x.get("type") == "series"
               and urlparse(x.get("url", "")).scheme == "https"
               and urlparse(x["url"]).hostname == HOST
               and "episodes" not in existing.get(x["url"], {})][:args.limit]
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for item in pending:
                url = item["url"]
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=25000)
                    if not response or response.status >= 400 or urlparse(page.url).hostname != HOST:
                        print(f"Unavailable: {url}")
                        continue
                    page.wait_for_timeout(900)
                    html = page.content()
                    visible = BeautifulSoup(html, "html.parser")
                    for tag in visible(["script", "style", "noscript"]):
                        tag.decompose()
                    txt = visible.get_text(" ", strip=True).lower()[:3000]
                    if any(x in txt for x in ("verify you are human", "access denied", "checking your browser")):
                        print("Access verification requested; stopping.")
                        break
                    episodes = parse_episodes(html, page.url)
                    # An empty result could mean JS-rendered controls or a different DOM.
                    # Keep it visible as unverified, rather than declaring 0 episodes.
                    record = existing.setdefault(url, {
                        "title": item.get("title", ""), "year": item.get("year"),
                        "type": "series", "source_url": url
                    })
                    record["episode_status"] = "links_found" if episodes else "needs_review"
                    record["episodes"] = episodes
                    save_atomic(OUTPUT, existing)
                    print(f"{item.get('title')}: {len(episodes)} explicit episode links; {record['episode_status']}")
                except Exception as exc:
                    print(f"Error: {type(exc).__name__} on {url}")
                time.sleep(args.delay)
        finally:
            browser.close()
    print(f"Total combined metadata records: {len(existing)}")


if __name__ == "__main__":
    main()
