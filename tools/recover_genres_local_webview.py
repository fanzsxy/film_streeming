"""Local visible-browser recovery for blank catalog genres.

Run on the user's Windows desktop, NOT in GitHub Actions.
Install: py -m pip install playwright && py -m playwright install chromium
Run:     py tools/recover_genres_local_webview.py --limit 25

Uses an ordinary visible Chromium window. Does not bypass site restrictions.
Writes only assets/catalog/filmstream_catalog.json after each batch.
"""
import argparse
import json
import os
import ssl
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse

from recover_empty_catalog_genres import has_genres, apply_only_if_empty
from recover_source_titles_genres import (
    parse_source_metadata, safe_title_upgrade, valid_source_url,
)
from retry_catalog_genres import CATALOG, genre_ids, normalized
from third_pass_catalog_genres import assess

PASS = "local_webview_v1"
TMDB_AUTH_FAILED = False
TMDB_UNAVAILABLE = False
RETRYABLE_TMDB_STATUSES = {"tmdb_auth_required", "tmdb_network_error", "source_only_pending"}


def should_skip(item, skip_tmdb_pending=False):
    """Do not repeat completed items; optionally defer TMDB-auth failures."""
    if item.get("genre_local_pass") == PASS:
        return True
    return (skip_tmdb_pending
            and item.get("genre_local_status") in RETRYABLE_TMDB_STATUSES)



def browse_source(page, item, delay):
    """Read rendered page from an actual visible browser, never an HTTP scraper."""
    address = item.get("url")
    if not valid_source_url(address):
        return None, [], "invalid_source"
    response = page.goto(str(address), wait_until="domcontentloaded", timeout=35000)
    page.wait_for_timeout(1000)
    current = urlparse(page.url)
    original = urlparse(str(address))
    if (current.hostname != original.hostname
            or current.path.rstrip("/") != original.path.rstrip("/")):
        return None, [], "invalid_redirect"
    status = response.status if response else None
    if status in (401, 403, 429):
        return None, [], f"blocked_{status}"
    if status is not None and status >= 400:
        return None, [], f"http_{status}"
    time.sleep(delay)
    try:
        expected_year = int(item["year"])
    except (ValueError, TypeError, KeyError):
        return None, [], "invalid_year"
    title, genres = parse_source_metadata(page.content(), expected_year)
    return (title, genres, "verified") if title else (None, [], "no_source_title")


def recover_item(item, title, source_genres, source_status, token, delay,
                 source_only=False):
    """Apply verified metadata to one blank-genre catalog item."""
    old_title = str(item.get("title") or "")
    if source_status == "verified" and not safe_title_upgrade(item, title):
        return "title_conflict", False, False, False
    corrected = False
    if source_status == "verified" and normalized(title) != normalized(old_title):
        item.setdefault("title_before_source_check", old_title)
        item["title"] = title
        corrected = True

    if genre_ids(item.get("genre_ids")):
        return "existing_tmdb_ids", corrected, False, False

    global TMDB_AUTH_FAILED, TMDB_UNAVAILABLE
    media = "tv" if item.get("type") == "series" else "movie"
    result, reason = None, "unmatched"
    if source_only:
        reason = "source_only_pending"
    elif TMDB_AUTH_FAILED:
        reason = "tmdb_auth_required"
    elif TMDB_UNAVAILABLE:
        reason = "tmdb_network_error"
    else:
        try:
            result, reason = assess(item, media, token, delay)
        except HTTPError as exc:
            if exc.code == 401:
                TMDB_AUTH_FAILED = True
                reason = "tmdb_auth_required"
                print("TMDB returned HTTP 401. Check the API Read Access Token. "
                      "Continuing with verified source genres.", flush=True)
            elif exc.code in (408, 429, 500, 502, 503, 504):
                # Do not retry rate-limited responses or hammer an unavailable API.
                TMDB_UNAVAILABLE = True
                reason = "tmdb_network_error"
                print(f"TMDB API unavailable (HTTP {exc.code}); "
                      "continuing with source genres only for this batch.",
                      flush=True)
            else:
                raise
        except (URLError, TimeoutError, ssl.SSLError, ConnectionError) as exc:
            # urllib raises URLError for SSL handshake timeouts; treat the
            # entire TMDB path as temporarily unavailable for this batch.
            # Browser/source errors remain independently handled by main().
            TMDB_UNAVAILABLE = True
            reason = "tmdb_network_error"
            print(f"TMDB HTTPS connection failed ({type(exc).__name__}); "
                  "continuing with source genres only for this batch.",
                  flush=True)
    if result and apply_only_if_empty(item, result):
        item["genre_data_source"] = "tmdb"
        return "matched_tmdb", corrected, True, False
    if source_status == "verified" and source_genres and not has_genres(item):
        item["genres"] = list(source_genres)
        item["genre_data_source"] = "lk21_source"
        return "matched_source", corrected, False, True
    return reason or "unmatched", corrected, False, False


