"""Conservatively discover new public LK21 title links and prepare a review PR.

Collects title/year/type/source URL and conservatively verified detail genres/poster. Never downloads media.
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
from bs4 import BeautifulSoup, Tag, NavigableString

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/auto_discovery_report.json")
MOVIE_BASE = "https://tv12.lk21official.cc"
SERIES_CONFIG = Path("config/source_domains.json")
UA = "FilmStreamPublicCatalogUpdater/1.0"
YEAR_SLUG = re.compile(r"-(19\d{2}|20\d{2})$")
CARD_CLASS = re.compile(r"item|movie|series|poster|film", re.I)
DETAIL_TITLE = re.compile(r"^(.+?)\s*\((\d{4})\)\s*$")
GENRE_NAMES = frozenset({
    "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime",
    "Documentary", "Drama", "Family", "Fantasy", "History", "Horror",
    "Musical", "Music", "Mystery", "Romance", "Sci-Fi", "Science Fiction",
    "Sport", "Thriller", "War", "Western", "Reality", "Soap", "Kids",
    "TV Movie", "War & Politics", "Action & Adventure", "Sci-Fi & Fantasy",
})



def read_listing(session, base, path, robots_cache=None):
    url = base.rstrip("/") + path
    if urlparse(url).scheme != "https":
        return None
    robots = urljoin(base, "/robots.txt")
    try:
        rp = robots_cache.get(base) if robots_cache is not None else None
        if rp is None:
            response = session.get(robots, timeout=12)
            response.raise_for_status()
            rp = RobotFileParser()
            rp.parse(response.text.splitlines())
            if robots_cache is not None:
                robots_cache[base] = rp
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
    final_url = urlparse(response.url)
    requested_url = urlparse(url)
    if (final_url.hostname != requested_url.hostname or
            final_url.path.rstrip("/") != requested_url.path.rstrip("/")):
        print("Skipped unexpected redirect:", response.url)
        return None
    if len(response.content) > 1_200_000:
        print("Skipped oversized metadata page:", url)
        return None
    html = response.text
    if re.search(r"captcha|verify you are human|access denied", html, re.I):
        print("Skipped verification page:", url)
        return None
    return html


def normalized_title(value):
    return re.sub(r"[^a-z0-9]+", "", str(value).casefold())


def safe_poster_url(raw, base):
    if not isinstance(raw, str) or not raw.strip():
        return ""
    url = urljoin(base, raw.strip())
    parsed = urlparse(url)
    return url if parsed.scheme == "https" and parsed.hostname and not (
        parsed.username or parsed.password) else ""


def detail_metadata(html, entry):
    """Only trust genres beside a verified H1 of the same title and year.

    Never read global menu, related-title/footer genres, or redirected pages.
    """
    soup = BeautifulSoup(html, "html.parser")
    heading = soup.find("h1")
    if heading is None:
        return {}
    match = DETAIL_TITLE.fullmatch(heading.get_text(" ", strip=True))
    if not match or int(match.group(2)) != entry["year"]:
        return {}
    title = match.group(1).strip()
    if normalized_title(title) != normalized_title(entry["title"]):
        # A source title can have punctuation differences, but different
        # names must be reviewed instead of attaching another film's genres.
        return {}
    genres = []
    links = 0
    for node in heading.next_elements:
        if isinstance(node, Tag):
            if node.name in ("h2", "iframe", "video"):
                break
            if node.name != "a":
                continue
            links += 1
            if links > 25:
                break
            label = node.get_text(" ", strip=True)
            if label.casefold() in ("play awal", "play terbaru", "trailer"):
                break
            if label in GENRE_NAMES and label not in genres:
                genres.append(label)
        elif isinstance(node, NavigableString):
            if re.search(r"\b(?:Play Awal|Play Terbaru|Beri rating film ini)\b",
                         str(node), re.I):
                break
    result = {"genres": genres} if genres else {}
    poster = soup.select_one('meta[property="og:image"],meta[name="twitter:image"]')
    if poster:
        image = safe_poster_url(poster.get("content"), entry["url"])
        if image:
            result["poster_url"] = image
    return result


def enrich_new_entries(session, entries, bases, robots_cache,
                       detail_limit=30, detail_delay=2.0):
    """One bounded detail request per NEW title; never rescan existing rows."""
    checked = filled = posters = 0
    unavailable = set()
    for entry in sorted(entries, key=lambda e: (e["type"] != "movie", -e["year"])):
        if checked >= detail_limit:
            break
        base = bases[entry["type"]]
        parsed = urlparse(entry["url"])
        if parsed.hostname != urlparse(base).hostname or base in unavailable:
            continue
        if checked:
            time.sleep(detail_delay)
        checked += 1
        html = read_listing(session, base, parsed.path, robots_cache)
        if html is None:
            # A restricted or unreachable host is not hammered repeatedly.
            unavailable.add(base)
            continue
        metadata = detail_metadata(html, entry)
        if metadata.get("genres"):
            entry["genres"] = metadata["genres"]
            entry["genre_data_source"] = "lk21_source"
            filled += 1
        if not entry.get("poster_url") and metadata.get("poster_url"):
            entry["poster_url"] = metadata["poster_url"]
            posters += 1
    return {"detail_checked": checked, "genres_filled": filled,
            "posters_filled": posters, "detail_hosts_unavailable": sorted(unavailable)}


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
        item = {"title": title, "year": year, "type": kind, "url": url}
        if image is not None:
            picture = (image.get("data-src") or image.get("data-original")
                       or image.get("data-lazy-src") or image.get("src"))
            poster = safe_poster_url(picture, base)
            if poster:
                item["poster_url"] = poster
        result[url] = item
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", type=int, default=2)
    parser.add_argument("--delay", type=float, default=3)
    parser.add_argument("--detail-limit", type=int, default=30,
                        help="Maximum new detail pages read for verified genres")
    parser.add_argument("--detail-delay", type=float, default=2.0,
                        help="Minimum seconds between new detail page requests")
    args = parser.parse_args()
    if (not 1 <= args.pages <= 5 or args.delay < 2 or
            not 0 <= args.detail_limit <= 100 or args.detail_delay < 2):
        parser.error("pages 1-5, delay >= 2; detail-limit 0-100, detail-delay >= 2")
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
    robots_cache = {}
    seen_urls = {(str(x.get("type")), str(x.get("url", "")).rstrip("/"))
                 for x in items if isinstance(x, dict)}
    # Do not add duplicate titles with equivalent identity but changed domains.
    seen_titles = {(str(x.get("type")), re.sub(r"[^a-z0-9]", "", str(x.get("title", "")).lower()),
                    str(x.get("year"))) for x in items if isinstance(x, dict)}
    new = []
    observations = {}
    failures = {}
    for base, path, kind in sources:
        observed = 0
        for index in range(1, args.pages + 1):
            suffix = path if index == 1 else f"{path}/page/{index}"
            html = read_listing(session, base, suffix, robots_cache)
            if html is None:
                failures[kind] = f"Listing inaccessible or restricted: {base}{suffix}"
                break
            matches = candidates(html, base, kind)
            if not matches:
                print("No recognized cards:", suffix, "- stopping this source")
                failures[kind] = f"No recognizable title cards: {base}{suffix}"
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
    details = {"detail_checked": 0, "genres_filled": 0,
               "posters_filled": 0, "detail_hosts_unavailable": []}
    if new and args.detail_limit:
        details = enrich_new_entries(
            session, new, {"movie": MOVIE_BASE, "series": series_base},
            robots_cache, args.detail_limit, args.detail_delay)
    # Always write a report, even when source access is denied.
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({"checked_at": datetime.now(timezone.utc).isoformat(),
        "observed": observations, "failures": failures, "detail": details,
        "new_count": len(new),
        "new": new[:100]}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # Inaccessible listings must never appear as a successful sync.
    if not any(observations.values()):
        raise SystemExit("No accessible LK21 listing data; catalog unchanged (see uploaded report)")
    new.sort(key=lambda x: (x["type"], -x["year"], x["title"].casefold()))
    document["items"] = items + new
    if new:
        CATALOG.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Observed {observations}, added {len(new)} new candidate(s). "
          f"Details checked={details['detail_checked']}, "
          f"genres recovered={details['genres_filled']}. Review before merging.")


if __name__ == "__main__":
    main()
