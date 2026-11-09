"""Scan new LK21 movies and series with a *visible local Chromium* browser.

Why this exists: GitHub-hosted runner requests to LK21 /latest and
/latest-series can receive HTTP 403, despite user-visible browser access.

Windows:
  py -m pip install playwright beautifulsoup4
  py -m playwright install chromium
  py tools/discover_new_titles_local_webview.py --pages 2 --dry-run
  py tools/discover_new_titles_local_webview.py --pages 2

Only collects public metadata (title, year, source URL, poster URL and
source-page genre tags). Never downloads streams or bypasses verification.
Does not modify existing catalog records or infer missing genres.
"""
import argparse
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from urllib.robotparser import RobotFileParser

from bs4 import BeautifulSoup

if __package__:
    from .auto_discover_lk21 import (
        CATALOG, REPORT, MOVIE_BASE, SERIES_CONFIG, UA,
        candidates, detail_metadata,
    )
else:
    from auto_discover_lk21 import (
        CATALOG, REPORT, MOVIE_BASE, SERIES_CONFIG, UA,
        candidates, detail_metadata,
    )

BLOCKED_MARKERS = re.compile(
    r"captcha|verify you are human|access denied|cloudflare challenge",
    re.I,
)


def valid_source_base(value, kind, series_hosts=()):
    """A manually selected base must be the configured source's own host."""
    parsed = urlparse(value)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port or (
            parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        return False
    hostname = parsed.hostname or ""
    if kind == "movie":
        return hostname == "lk21official.cc" or hostname.endswith(".lk21official.cc")
    return kind == "series" and hostname in series_hosts


def load_robots(page, base):
    """Fetch robots.txt via the same browser. Refuse unverified policies."""
    target = base.rstrip("/") + "/robots.txt"
    response = page.goto(target, wait_until="domcontentloaded", timeout=35000)
    if response is None or response.status != 200:
        raise RuntimeError(f"robots.txt unavailable (HTTP {response.status if response else 'none'})")
    parsed = urlparse(page.url)
    original = urlparse(target)
    if parsed.hostname != original.hostname or parsed.path.rstrip("/") != original.path.rstrip("/"):
        raise RuntimeError("robots.txt redirected; source skipped")
    body = page.locator("body").inner_text(timeout=8000)
    if not re.search(r"^\s*User-agent\s*:", body, re.I | re.M):
        raise RuntimeError("robots.txt is not a valid policy; source skipped")
    robots = RobotFileParser()
    robots.parse(body.splitlines())
    return robots


def read_browser(page, robots, url, render_wait_ms=850):
    """Return (HTML, status), with no trust in redirected or blocked pages."""
    original = urlparse(url)
    if original.scheme != "https" or not original.hostname or original.username or original.password:
        return None, "invalid_url"
    if not robots.can_fetch(UA, url):
        return None, "robots_disallow"
    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=35000)
    except Exception as exc:
        return None, f"browser_error:{type(exc).__name__}"
    actual = urlparse(page.url)
    if actual.scheme != "https" or actual.hostname != original.hostname or \
            actual.path.rstrip("/") != original.path.rstrip("/"):
        return None, "unexpected_redirect"
    status = response.status if response else 0
    if status in (401, 403, 429):
        return None, f"blocked_http_{status}"
    if status >= 400 or status <= 0:
        return None, f"http_{status}"
    page.wait_for_timeout(render_wait_ms)
    html = page.content()
    if len(html) > 1_500_000:
        return None, "oversized_html"
    # Check visible page text, not JavaScript source that may mention
    # captcha handlers on otherwise usable listing pages.
    doc = BeautifulSoup(html, "html.parser")
    for element in doc(["script", "style", "noscript"]):
        element.decompose()
    visible = doc.get_text(" ", strip=True)[:1800]
    if BLOCKED_MARKERS.search(visible):
        return None, "verification_required"
    return html, "ok"


