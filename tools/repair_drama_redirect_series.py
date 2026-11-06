"""Verify LK21 /nontondrama redirects and repair misclassified series only.

A movie-domain redirect to /nontondrama?page=slug is evidence to investigate,
NOT sufficient to relabel a row. Visit the candidate on the dedicated series
host in headed Chromium, verify page title/year and episode markers, and use
only a genuine non-placeholder poster. Keep unmatched and restricted films as
movie. Default dry run, resumable checkpoint; --apply backs up catalog and
changes only type, URL, poster of uniquely verified records.
"""
import argparse
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urlparse, urljoin

from bs4 import BeautifulSoup

from tools.audit_catalog_completeness import good_poster
from tools.import_local_lk21_sitemaps import identity
from tools.local_lk21_browser_search import browse, load_robots, NavigationPacer
from tools.local_lk21_gap_match import validated, poster_from_detail
from tools.repair_catalog_missing_posters import CATALOG, PROGRESS, save_catalog, write_json
from tools.triage_missing_catalog_posters import SITEMAP_PROGRESS, status_for
from tools.repair_misclassified_series import (
    DOMAINS, SERIES_BASE, allowed_series_url, series_hosts, series_browse, series_robots,
)

REDIRECT_PROGRESS = Path("crawler/data/redirect_poster_recheck_progress.json")
STATE = Path("crawler/data/drama_redirect_series_progress.json")
REPORT = Path("crawler/data/drama_redirect_series_report.json")
DRAMA_PATH = "/nontondrama"
EPISODES = re.compile(r"\b(?:episode|episodes|eps\.?|season)\b", re.I)
YEARS = re.compile(r"\b(?:19|20)\d{2}\b")


def drama_slug(redirect_url):
    parsed = urlparse(redirect_url)
    if (parsed.scheme != "https" or parsed.hostname != "tv12.lk21official.cc"
            or parsed.path.rstrip("/").lower() != DRAMA_PATH
            or parsed.port is not None):
        return None
    values = parse_qs(parsed.query).get("page", [])
    if len(values) != 1:
        return None
    slug = values[0].strip().strip("/")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug, re.I):
        return None
    return slug.lower()


def candidate_rows(catalog, poster_progress, sitemap_state=None, redirect_state=None):
    """Pick missing movie posters using triage status or an observed drama redirect."""
    sitemap_state = sitemap_state or {}
    redirect_state = redirect_state or {}
    for index, item in enumerate(catalog.get("items") or []):
        if not isinstance(item, dict) or item.get("type") != "movie":
            continue
        if good_poster(item.get("poster_url")):
            continue
        url = str(item.get("url") or "").rstrip("/")
        if not validated(url):
            continue
        reason = status_for(url, poster_progress, sitemap_state)
        observed = observed_target(redirect_state, url)
        if reason["category"] == "redirect" or drama_slug(observed):
            yield index, item


def observed_target(redirect_state, url):
    entry = (redirect_state.get("checked") or {}).get(url)
    if isinstance(entry, dict):
        return entry.get("final_url", "")
    return ""


