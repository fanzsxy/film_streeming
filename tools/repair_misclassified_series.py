"""Find movie catalog rows that LK21 explicitly identifies as series.

Read only poster-missing movie rows already checked by poster crawler.
Default dry-run creates report. --apply makes backup and corrects type, poster,
and source URL only on a unique observed search card with matching title/year.
Does not modify other records or the original sitemap crawler.
"""
import argparse
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlparse, urlunparse, parse_qsl
from urllib.robotparser import RobotFileParser

from bs4 import BeautifulSoup

from tools.import_local_lk21_sitemaps import identity
from tools.local_lk21_browser_search import NavigationPacer
from tools.local_lk21_gap_match import poster_from_node
from tools.repair_catalog_missing_posters import (
    CATALOG, PROGRESS, good_poster, save_catalog, write_json,
)

REPORT = Path("crawler/data/misclassified_series_report.json")
STATE = Path("crawler/data/misclassified_series_progress.json")
DOMAINS = Path("config/source_domains.json")
SERIES_BASE = "https://tv.nontondrama.vip"
UA = "FilmStreamPublicCatalogUpdater/1.0"
BLOCK = re.compile(r"captcha|verify you are human|access denied", re.I)


def allowed_series_url(url, hosts):
    parsed = urlparse(url)
    return (parsed.scheme == "https" and parsed.hostname in hosts and
            parsed.port is None and not parsed.username and not parsed.password)


def series_hosts(config_path=DOMAINS):
    data = json.loads(config_path.read_text(encoding="utf-8"))
    return set(data["series"]["allowed_hosts"])


def series_browse(page, robots, url, hosts, pacer):
    if not allowed_series_url(url, hosts):
        raise RuntimeError("URL outside configured series domains")
    if not robots.can_fetch(UA, url):
        raise RuntimeError("Series robots.txt disallows URL")
    pacer.before_navigation(page)
    response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
    if response is None or response.status in (401, 403, 429):
        raise RuntimeError("Series site access restricted")
    if response.status >= 400:
        raise RuntimeError("Series site HTTP " + str(response.status))
    if not allowed_series_url(page.url, hosts):
        raise RuntimeError("Series page redirected outside allowed domains")
    html = page.content()
    if BLOCK.search(html):
        raise RuntimeError("Series site verification challenge")
    return html


def series_robots(page, base):
    url = base.rstrip("/") + "/robots.txt"
    response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
    if response is None or response.status != 200:
        raise RuntimeError("Cannot verify series robots.txt")
    body = page.locator("body").inner_text(timeout=10000)
    if "<html" in body.lower():
        raise RuntimeError("Series robots.txt returned HTML")
    robots = RobotFileParser()
    robots.parse(body.splitlines())
    return robots


def series_search_form(html, base, hosts):
    """Discover actual search endpoint from public series homepage."""
    soup = BeautifulSoup(html, "html.parser")
    for form in soup.select("form"):
        if form.get("method", "get").lower() != "get":
            continue
        inputs = form.select("input[name]")
        for field in inputs:
            key = field.get("name", "")
            if key.lower() not in ("s", "q", "query", "search", "keyword", "judul"):
                continue
            action = urljoin(base + "/", form.get("action") or base + "/")
            if not allowed_series_url(action, hosts):
                continue
            fixed = [(entry.get("name"), entry.get("value", "")) for entry in inputs
                     if entry.get("name") and entry.get("name") != key
                     and entry.get("type", "").lower() == "hidden"]
            return action, key, fixed
    return None


def make_series_search_url(form, title):
    action, key, fixed = form
    parsed = urlparse(action)
    query = parse_qsl(parsed.query, keep_blank_values=True)
    query.extend(fixed)
    query.append((key, title))
    return urlunparse(parsed._replace(query=urlencode(query)))



