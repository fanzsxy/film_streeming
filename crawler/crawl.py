"""Incremental, metadata-only public catalog crawler. Respects robots.txt."""
import argparse
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.robotparser import RobotFileParser

import requests
from bs4 import BeautifulSoup

BASE = "https://tv12.lk21official.cc"
UA = "FilmStreamMetadataIndexer/1.0 (+personal catalog research)"
OUT = Path("crawler/data/catalog.json")
STATE = Path("crawler/data/state.json")
YEAR = re.compile(r"\b(?:19|20)\d{2}\b")


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, default=10)
    ap.add_argument("--delay", type=float, default=3)
    args = ap.parse_args()
    if not 1 <= args.pages <= 20 or args.delay < 2:
        ap.error("Use 1-20 pages and delay >= 2 seconds")
    rp = RobotFileParser()
    rp.set_url(BASE + "/robots.txt")
    try:
        response = requests.get(BASE + "/robots.txt", headers={"User-Agent": UA}, timeout=12)
        response.raise_for_status()
        rp.parse(response.text.splitlines())
    except requests.RequestException as exc:
        print(f"robots.txt unavailable; stopping safely: {exc}")
        return
    items = read_json(OUT, {})
    state = read_json(STATE, {"page": 1})
    page = max(1, int(state.get("page", 1)))
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    fetched = 0
    while fetched < args.pages:
        url = BASE + ("/latest" if page == 1 else f"/latest/page/{page}")
        if not rp.can_fetch(UA, url):
            print(f"robots.txt disallows {url}; stopping")
            break
        try:
            response = session.get(url, timeout=18)
            if response.status_code in (403, 429):
                print(f"Source restricted requests ({response.status_code}); stopping")
                break
            response.raise_for_status()
        except requests.RequestException as exc:
            print(f"Request failed: {exc}")
            break
        doc = BeautifulSoup(response.text, "html.parser")
        found = 0
        for a in doc.select("a[href]"):
            href = urljoin(url, a.get("href", ""))
            parsed = urlparse(href)
            if parsed.scheme != "https" or parsed.netloc != urlparse(BASE).netloc:
                continue
            slug = parsed.path.strip("/").split("/")[-1]
            match = re.search(r"-(19\d{2}|20\d{2})$", slug)
            if not match:
                continue
            card = a.find_parent(["article", "li"]) or a
            title_el = card.select_one("h2,h3,h4,.title,.poster-title")
            title = (title_el.get_text(" ", strip=True) if title_el else
                     a.get("title") or a.get_text(" ", strip=True) or
                     slug.rsplit("-", 1)[0].replace("-", " ")).strip()
            if not title or len(title) > 180:
                continue
            items[href] = {"title": title, "year": match.group(1),
                           "url": href, "type": "movie", "last_seen": datetime.now(timezone.utc).date().isoformat()}
            found += 1
        if found == 0:
            print(f"No dated detail links found on page {page}; stopping (verify page layout)")
            break
        fetched += 1
        print(f"Page {page}: {found} observed links; total unique {len(items)}")
        page += 1
        state["page"] = page
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(items, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        if fetched < args.pages:
            time.sleep(args.delay)
    print(f"Finished: {fetched} pages, {len(items)} unique metadata entries")


if __name__ == "__main__":
    main()