def verify_series_detail(html, page_url, item):
    """Do not trust a page solely because its URL slug looks plausible.

    The source URL (not an exact display-title match) identifies the record.
    Require source year, series episode evidence and a non-placeholder poster.
    """
    soup = BeautifulSoup(html, "html.parser")
    heading = soup.select_one("h1")
    if heading is None:
        return None, "missing_series_heading"
    heading_text = heading.get_text(" ", strip=True)
    year_string = str(item.get("year") or "")
    if not re.fullmatch(r"(19|20)\d{2}", year_string):
        return None, "missing_catalog_year"
    year_matches = YEARS.findall(heading_text)
    if not year_matches:
        return None, "missing_series_year"
    if year_string not in year_matches:
        return None, "year_mismatch"
    # The movie site's /nontondrama?page=... redirect provides the mapping.
    # An alternate display/translated title must not discard that mapping.
    observed_title = re.sub(
        r"\s*\(?" + re.escape(year_string) + r"\)?\s*$", "", heading_text
    ).strip()
    # Require real series identity, not a generic movie listing with a matching slug.
    page_text = soup.get_text(" ", strip=True)
    if not (EPISODES.search(page_text) and
            re.search(r"\bseries\b", page_text, re.I)):
        return None, "missing_series_evidence"
    poster = poster_from_detail(html, page_url)
    if not good_poster(poster):
        # Series page can expose a poster in Open Graph metadata.
        meta = soup.select_one('meta[property="og:image"]')
        if meta is not None:
            poster = urljoin(page_url, meta.get("content") or "")
    if not good_poster(poster):
        return None, "missing_series_poster"
    return {"type": "series", "url": page_url.rstrip("/"),
            "poster_url": poster, "observed_title": observed_title}, "verified_series"