def diagnose_series_results(html, page_url, row, hosts=None):
    """Inspect small samples of visible search cards without editing catalog."""
    hosts = hosts or series_hosts()
    soup = BeautifulSoup(html, "html.parser")
    rows = []
    seen = set()
    for anchor in soup.select("a[href]"):
        href = urljoin(page_url, anchor.get("href", ""))
        if not allowed_series_url(href, hosts) or href in seen:
            continue
        parent = anchor.find_parent(["article", "li"]) or anchor.find_parent(
            class_=re.compile(r"item|movie|series|poster|film|result", re.I))
        if parent is None:
            continue
        img = parent.select_one("img")
        heading = parent.select_one("h2,h3,h4,.title,.poster-title")
        if img is None and heading is None:
            continue
        seen.add(href)
        rows.append({
            "url": href[:300],
            "title": (heading.get_text(" ", strip=True) if heading else
                      img.get("alt", "") if img else "")[:150],
            "text": parent.get_text(" ", strip=True)[:220],
            "images": {k: str(img.get(k))[:250] for k in
                       ("src", "data-src", "data-original", "data-lazy-src")
                       if img is not None and img.get(k)}
        })
        if len(rows) >= 5:
            break
    return {"requested_title": row.get("title"),
            "requested_year": row.get("year"),
            "page_title": (soup.title.get_text(" ", strip=True)
                           if soup.title else "")[:150],
            "cards_sample": rows}


def series_card_matches(html, page_url, row, hosts=None):
    expected = identity(row.get("title"), row.get("year"))[0]
    year = str(row.get("year", ""))
    if not expected or not re.fullmatch(r"(19|20)\d{2}", year):
        return []
    soup = BeautifulSoup(html, "html.parser")
    hosts = hosts or series_hosts()
    matches = {}
    for anchor in soup.select("a[href]"):
        href = urljoin(page_url, anchor["href"])
        if not allowed_series_url(href, hosts):
            continue
        parent = anchor.find_parent(["article", "li"]) or anchor.find_parent(
            class_=re.compile(r"item|movie|series|poster|film|result", re.I))
        if parent is None:
            continue
        img = parent.select_one("img")
        if img is None:
            continue
        heading = parent.select_one("h2,h3,h4,.title,.poster-title")
        label = (heading.get_text(" ", strip=True) if heading else
                 img.get("alt") or anchor.get("title") or anchor.get_text(" ", strip=True))
        label = re.sub(r"\s*[-|]\s*(series|movie|film)\s*$", "", label.strip(), flags=re.I)
        label = re.sub(r"\s*\(?(?:19\d{2}|20\d{2})\)?\s*$", "", label).strip()
        if identity(label, year)[0] != expected:
            continue
        slug_year = re.search(r"-(19\d{2}|20\d{2})$", urlparse(href).path.rstrip("/"))
        text = parent.get_text(" ", strip=True)
        card_year = re.search(r"\b(19\d{2}|20\d{2})\b", text)
        if not (slug_year or card_year):
            continue
        if any(x and x.group(1) != year for x in (slug_year, card_year)):
            continue
        # Dedicated series-domain search results do not require a Series label.
        poster = poster_from_node(img, page_url)
        if not good_poster(poster):
            continue
        matches[href.rstrip("/")] = {"new_url": href.rstrip("/"), "poster_url": poster,
                                      "type": "series"}
    return list(matches.values())


