"""Collect public series listing metadata in a separate dataset from movies.

Usage: py crawler/series_catalog.py --pages 20 --delay 3
Only follows observed same-host next-page links; stops on denied access.
"""
import argparse
import csv
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

BASE = "https://tv9.nontondrama.my"
START = BASE + "/latest-series"
ROOT = Path("crawler/data")
STORE = ROOT / "series_catalog.json"
CSV = ROOT / "series_catalog.csv"
STATE = ROOT / "series_state.json"
YEAR = re.compile(r"(?<!\d)(?:19|20)\d{2}(?!\d)")
PAGE = re.compile(r"/latest-series/page/(\d+)/?$")


def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return default


def cards(html, current):
    soup = BeautifulSoup(html, "html.parser")
    result = {}
    for a in soup.select("a[href]"):
        url = urljoin(current, a.get("href", ""))
        u = urlparse(url)
        if u.scheme != "https" or u.hostname != urlparse(BASE).hostname:
            continue
        if u.path in ("/", "/latest-series", "/search") or "/page/" in u.path:
            continue
        card = (a.find_parent(["article", "li"]) or
                a.find_parent(class_=re.compile(r"item|series|poster|film", re.I)) or a)
        image = card.select_one("img")
        heading = card.select_one("h2,h3,h4,.title,.poster-title")
        title = ((heading.get_text(" ", strip=True) if heading else "")
                 or a.get("title", "") or a.get_text(" ", strip=True)
                 or (image.get("alt", "") if image else "")).strip()
        if not title or len(title) > 180 or (image is None and heading is None):
            continue
        year = YEAR.search(u.path.rstrip("/").split("/")[-1]) or YEAR.search(card.get_text(" ", strip=True))
        if not year:
            continue
        result[url] = {"title": title, "year": year.group(),
                       "url": url, "type": "series"}
    return result


def next_page(html, current):
    soup = BeautifulSoup(html, "html.parser")
    match = PAGE.search(urlparse(current).path)
    number = int(match.group(1)) if match else 1
    for a in soup.select("a[href]"):
        url = urljoin(current, a.get("href", ""))
        u = urlparse(url)
        m = PAGE.fullmatch(u.path)
        if u.scheme == "https" and u.hostname == urlparse(BASE).hostname and m:
            if int(m.group(1)) == number + 1:
                return url
    return None


def save(items, next_url, completed=False):
    ROOT.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(items, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    state = load(STATE, {})
    state.update({"next_url": next_url, "completed": completed})
    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    try:
        with CSV.open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=["title", "year", "url", "type"])
            writer.writeheader()
            writer.writerows(sorted(items.values(), key=lambda item: (item["title"].casefold(), item["year"])))
    except PermissionError:
        print("series_catalog.csv is open in Excel; JSON and checkpoint are safe. Close Excel before rerunning.")



YEAR_STATE = ROOT / "series_years_state.json"


def next_year_page(html, current, category_path):
    """Only follow a linked next numbered page inside the same year category."""
    path = urlparse(current).path.rstrip("/")
    match = re.fullmatch(re.escape(category_path) + r"/page/(\\d+)", path)
    number = int(match.group(1)) if match else 1
    for a in BeautifulSoup(html, "html.parser").select("a[href]"):
        candidate = urljoin(current, a.get("href", ""))
        parsed = urlparse(candidate)
        match = re.fullmatch(re.escape(category_path) + r"/page/(\\d+)/?", parsed.path)
        if (parsed.scheme == "https" and parsed.hostname == urlparse(BASE).hostname
                and match and int(match.group(1)) == number + 1):
            return candidate
    return None


