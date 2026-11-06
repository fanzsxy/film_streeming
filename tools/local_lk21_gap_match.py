"""Look up TMDB catalog gaps by title on LK21, without year-page crawling.

Only public metadata. Require observed URL, exact title/year match, robots access;
stop on rate limits/restrictions. Resume with one checkpoint per candidate.
"""
import argparse
import json
import re
import time
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlparse, parse_qsl, urlunparse
from urllib.robotparser import RobotFileParser

import requests
from bs4 import BeautifulSoup

from tools.auto_discover_lk21 import MOVIE_BASE, UA, candidates
from tools.tmdb_full_gap_scan import identity
from tools.reconcile_tmdb_gaps import reconcile

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/lk21_year_tmdb_report.json")
OUTPUT = Path("crawler/data/local_lk21_gap_candidates.json")
STATE = Path("crawler/data/local_lk21_catalog_first_progress.json")
MANUAL_URLS = Path("crawler/data/manual_lk21_urls.json")
BLOCK = re.compile(r"captcha|verify you are human|access denied", re.I)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def validated(url):
    p = urlparse(url)
    base = urlparse(MOVIE_BASE)
    return p.scheme == "https" and p.hostname == base.hostname and p.port is None and not p.username and not p.password


def get_page(session, robots, url):
    if not validated(url):
        raise RuntimeError("Search/detail URL outside configured LK21 host")
    if not robots.can_fetch(UA, url):
        raise RuntimeError("Disallowed by robots.txt: " + url)
    try:
        r = session.get(url, timeout=25, allow_redirects=False)
    except requests.RequestException as e:
        raise RuntimeError("Temporary LK21 connection failure: " + type(e).__name__) from None
    if r.status_code in (401, 403, 429):
        raise RuntimeError(f"LK21 restricted HTTP {r.status_code}; stopped")
    if r.status_code in (301, 302, 303, 307, 308):
        raise RuntimeError("LK21 redirect; stopped without following it")
    if r.status_code != 200:
        raise RuntimeError(f"LK21 HTTP {r.status_code}; stopped")
    if BLOCK.search(r.text):
        raise RuntimeError("LK21 verification page; stopped")
    return r.text


def discover_search_form(html):
    """Recognize a real GET title-search form; don't invent a search endpoint."""
    soup = BeautifulSoup(html, "html.parser")
    for form in soup.select("form"):
        if form.get("method", "get").lower() != "get":
            continue
        fields = form.select("input[name]")
        for field in fields:
            name = field.get("name", "")
            if name.lower() in ("s", "q", "query", "search", "keyword", "keywords", "judul"):
                action = urljoin(MOVIE_BASE + "/", form.get("action") or "/")
                if not validated(action):
                    continue
                fixed = [(i.get("name"), i.get("value", "")) for i in fields
                         if i.get("name") and i.get("name") != name
                         and i.get("type", "").lower() == "hidden"]
                return action, name, fixed
    return None


def search_url(search, title):
    action, key, fixed = search
    parsed = urlparse(action)
    query = parse_qsl(parsed.query, keep_blank_values=True)
    query.extend(fixed)
    query.append((key, title))
    return urlunparse(parsed._replace(query=urlencode(query)))


def missing_list(report):
    for year in sorted(report.get("by_year", {}), reverse=True):
        data = report["by_year"][year]
        for movie in data.get("missing_tmdb_titles", []):
            if isinstance(movie, dict) and isinstance(movie.get("tmdb_id"), int):
                yield str(year), movie


def poster_url(raw, page_url):
    """Get an actual HTTPS image URL, never placeholders or data URLs."""
    if not raw:
        return None
    raw = raw.strip().split(",")[0].strip().split()[0]
    url = urljoin(page_url, raw)
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        return None
    if url.startswith("data:") or url.endswith((".svg", ".gif")):
        return None
    return url


def poster_from_node(image, page_url):
    if image is None:
        return None
    for attr in ("data-src", "data-original", "data-lazy-src", "src"):
        result = poster_url(image.get(attr), page_url)
        if result:
            return result
    return None