def report_state(args, state, catalog, candidates):
    matches = state.setdefault("matches", {})
    applicable = {}
    existing = {str(row.get("url") or "").rstrip("/") for row in catalog["items"]
                if isinstance(row, dict)}
    for old_url, match in matches.items():
        index = match.get("index")
        if not isinstance(index, int) or not 0 <= index < len(catalog["items"]):
            continue
        row = catalog["items"][index]
        if (str(row.get("url") or "").rstrip("/") != old_url or row.get("type") != "movie"
                or good_poster(row.get("poster_url")) or
                row.get("title") != match.get("title") or
                str(row.get("year") or "") != str(match.get("year") or "") or
                not good_poster(match.get("poster_url")) or
                not allowed_series_url(match.get("url") or "", series_hosts(args.domains))):
            continue
        if match["url"] in existing and match["url"] != old_url:
            continue
        applicable[old_url] = match
    dest_counts = Counter(x["url"] for x in applicable.values())
    applicable = {url: found for url, found in applicable.items()
                  if dest_counts[found["url"]] == 1}
    applied = 0
    if args.apply and applicable:
        backup = args.catalog.with_name(
            args.catalog.stem + ".backup_" +
            datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
        backup.write_bytes(args.catalog.read_bytes())
        for old_url, match in applicable.items():
            row = catalog["items"][match["index"]]
            row["type"] = "series"
            row["url"] = match["url"]
            row["poster_url"] = match["poster_url"]
            applied += 1
        save_catalog(args.catalog, catalog)
        print("Backup:", backup)
    statuses = Counter(x.get("status") for x in state.get("checked", {}).values()
                       if isinstance(x, dict))
    report = {"candidates": len(candidates), "checked": len(state.get("checked", {})),
              "statuses": dict(statuses), "verified_and_applicable": len(applicable),
              "applied": applied, "matches": list(matches.values()),
              "details": state.get("checked", {})}
    write_json(args.report, report)
    print("Series cocok dan dapat diperbaiki:", len(applicable),
          "| diterapkan:", applied, "| laporan:", args.report)
    if not args.apply:
        print("DRY RUN: katalog tidak diubah. --apply setelah meninjau laporan.")


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    previous = json.loads(args.poster_progress.read_text(encoding="utf-8-sig"))
    redirect_state = (json.loads(args.redirect_progress.read_text(encoding="utf-8-sig"))
                      if args.redirect_progress.is_file() else {})
    sitemap_state = (json.loads(args.sitemap_progress.read_text(encoding="utf-8-sig"))
                     if args.sitemap_progress.is_file() else {})
    state = (json.loads(args.state.read_text(encoding="utf-8-sig"))
             if args.state.is_file() else {"checked": {}, "matches": {}})
    checked = state.setdefault("checked", {})
    matches = state.setdefault("matches", {})
    queue = list(candidate_rows(catalog, previous, sitemap_state, redirect_state))
    todo = [(i, row) for i, row in queue
            if (args.recheck or
                (args.retry_mismatches and
                 (checked.get(str(row.get("url") or "").rstrip("/")) or {}).get("status")
                 == "title_mismatch") or
                str(row.get("url") or "").rstrip("/") not in checked)]
    if args.limit:
        todo = todo[:args.limit]
    observed_count = sum(bool(drama_slug(observed_target(redirect_state,
        str(row.get("url") or "").rstrip("/")))) for _, row in queue)
    print("Redirect drama sudah diamati:", observed_count, flush=True)
    print("Kandidat movie gagal poster dengan redirect:", len(queue),
          "| diperiksa sekarang:", len(todo), flush=True)
    if todo:
        from playwright.sync_api import sync_playwright
        hosts = series_hosts(args.domains)
        if not allowed_series_url(args.series_base, hosts):
            raise SystemExit("Series base URL is not allowlisted")
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            movie_page = browser.new_page(viewport={"width": 1280, "height": 820})
            series_page = browser.new_page(viewport={"width": 1280, "height": 820})
            try:
                movie_robots = load_robots(movie_page)
                series_policy = series_robots(series_page, args.series_base)
                pacer = NavigationPacer(args.delay)
                for n, (index, item) in enumerate(todo, 1):
                    url = str(item["url"]).rstrip("/")
                    print(f"[{n}/{len(todo)}] {item.get('title')} ({item.get('year')})",
                          flush=True)
                    prior_target = observed_target(redirect_state, url)
                    destination = prior_target if drama_slug(prior_target) else ""
                    try:
                        if not destination:
                            browse(movie_page, movie_robots, url, pacer=pacer)
                            destination = movie_page.url
                        slug = drama_slug(destination)
                        if not slug:
                            result = {"status": "not_drama_redirect",
                                      "final_url": destination}
                        else:
                            series_url = args.series_base.rstrip("/") + "/" + slug
                            html = series_browse(series_page, series_policy,
                                                 series_url, hosts, pacer)
                            final_url = series_page.url
                            if not allowed_series_url(final_url, hosts):
                                raise RuntimeError("Unexpected series-domain redirect")
                            if urlparse(final_url).path.rstrip("/") != "/" + slug:
                                raise RuntimeError("Series URL unexpectedly redirected to another title")
                            candidate, status = verify_series_detail(html, final_url, item)
                            result = {"status": status, "final_url": destination,
                                      "series_url": final_url}
                            if candidate:
                                result["observed_title"] = candidate.get("observed_title")
                            if candidate:
                                matches[url] = {
                                    "index": index, "title": item.get("title"),
                                    "year": item.get("year"), **candidate}
                        checked[url] = result
                        print("  ", result["status"], "|", result["final_url"],
                              "| series:", result.get("series_url", ""), flush=True)
                    except RuntimeError as exc:
                        msg = str(exc)
                        # Access/robots/policy restrictions: stop safely, don't
                        # record as a completed examination.
                        state.setdefault("errors", []).append({"url": url, "reason": msg})
                        write_json(args.state, state)
                        print("  Dihentikan:", msg, flush=True)
                        break
                    write_json(args.state, state)
            finally:
                browser.close()
    report_state(args, state, catalog, queue)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--poster-progress", type=Path, default=PROGRESS)
    p.add_argument("--redirect-progress", type=Path, default=REDIRECT_PROGRESS)
    p.add_argument("--sitemap-progress", type=Path, default=SITEMAP_PROGRESS)
    p.add_argument("--state", type=Path, default=STATE)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--domains", type=Path, default=DOMAINS)
    p.add_argument("--series-base", default=SERIES_BASE)
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--delay", type=float, default=2.0)
    p.add_argument("--recheck", action="store_true")
    p.add_argument("--retry-mismatches", action="store_true",
                   help="Revisit previous title_mismatch entries using source URL mapping")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    if args.limit < 0 or args.delay < 2:
        p.error("--limit >= 0 and --delay >= 2 required")
    run(args)


if __name__ == "__main__":
    main()