def main():
    parser = argparse.ArgumentParser(description="Series catalog: latest or year categories")
    parser.add_argument("--pages", type=int, default=20)
    parser.add_argument("--delay", type=float, default=3)
    parser.add_argument("--year", type=int, help="Series year category, e.g. 2026")
    parser.add_argument("--years", help="Comma-separated years, e.g. 2026,2025,2024")
    parser.add_argument("--url", help="Observed year category URL on the same host")
    args = parser.parse_args()
    if not 1 <= args.pages <= 100 or args.delay < 2:
        parser.error("--pages must be 1-100; --delay must be >= 2")
    if args.years:
        if args.year is not None or args.url:
            parser.error("Choose --years OR --year (and optional --url)")
        try:
            years = [int(part.strip()) for part in args.years.split(",")]
        except ValueError:
            parser.error("--years must be comma-separated whole years")
        if not years or any(y < 1900 or y > 2100 for y in years):
            parser.error("Every year must be between 1900 and 2100")
        original_argv = sys.argv[:]
        try:
            for year in dict.fromkeys(years):
                print(f"\n=== Year {year} ===")
                sys.argv = [original_argv[0], "--year", str(year),
                            "--pages", str(args.pages), "--delay", str(args.delay)]
                main()
        finally:
            sys.argv = original_argv
        return
    if args.url and args.year is None:
        parser.error("--url requires --year")
    if args.year is not None and not 1900 <= args.year <= 2100:
        parser.error("--year must be 1900-2100")

    items = load(STORE, {})
    state = load(STATE, {})
    category = None
    category_path = None
    if args.year is not None:
        category = str(args.year)
        initial = args.url or f"{BASE}/year/{category}"
        parsed = urlparse(initial)
        category_path = parsed.path.rstrip("/")
        if (parsed.scheme != "https" or parsed.hostname != urlparse(BASE).hostname
                or parsed.query or parsed.fragment or
                not re.fullmatch(r"/[A-Za-z0-9/_-]+", category_path)
                or "/page/" in category_path):
            parser.error("Year URL must be an HTTPS category URL on tv9.nontondrama.my")
        # Carry forward any previous year-category checkpoint.
        old = load(YEAR_STATE, {}).get("categories", {}).get(category, {})
        categories = state.setdefault("categories", {})
        entry = categories.get(category, old)
        if entry.get("start") and entry["start"] != initial:
            parser.error("Saved year category URL differs from --url")
        if entry.get("completed") and entry.get("next_url") == initial:
            print(f"Rechecking year {category}: previous one-page completion is unverified.")
            entry["completed"] = False
        elif entry.get("completed"):
            print(f"Year {category} complete; {len(items)} series saved.")
            return
        url = entry.get("next_url", initial)
    else:
        if state.get("completed"):
            print(f"Latest listing complete; {len(items)} unique series saved. Use --year to collect year categories.")
            return
        url = state.get("next_url", START)

    visited = set()
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=False)
        page = browser.new_page()
        try:
            for _ in range(args.pages):
                if url in visited:
                    print("Pagination loop; stopped.")
                    break
                visited.add(url)
                try:
                    response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                except Exception as exc:
                    print(f"Page load failed ({type(exc).__name__}); stopped.")
                    break
                if not response or response.status >= 400:
                    print(f"HTTP {response.status if response else 'unknown'}; stopped.")
                    break
                if urlparse(page.url).hostname != urlparse(BASE).hostname:
                    print("Unexpected redirect; stopped.")
                    break
                page.wait_for_timeout(900)
                html = page.content()
                if re.search(r"captcha|verify you are human|access denied", html, re.I):
                    print("Verification required; stopped.")
                    break
                found = cards(html, page.url)
                if not found:
                    print("No series cards found; stopped.")
                    break
                if category and not any(item["year"] == category for item in found.values()):
                    print("Year category contains no matching-year cards; stopped.")
                    break
                before = len(items)
                items.update(found)
                following = (next_year_page(html, page.url, category_path) if category
                             else next_page(html, page.url))
                if category:
                    state.setdefault("categories", {})[category] = {
                        "start": initial, "next_url": following or url,
                        "completed": False}
                    ROOT.mkdir(parents=True, exist_ok=True)
                    STORE.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
                    try:
                        with CSV.open("w", newline="", encoding="utf-8-sig") as out:
                            writer = csv.DictWriter(out, fieldnames=["title", "year", "url", "type"])
                            writer.writeheader()
                            writer.writerows(sorted(items.values(), key=lambda x: (x["title"].casefold(), x["year"])))
                    except PermissionError:
                        print("CSV locked by Excel; JSON and checkpoint saved. Close Excel before exporting.")
                else:
                    save(items, following or url, completed=not bool(following))
                    # save() rewrites the checkpoint; restore year-category entries.
                    state["next_url"] = following or url
                    state["completed"] = not bool(following)
                    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
                print(f"{url}: {len(found)} cards; {len(items)-before} new; total {len(items)}")
                if not following or following in visited:
                    print("No next linked page; year progress NOT marked complete." if category
                          else "No next linked page; stopped.")
                    break
                url = following
                time.sleep(args.delay)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