def norm_title(title):
    return re.sub(r"[^a-z0-9]+", "", str(title).casefold())


def select_new(existing, observed, max_new=100):
    """Deduplicate by source URL and type+normalized title+year."""
    known_urls = {
        (str(row.get("type")), str(row.get("url", "")).rstrip("/"))
        for row in existing if isinstance(row, dict)
    }
    known_titles = {
        (str(row.get("type")), norm_title(row.get("title", "")), str(row.get("year")))
        for row in existing if isinstance(row, dict)
    }
    new = []
    for row in observed:
        key = (row["type"], row["url"].rstrip("/"))
        identity = (row["type"], norm_title(row["title"]), str(row["year"]))
        if key in known_urls or identity in known_titles:
            continue
        known_urls.add(key)
        known_titles.add(identity)
        new.append(dict(row))
        if len(new) >= max_new:
            break
    return new


def scan_listings(page, robots, base, path, kind, pages, delay, wait_ms):
    observed, errors = [], []
    for i in range(1, pages + 1):
        url = base.rstrip("/") + (path if i == 1 else f"{path}/page/{i}")
        html, status = read_browser(page, robots, url, wait_ms)
        if status != "ok":
            errors.append(f"{url}: {status}")
            break
        records = list(candidates(html, base, kind).values())
        if not records:
            errors.append(f"{url}: no dated cards recognized (check page layout)")
            break
        observed.extend(records)
        print(f"  {kind} page {i}: found {len(records)} cards", flush=True)
        if i < pages:
            time.sleep(delay)
    return observed, errors


def scan_details(page, robots_by_type, bases, new, limit, delay, wait_ms):
    checked = filled = 0
    problems = {}
    if limit < 1:
        return {"checked": 0, "genres_added": 0, "problems": problems}
    for entry in new:
        if checked >= limit:
            break
        kind = entry["type"]
        robots = robots_by_type.get(kind)
        if robots is None:
            continue
        base = bases[kind]
        address = urlparse(entry["url"])
        if address.hostname != urlparse(base).hostname:
            continue
        if checked:
            time.sleep(delay)
        html, status = read_browser(page, robots, entry["url"], wait_ms)
        checked += 1
        if status != "ok":
            problems[entry["url"]] = status
            if status.startswith(("blocked_", "robots_disallow", "verification_required")):
                # Source is restricted: leave remaining entries unvisited.
                break
            continue
        detail = detail_metadata(html, entry)
        if detail.get("genres"):
            entry["genres"] = detail["genres"]
            entry["genre_data_source"] = "lk21_source"
            filled += 1
        if not entry.get("poster_url") and detail.get("poster_url"):
            entry["poster_url"] = detail["poster_url"]
        print(f"  detail {checked}/{min(limit, len(new))}: {entry['title']!r}; "
              f"genres={entry.get('genres', [])}", flush=True)
    return {"checked": checked, "genres_added": filled, "problems": problems}


