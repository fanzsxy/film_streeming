"""Fill Indonesian TMDB overviews in the offline cache without touching titles or URLs.

Run after enrich_tmdb.py. Uses the same TMDB_TOKEN GitHub Actions secret.
Only matched entries with a TMDB ID are queried. Previously checked entries are skipped.
"""
import argparse
import json
import os
import time
from pathlib import Path
from urllib.error import HTTPError, URLError

from enrich_tmdb import tmdb_get


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default="assets/catalog/tmdb_cache.jsonl")
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--delay", type=float, default=0.35)
    args = parser.parse_args()
    if args.limit < 1 or args.delay < 0.25:
        parser.error("--limit >= 1 and --delay >= 0.25")
    token = os.environ.get("TMDB_TOKEN", "").strip()
    if not token:
        parser.error("TMDB_TOKEN not set")
    path = Path(args.cache)
    if not path.is_file():
        print("TMDB cache not available yet.")
        return
    records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    attempted = 0
    localized = 0
    for record in records:
        if attempted >= args.limit:
            break
        if record.get("match_status") != "matched" or not isinstance(record.get("tmdb_id"), int):
            continue
        if record.get("overview_id_checked"):
            continue
        kind = record.get("tmdb_type")
        if kind not in ("tv", "movie"):
            continue
        try:
            detail = tmdb_get(f"{kind}/{record['tmdb_id']}", {"language": "id-ID"}, token)
            overview = (detail.get("overview") or "").strip()
            if overview:
                record["overview_id"] = overview
                localized += 1
            record["overview_id_checked"] = True
        except (HTTPError, URLError, TimeoutError) as exc:
            print(f"TMDB unavailable, stopping without marking current record: {exc}")
            break
        attempted += 1
        if attempted % 50 == 0:
            print(f"Checked {attempted} TMDB records, Indonesian overviews: {localized}")
        time.sleep(args.delay)
    # Atomic replacement, retaining one JSONL record per source URL.
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in records), encoding="utf-8")
    tmp.replace(path)
    print(f"Indonesian synopsis checked: {attempted}; found: {localized}")


if __name__ == "__main__":
    main()
