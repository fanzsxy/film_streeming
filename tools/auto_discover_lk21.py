"""Conservatively discover new public LK21 title links and prepare a review PR.

Only collects title/year/type/source URL. Never downloads media.
Fail closed for robots restrictions, empty/ambiguous pages and unknown host.
"""
import argparse
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.robotparser import RobotFileParser

import requests
from bs4 import BeautifulSoup

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/auto_discovery_report.json")
MOVIE_BASE = "https://tv12.lk21official.cc"
SERIES_CONFIG = Path("config/source_domains.json")
UA = "FilmStreamPublicCatalogUpdater/1.0"
YEAR_SLUG = re.compile(r"-(19\d{2}|20\d{2})$")
CARD_CLASS = re.compile(r"item|movie|series|poster|film", re.I)


def read_listing(session, base, path):
    url = base.rstrip("/") + path
    if urlparse(url).scheme != "https":
        return None
    robots = urljoin(base, "/robots.txt")
    try:
        response = session.get(robots, timeout=12)
        response.raise_for_status()
        rp = RobotFileParser()
        rp.parse(response.text.splitlines())
        if not rp.can_fetch(UA, url):
            print("Skipped disallowed page:", url)
            return None
        response = session.get(url, timeout=18)
        if response.status_code in (401, 403, 429):
            print("Source restricted access:", response.status_code, url)
            return None
        response.raise_for_status()
    except requests.RequestException as exc:
        print("Skipped unavailable source:", url, str(exc)[:150])
        return None
    if urlparse(response.url).hostname != urlparse(base).hostname:
        print("Skipped redirected cross-host listing:", response.url)
        return None
    html = response.text
    if re.search(r"captcha|verify you are human|access denied", html, re.I):
        print("Skipped verification page:", url)
        return None
    return html


def candidates(html, base, kind):
    soup = BeautifulSoup(html, "html.parser")
    result = {}
    host = urlparse(base).hostname
    for anchor in soup.select("a[href]"):
        url = urljoin(base, anchor.get("href", ""))
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != host:
            continue
        if parsed.query or parsed.fragment or not parsed.path:
            continue
        slug = parsed.path.strip("/").split("/")[-1]
        match = YEAR_SLUG.search(slug)
        if not match:
            continue
        container = anchor.find_parent(["article", "li"]) or anchor.find_parent(class_=CARD_CLASS)
        if container is None:
            continue
        image = container.select_one("img")
        heading = container.select_one("h2,h3,h4,.title,.poster-title")
        if image is None and heading is None:
            continue
        title = ((heading.get_text(" ", strip=True) if heading else "")
                 or anchor.get("title", "")
                 or (image.get("alt", "") if image else "")).strip()
        title = re.sub(r"\s+", " ", title)
        if not title or len(title) > 180:
            continue
        year = int(match.group(1))
        if year > datetime.now(timezone.utc).year + 2:
            continue
        result[url] = {"title": title, "year": year, "type": kind, "url": url}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=int, default=2)
    parser.add_argument("--delay", type=float, default=3)
    args = parser.parse_args()
    if not 1 <= args.pages <= 5 or args.delay < 2:
        parser.error("pages must be 1-5 and delay >= 2")
    document = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = document.get("items")
    if not isinstance(items, list) or not items:
        raise SystemExit("Existing catalog empty/invalid; refusing to replace it")
    config = json.loads(SERIES_CONFIG.read_text(encoding="utf-8"))
    series_base = config["series"]["active_base_url"].rstrip("/")
    sources = [(MOVIE_BASE, "/latest", "movie"),
               (series_base, "/latest-series", "series")]
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    seen_urls = {(str(x.get("type")), str(x.get("url", "")).rstrip("/"))
                 for x in items if isinstance(x, dict)}
    # Do not add duplicate titles with equivalent identity but changed domains.
    seen_titles = {(str(x.get("type")), re.sub(r"[^a-z0-9]", "", str(x.get("title", "")).lower()),
                    str(x.get("year"))) for x in items if isinstance(x, dict)}
    new = []
    observations = {}
    for base, path, kind in sources:
        observed = 0
        for index in range(1, args.pages + 1):
            suffix = path if index == 1 else f"{path}/page/{index}"
            html = read_listing(session, base, suffix)
            if html is None:
                break
            matches = candidates(html, base, kind)
            if not matches:
                print("No recognized cards:", suffix, "- stopping this source")
                break
            observed += len(matches)
            for entry in matches.values():
                identity = (kind, re.sub(r"[^a-z0-9]", "", entry["title"].lower()), str(entry["year"]))
                urlkey = (kind, entry["url"].rstrip("/"))
                if identity in seen_titles or urlkey in seen_urls:
                    continue
                seen_titles.add(identity)
                seen_urls.add(urlkey)
                new.append(entry)
            if index < args.pages:
                time.sleep(args.delay)
        observations[kind] = observed
    # Require actual observed source cards. An empty response must not wipe data.
    if not any(observations.values()):
        print("No accessible listing data; catalog unchanged")
        return
    new.sort(key=lambda x: (x["type"], -x["year"], x["title"].casefold()))
    document["items"] = items + new
    if new:
        CATALOG.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({"checked_at": datetime.now(timezone.utc).isoformat(),
        "observed": observations, "new_count": len(new), "new": new[:100]}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Observed {observations}, added {len(new)} new candidate(s). Review before merging.")


if __name__ == "__main__":
    main()
