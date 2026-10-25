"""Bounded parallel detail metadata crawler. Do not run alongside detail_metadata.py.

Usage:
    py crawler/detail_metadata_fast.py --type movie --limit 100 --workers 3 --delay 3
    py crawler/detail_metadata_fast.py --type movie --retry-rating --retry-synopsis --limit 40
"""
import argparse
import asyncio
from urllib.parse import urlparse
from playwright.async_api import async_playwright
from detail_metadata import CATALOG, OUTPUT, HOSTS, load, parse_detail, save_atomic


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--type", choices=("movie", "series", "all"), default="all")
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--delay", type=float, default=3)
    ap.add_argument("--retry-rating", action="store_true")
    ap.add_argument("--retry-synopsis", action="store_true")
    args = ap.parse_args()
    if args.limit < 1 or not 1 <= args.workers <= 5 or args.delay < 2:
        ap.error("limit >= 1, workers 1-5, delay >= 2 seconds")
    records = load(OUTPUT, {})
    catalog = load(CATALOG, {}).get("items", [])
    pending = []
    for item in catalog:
        kind, url = item.get("type"), item.get("url", "")
        if kind not in HOSTS or (args.type != "all" and kind != args.type):
            continue
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != HOSTS[kind]:
            continue
        old = records.get(url)
        retry = old is not None and (
            args.retry_rating or args.retry_synopsis
        )
        if old is not None and not retry:
            continue
        pending.append(item)
        if len(pending) >= args.limit:
            break
    if not pending:
        print("No pending entries.")
        return
    queue = asyncio.Queue()
    for item in pending:
        queue.put_nowait(item)
    lock = asyncio.Lock()
    done, failed = 0, 0
    stop = asyncio.Event()

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        async def worker(number):
            nonlocal done, failed
            page = await browser.new_page()
            try:
                while not queue.empty() and not stop.is_set():
                    try:
                        item = queue.get_nowait()
                    except asyncio.QueueEmpty:
                        return
                    url = item["url"]
                    try:
                        response = await page.goto(
                            url, wait_until="domcontentloaded", timeout=25000)
                        if not response or response.status >= 400 or urlparse(page.url).hostname != urlparse(url).hostname:
                            print(f"Worker {number}: unavailable {url}")
                            failed += 1
                            continue
                        await page.wait_for_timeout(800)
                        html = await page.content()
                        if any(x in html.lower() for x in ("verify you are human", "access denied", "captcha")):
                            print("Access verification detected; stopping.")
                            stop.set()
                            return
                        details = parse_detail(html, page.url)
                        previous = records.get(url, {})
                        updated = {
                            "title": item.get("title", ""),
                            "year": item.get("year"),
                            "type": item["type"],
                            "source_url": url,
                            **{key: value if value not in (None, "", [])
                               else previous.get(key, value)
                               for key, value in details.items()}
                        }
                        if args.retry_rating and details["rating"] is None:
                            updated["rating"] = None
                            updated["rating_source"] = None
                        async with lock:
                            records[url] = updated
                            save_atomic(OUTPUT, records)
                            done += 1
                            print(f"{done}/{len(pending)} {item['title']}: poster={bool(updated['poster_url'])} synopsis={bool(updated['synopsis'])} rating={updated['rating']}")
                    except Exception as exc:
                        failed += 1
                        print(f"Worker {number} failed on {url}: {type(exc).__name__}")
                    finally:
                        queue.task_done()
                        await asyncio.sleep(args.delay)
            finally:
                await page.close()
        try:
            await asyncio.gather(*(worker(i + 1) for i in range(args.workers)))
        finally:
            await browser.close()
    print(f"Saved {done}, failed {failed}, total cache {len(records)}")


if __name__ == "__main__":
    asyncio.run(main())