def extract_matches(html, year, titles, page_url=None):
    """Match real LK21 result links even when the site uses nonstandard cards.

    Only accept links observed in response HTML, exact normalized titles/year,
    and the configured LK21 hostname. Never manufacture a film URL.
    """
    page_url = page_url or MOVIE_BASE + "/"
    expected = {identity(t, year)[0] for t in titles if t}
    rows = candidates(html, MOVIE_BASE, "movie")
    for row in rows.values():
        if row.get("year") == int(year) and identity(row.get("title", ""), year)[0] in expected:
            row["poster_url"] = None
    matches = {url: row for url, row in rows.items()
               if row.get("year") == int(year) and identity(row.get("title", ""), year)[0] in expected}
    soup = BeautifulSoup(html, "html.parser")
    for anchor in soup.select("a[href]"):
        href = urljoin(page_url, anchor.get("href", ""))
        if not validated(href):
            continue
        parsed = urlparse(href)
        if parsed.query or parsed.fragment:
            continue
        slug = parsed.path.rstrip("/").split("/")[-1]
        suffix = re.fullmatch(r"(.+)-(19\d{2}|20\d{2})", slug)
        if suffix is None or int(suffix.group(2)) != int(year):
            continue
        normalized_slug = identity(suffix.group(1).replace("-", " "), year)[0]
        container = anchor.find_parent(["article", "li"]) or anchor.find_parent(
            class_=re.compile(r"item|movie|poster|film|result", re.I)) or anchor
        heading = container.select_one("h2,h3,h4,.title,.poster-title")
        text = (heading.get_text(" ", strip=True) if heading else
                anchor.get("title") or anchor.get_text(" ", strip=True) or "")
        img = container.select_one("img")
        alt = img.get("alt", "") if img else ""
        observed_title = next((t for t in (text, alt)
                               if identity(t, year)[0] in expected), None)
        if normalized_slug not in expected and observed_title is None:
            continue
        if href not in matches:
            matches[href] = {"title": observed_title or next(
                (t for t in titles if identity(t, year)[0] == normalized_slug), titles[0]),
                "year": int(year), "url": href, "type": "movie", "poster_url": None}
        if not matches[href].get("poster_url"):
            matches[href]["poster_url"] = poster_from_node(img, page_url)
    return list(matches.values())


def poster_from_detail(html, detail_url):
    """Fallback to detail-page poster metadata if search cards lack images."""
    soup = BeautifulSoup(html, "html.parser")
    for selector, attribute in (
        ('meta[property="og:image"]', "content"),
        ('meta[name="twitter:image"]', "content"),
        ('.poster img', "data-src"),
        ('.poster img', "src"),
        ('.mvic-desc img', "data-src"),
        ('.mvic-desc img', "src"),
        ('.info img', "data-src"),
        ('.info img', "src"),
        ('article img', "data-src"),
        ('article img', "src"),
    ):
        node = soup.select_one(selector)
        if node:
            poster = poster_url(node.get(attribute), detail_url)
            if poster:
                return poster
    return None


def detail_title_year(html):
    soup = BeautifulSoup(html, "html.parser")
    node = soup.select_one("h1")
    title = node.get_text(" ", strip=True) if node else ""
    # The release year is the final parenthesized year, not the first
    # 4-digit number inside an alternate title (e.g. "Gangnam 1970").
    match = re.search(r"\s*\(((?:19|20)\d{2})\)\s*$", title)
    if not match:
        match = re.search(r"\s+((?:19|20)\d{2})\s*$", title)
    if not match:
        return None, None
    return title[:match.start()].strip(), int(match.group(1))


def trusted_manual_match(session, robots, title, year, manual_urls):
    """Only check URLs explicitly supplied by the user and verify detail heading."""
    source = manual_urls.get(f"{year}:{identity(title, year)[0]}")
    if not source or not validated(source):
        return None
    html = get_page(session, robots, source)
    observed_title, observed_year = detail_title_year(html)
    if observed_year != int(year) or identity(observed_title, year)[0] != identity(title, year)[0]:
        return None
    return {"title": observed_title, "year": observed_year, "url": source,
            "type": "movie", "poster_url": poster_from_detail(html, source)}