def candidates(catalog, previous):
    checked = previous.get("checked", {})
    for index, row in enumerate(catalog["items"]):
        if not isinstance(row, dict) or row.get("type") != "movie":
            continue
        if good_poster(row.get("poster_url")):
            continue
        url = str(row.get("url") or "").rstrip("/")
        # Only revisit recorded problematic poster searches, not every movie.
        status = checked.get(url)
        if status in ("redirect", "search_no_verified_match", "year_mismatch",
                      "title_mismatch", "missing_detail_heading_or_year",
                      "catalog_type_mismatch_series"):
            yield index, row


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    previous = (json.loads(args.poster_progress.read_text(encoding="utf-8-sig"))
                if args.poster_progress.is_file() else {})
    queue = list(candidates(catalog, previous))
    saved = json.loads(args.state.read_text(encoding="utf-8-sig")) if args.state.is_file() else {
        "checked": {}, "matches": {}, "errors": []}
    checked = saved.setdefault("checked", {})
    matches = saved.setdefault("matches", {})
    pending = [(i, r) for i, r in queue if args.recheck or r["url"].rstrip("/") not in checked]
    if args.limit:
        pending = pending[:args.limit]
    print("Kandidat movie yang diduga series:", len(queue), "| belum dicek:", len(pending), flush=True)
    diagnostics = []
    if pending:
        from playwright.sync_api import sync_playwright
        hosts = series_hosts(args.domains)
        if urlparse(args.series_base).hostname not in hosts:
            raise SystemExit("Series base URL not allowed by config/source_domains.json")
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            page = browser.new_page(viewport={"width": 1280, "height": 820})
            try:
                robots = series_robots(page, args.series_base)
                pacer = NavigationPacer(args.delay)
                homepage = series_browse(page, robots, args.series_base.rstrip("/") + "/", hosts, pacer)
                form = series_search_form(homepage, args.series_base, hosts)
                if form is None:
                    raise RuntimeError("Series homepage has no supported GET search form")
                for n, (index, row) in enumerate(pending, 1):
                    original = row["url"].rstrip("/")
                    search_url = make_series_search_url(form, row["title"])
                    print(f"[{n}/{len(pending)}] {row['title']} ({row.get('year')})", flush=True)
                    try:
                        html = series_browse(page, robots, search_url, hosts, pacer)
                    except RuntimeError as exc:
                        saved["errors"].append({"url": original, "error": str(exc)})
                        write_json(args.state, saved)
                        print("Pencarian dihentikan:", exc, flush=True)
                        break
                    found = series_card_matches(html, page.url, row, hosts)
                    if args.diagnose and len(diagnostics) < args.diagnose:
                        sample = diagnose_series_results(html, page.url, row, hosts)
                        sample["matches"] = len(found)
                        diagnostics.append(sample)
                        print("  Diagnostik:", json.dumps(sample, ensure_ascii=False),
                              flush=True)
                    if len(found) == 1:
                        matches[original] = {
                            "index": index, "title": row["title"], "year": row["year"],
                            "old_type": row["type"], "old_url": original, **found[0]}
                        checked[original] = "verified_series"
                        print("  Series terverifikasi:", found[0]["new_url"], flush=True)
                    else:
                        checked[original] = "ambiguous_series" if len(found) > 1 else "series_not_verified"
                    write_json(args.state, saved)
            finally:
                browser.close()
    applied = 0
    if args.apply and matches:
        # All matches are individually revalidated against current catalog.
        known_urls = {str(row.get("url", "")).rstrip("/"): i for i, row in
                      enumerate(catalog["items"]) if isinstance(row, dict)}
        changes = []
        for old_url, match in matches.items():
            index = known_urls.get(old_url)
            if index is None:
                continue
            row = catalog["items"][index]
            if (row.get("type") != "movie" or good_poster(row.get("poster_url"))
                    or identity(row.get("title"), row.get("year")) !=
                    identity(match["title"], match["year"])):
                continue
            new_url = match["new_url"]
            other = known_urls.get(new_url)
            if other is not None and other != index:
                continue
            if not good_poster(match["poster_url"]) or not allowed_series_url(new_url, series_hosts(args.domains)):
                continue
            changes.append((index, match))
        if changes:
            backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
                datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
            backup.write_bytes(args.catalog.read_bytes())
            print("Backup katalog:", backup, flush=True)
            for index, match in changes:
                row = catalog["items"][index]
                row["type"] = "series"
                row["url"] = match["new_url"]
                row["poster_url"] = match["poster_url"]
                applied += 1
            save_catalog(args.catalog, catalog)
    report = {"candidates": len(queue), "checked": len(checked),
              "diagnostics": diagnostics,
              "verified_series": len(matches), "applied": applied,
              "matches": list(matches.values()),
              "statuses": dict(Counter(checked.values()))}
    write_json(args.report, report)
    print("Series terverifikasi:", len(matches), "| dikoreksi:", applied,
          "| laporan:", args.report, flush=True)
    if not args.apply:
        print("DRY RUN: katalog tidak diubah. --apply setelah meninjau laporan.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--poster-progress", type=Path, default=PROGRESS)
    parser.add_argument("--state", type=Path, default=STATE)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--series-base", default=SERIES_BASE)
    parser.add_argument("--domains", type=Path, default=DOMAINS)
    parser.add_argument("--recheck", action="store_true",
                        help="Inspect already checked rows again; use with --limit")
    parser.add_argument("--diagnose", type=int, default=0,
                        help="Print sample search cards for N titles")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--delay", type=float, default=2)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.limit < 0 or args.delay < 2 or args.diagnose < 0:
        parser.error("limit >= 0 and delay >= 2 required")
    run(args)


if __name__ == "__main__":
    main()