def write_json_atomic(path, data, original=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Keep the original layout to avoid a giant unrelated catalog diff.
    pretty = original is None or "\n  \"" in original[:300]
    options = {"ensure_ascii": False}
    if pretty:
        options["indent"] = 2
    else:
        options["separators"] = (",", ":")
    output = json.dumps(data, **options) + "\n"
    temp = path.with_suffix(".scan.tmp")
    temp.write_text(output, encoding="utf-8")
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--movie-base", default=MOVIE_BASE,
                        help="Current LK21 movie source base (HTTPS on lk21official.cc)")
    parser.add_argument("--series-base", default="",
                        help="Current series base from configured allowed hosts")
    parser.add_argument("--pages", type=int, default=2,
                        help="Listing pages per source, 1-5")
    parser.add_argument("--max-new", type=int, default=100,
                        help="Maximum new titles appended per run, 1-200")
    parser.add_argument("--detail-limit", type=int, default=60,
                        help="Maximum new source detail pages for genres, 0-200")
    parser.add_argument("--delay", type=float, default=2.0)
    parser.add_argument("--render-wait-ms", type=int, default=850)
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview new titles; never change the catalog")
    args = parser.parse_args()
    if not (1 <= args.pages <= 5 and 1 <= args.max_new <= 200 and
            0 <= args.detail_limit <= 200 and args.delay >= 2.0 and
            500 <= args.render_wait_ms <= 5000):
        parser.error("pages 1-5, max-new 1-200, detail-limit 0-200, "
                     "delay >=2s, render-wait-ms 500-5000")
    raw = CATALOG.read_text(encoding="utf-8-sig")
    document = json.loads(raw)
    existing = document.get("items")
    if not isinstance(existing, list) or not existing:
        raise SystemExit("Catalog is empty/invalid. No changes made.")
    config = json.loads(SERIES_CONFIG.read_text(encoding="utf-8"))
    bases = {
        "movie": args.movie_base.rstrip("/"),
        "series": (args.series_base or config["series"]["active_base_url"]).rstrip("/"),
    }
    for kind, base in bases.items():
        if not valid_source_base(
                base, kind, config["series"].get("allowed_hosts", [])):
            parser.error(f"Invalid {kind} source base: use HTTPS on a configured "
                         f"LK21 source host with no path/query")
    paths = {"movie": "/latest", "series": "/latest-series"}

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        parser.error("Install: py -m pip install playwright beautifulsoup4; "
                     "py -m playwright install chromium")

    all_observed, errors, observed_counts, robots_by_type = [], {}, {}, {}
    profile = str(Path.home() / ".filmstream_new_titles_chromium")
    with sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile, headless=False, viewport={"width": 1280, "height": 850},
            accept_downloads=False,
        )
        try:
            page = context.pages[0] if context.pages else context.new_page()
            print("Local Chromium opened. Scanning new public title listings.",
                  flush=True)
            for kind, base in bases.items():
                try:
                    robots = load_robots(page, base)
                except Exception as exc:
                    errors[kind] = [f"{base}: {exc}"]
                    observed_counts[kind] = 0
                    print(f"  {kind} skipped: {exc}", flush=True)
                    continue
                robots_by_type[kind] = robots
                rows, failure = scan_listings(
                    page, robots, base, paths[kind], kind,
                    args.pages, args.delay, args.render_wait_ms,
                )
                all_observed.extend(rows)
                errors[kind] = failure
                observed_counts[kind] = len(rows)
            discovered = select_new(existing, all_observed, args.max_new)
            print(f"Cards observed={len(all_observed)}; new titles={len(discovered)}",
                  flush=True)
            details = scan_details(
                page, robots_by_type, bases, discovered,
                args.detail_limit, args.delay, args.render_wait_ms,
            ) if discovered else {"checked": 0, "genres_added": 0, "problems": {}}
        finally:
            context.close()

    report = {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "mode": "local_visible_chromium", "observed": observed_counts,
        "new_count": len(discovered), "details": details,
        "errors": errors, "new": discovered,
    }
    target = Path("crawler/data/local_latest_scan_report.json")
    write_json_atomic(target, report)
    if not any(observed_counts.values()):
        print(f"No accessible listing pages. Report: {target}; catalog unchanged.",
              flush=True)
        raise SystemExit(1)
    if args.dry_run:
        print(f"Dry run: {len(discovered)} new title(s), "
              f"{details['genres_added']} genre(s) found. "
              f"Catalog untouched. Report: {target}", flush=True)
        return
    if discovered:
        document["items"] = existing + discovered
        write_json_atomic(CATALOG, document, original=raw)
        print(f"Added {len(discovered)} new title(s); "
              f"source genres filled={details['genres_added']}.", flush=True)
        print("Review git diff before committing; nothing is pushed automatically.",
              flush=True)
    else:
        print("No new titles after deduplication. Catalog unchanged.", flush=True)
    print(f"Report: {target}", flush=True)


if __name__ == "__main__":
    main()