def run(report_path, output, state_file, delay, limit):
    print("Membaca laporan TMDB lokal...", flush=True)
    report = json.loads(report_path.read_text(encoding="utf-8-sig"))
    print("Membaca dan membandingkan katalog utama...", flush=True)
    doc = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    catalog = doc.get("items")
    if not isinstance(catalog, list) or not catalog:
        raise SystemExit("Invalid/empty catalog")
    queue = reconcile(report, doc)
    print("Cocokkan katalog -> TMDB:", queue["stats"], flush=True)
    print("Hanya judul yang belum ada dicari di LK21:", len(queue["items"]), flush=True)
    known_urls = {str(x.get("url", "")).rstrip("/") for x in catalog if isinstance(x, dict)}
    known_ids = {str(x.get("tmdb_id")) for x in catalog
                 if isinstance(x, dict) and x.get("type") == "movie" and x.get("tmdb_id")}
    known_names = {identity(x.get("title", ""), x.get("year", "")) for x in catalog
                   if isinstance(x, dict) and x.get("type") == "movie"}
    state = {"completed": {}, "found": [], "errors": []}
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8-sig"))
    completed = state.setdefault("completed", {})
    found = state.setdefault("found", [])
    # Isolate this verified pipeline from older, less strict candidate results.
    write_json(output, {"new": found, "new_count": len(found), "checked": len(completed),
                        "errors": state.get("errors", []), "applied": False})
    seen = {x["url"].rstrip("/") for x in found}
    session = requests.Session()
    session.headers.update({"User-Agent": UA})
    print("Menghubungi LK21 robots.txt (batas tunggu 20 detik)...", flush=True)
    try:
        r = session.get(MOVIE_BASE + "/robots.txt", timeout=20, allow_redirects=False)
        if r.status_code != 200:
            raise RuntimeError(f"LK21 robots.txt HTTP {r.status_code}; stopped")
        robots = RobotFileParser()
        robots.parse(r.text.splitlines())
        print("Membaca halaman utama LK21 untuk menemukan form pencarian (batas 25 detik)...", flush=True)
        search = discover_search_form(get_page(session, robots, MOVIE_BASE + "/"))
        if not search:
            raise RuntimeError("No supported public GET search form found. Cannot safely guess URL. Search requires configuration.")
    except (requests.RequestException, RuntimeError) as e:
        write_json(output, {"new": found, "new_count": len(found), "errors": [str(e)], "applied": False})
        print("LK21 belum bisa digunakan: " + str(e), flush=True)
        return
    print(f"Form pencarian LK21 ditemukan. Resume: {len(completed)} judul sudah dicek, {len(found)} kandidat.", flush=True)
    manual_urls = json.loads(MANUAL_URLS.read_text(encoding="utf-8")) if MANUAL_URLS.is_file() else {}
    checked = 0
    for movie in queue["items"]:
        year = str(movie["year"])
        mid = str(movie["tmdb_id"])
        key = "catalog_v2:" + year + ":" + mid
        if mid in known_ids or key in completed:
            continue
        titles = [movie.get("title"), movie.get("original_title")]
        if any(identity(t, year) in known_names for t in titles if t):
            completed[key] = "already_in_catalog"
            continue
        print(f"[{checked + 1}/{limit if limit else 'semua'}] Cari: {titles[0]} ({year})", flush=True)
        try:
            # User-confirmed detail URLs are checked first, rather than relying on search cards.
            matches = {}
            for title in dict.fromkeys(t for t in titles if t):
                seeded = trusted_manual_match(session, robots, title, year, manual_urls)
                if seeded:
                    matches[seeded["url"]] = seeded
                    break
            # Search the same title only once, and use original title as fallback.
            for title in ([] if matches else dict.fromkeys(t for t in titles if t)):
                url = search_url(search, title)
                html = get_page(session, robots, url)
                for row in extract_matches(html, year, titles, url):
                    matches[row["url"]] = row
                if matches:
                    break
                time.sleep(delay)
        except RuntimeError as exc:
            state.setdefault("errors", []).append({"key": key, "message": str(exc)})
            write_json(state_file, state)
            print("Stopped: " + str(exc), flush=True)
            break
        eligible = [m for m in matches.values() if m["url"].rstrip("/") not in known_urls | seen]
        if len(eligible) == 1:
            candidate = eligible[0]
            # Search result alone is insufficient: verify actual detail heading/year.
            try:
                detail_html = get_page(session, robots, candidate["url"])
            except RuntimeError as exc:
                state.setdefault("errors", []).append({"key": key, "message": "Detail inaccessible: " + str(exc)})
                write_json(state_file, state)
                print("  Detail tidak dapat diverifikasi; judul belum ditandai selesai.", flush=True)
                break
            observed_title, observed_year = detail_title_year(detail_html)
            wanted_names = {identity(t, year)[0] for t in titles if t}
            if observed_year != int(year) or identity(observed_title, year)[0] not in wanted_names:
                completed[key] = "detail_mismatch"
            else:
                row = {"title": observed_title, "year": int(year),
                       "url": candidate["url"], "type": "movie",
                       "poster_url": poster_from_detail(detail_html, candidate["url"])
                                     or candidate.get("poster_url") or "",
                       "tmdb_id": movie["tmdb_id"]}
                found.append(row)
                seen.add(row["url"].rstrip("/"))
                completed[key] = "verified"
        elif len(eligible) > 1:
            completed[key] = "ambiguous"
        else:
            completed[key] = "not_found"
        checked += 1
        print(f"  Hasil: {completed[key]} | kandidat ditemukan: {len(found)}", flush=True)
        write_json(state_file, state)
        write_json(output, {"new": found, "new_count": len(found), "checked": len(completed),
                            "errors": state.get("errors", []), "applied": False})
        if limit and checked >= limit:
            break
        time.sleep(delay)
    print(f"Done this run: {checked} titles; verified candidates total {len(found)}. Catalog unchanged.", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--delay", type=float, default=3)
    p.add_argument("--limit", type=int, default=100, help="Max new title searches per run; 0 means all")
    p.add_argument("--output", type=Path, default=OUTPUT)
    p.add_argument("--state", type=Path, default=STATE)
    args = p.parse_args()
    if args.delay < 2 or args.limit < 0:
        p.error("delay >= 2, limit >= 0")
    run(args.report, args.output, args.state, args.delay, args.limit)


if __name__ == "__main__":
    main()