def save_catalog(data):
    tmp = CATALOG.with_suffix(".local.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(CATALOG)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=25,
                        help="1-1000 titles per batch; 0 audits without opening the browser")
    parser.add_argument("--delay", type=float, default=0.8)
    parser.add_argument(
        "--source-only", action="store_true",
        help="Use visible Chromium and verified source genres only. "
             "Does not call TMDB or require TMDB_TOKEN.",
    )
    parser.add_argument(
        "--skip-tmdb-pending", action="store_true",
        help="Defer empty titles already checked while TMDB was unauthorized; "
             "they remain pending and can be retried after fixing TMDB token",
    )
    args = parser.parse_args()
    if not 0 <= args.limit <= 1000 or args.delay < 0.5:
        parser.error("--limit must be 0..1000 and --delay >= 0.5")
    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    blanks = [item for item in items
              if item.get("type") in ("movie", "series") and not has_genres(item)]
    pending = sum(item.get("genre_local_pass") != PASS for item in blanks)
    print(f"Catalog: {len(items)}; without genres: {len(blanks)}; pending local: {pending}", flush=True)
    if not args.limit:
        return

    token = os.environ.get("TMDB_TOKEN", "").strip()
    if not token and not args.source_only:
        parser.error("TMDB_TOKEN is required unless using --source-only "
                     "(PowerShell: $env:TMDB_TOKEN = Read-Host 'TMDB token')")
    try:
        from playwright.sync_api import sync_playwright, Error as BrowserError
    except ImportError:
        parser.error("Playwright missing. Install: py -m pip install playwright; py -m playwright install chromium")

    # Kept outside the git repository, so browser cookies/profile are not committed.
    profile = str(Path.home() / ".filmstream_local_webview")
    attempted = corrected = tmdb_filled = source_filled = unresolved = 0
    with sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            profile, headless=False, viewport={"width": 1280, "height": 850},
            accept_downloads=False,
        )
        page = context.pages[0] if context.pages else context.new_page()
        print("Local Chromium window opened; reading source pages.", flush=True)
        try:
            for item in blanks:
                if attempted >= args.limit:
                    break
                if should_skip(item, args.skip_tmdb_pending):
                    continue
                try:
                    title, genres, source_status = browse_source(page, item, args.delay)
                    if source_status.startswith("blocked_"):
                        print(f"Access blocked by source website ({source_status}) for {item.get('url')}. "
                              "Stopping; no bypass attempted.", flush=True)
                        break
                    if source_status == "invalid_redirect":
                        # Ignore redirected page contents entirely: it might
                        # be another title, login page or an unrelated host.
                        # Record the anomaly and move to the next catalog URL.
                        item["genre_local_status"] = "invalid_redirect"
                        item["genre_local_pass"] = PASS
                        attempted += 1
                        unresolved += 1
                        print(f"[{attempted}/{args.limit}] "
                              f"{item.get('title')!r}: skipped unexpected redirect "
                              f"(no genre or title modified)", flush=True)
                    else:
                        if source_status.startswith("http_"):
                            print(f"Source page unavailable: {source_status} "
                                  f"({item.get('title')!r})", flush=True)
                        status, title_fixed, from_tmdb, from_source = recover_item(
                            item, title, genres, source_status, token, args.delay,
                            source_only=args.source_only)
                        item["genre_local_status"] = status
                        if status not in RETRYABLE_TMDB_STATUSES:
                            item["genre_local_pass"] = PASS
                        else:
                            # Keep this empty item pending. No genre is
                            # fabricated when TMDB cannot be verified.
                            item.pop("genre_local_pass", None)
                            print("No verified source genre; kept pending "
                                  "for later TMDB retry.", flush=True)
                        attempted += 1
                        corrected += int(title_fixed)
                        tmdb_filled += int(from_tmdb)
                        source_filled += int(from_source)
                        unresolved += int(not from_tmdb and not from_source)
                        print(f"[{attempted}/{args.limit}] {item.get('title')!r}: "
                              f"source={source_status}; result={status}; "
                              f"genres={item.get('genres') or []}", flush=True)
                except (HTTPError, URLError, TimeoutError, BrowserError, KeyError, ValueError) as exc:
                    # Do not classify network/API errors as permanent mismatches.
                    print(f"Stopped on temporary browser/TMDB error near {item.get('title')!r}: {exc}",
                          flush=True)
                    break
                if attempted % 25 == 0:
                    save_catalog(data)
                    print("Checkpoint saved to main catalog JSON.", flush=True)
        finally:
            context.close()
    if attempted % 25 or not attempted:
        if attempted:
            save_catalog(data)
    remaining = sum(
        item.get("type") in ("movie", "series")
        and not has_genres(item)
        and item.get("genre_local_pass") != PASS for item in items)
    print(f"Local browser batch: checked={attempted}; titles_fixed={corrected}; "
          f"from_tmdb={tmdb_filled}; from_source={source_filled}; "
          f"unresolved={unresolved}; pending={remaining}", flush=True)
    print("Only the local catalog JSON was changed; review 'git diff' before committing.", flush=True)


if __name__ == "__main__":
    main()
