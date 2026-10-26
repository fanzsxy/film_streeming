"""Safely retry unmatched series using alternate title queries and strict year checks.

Does not replace verified matches or change crawler URLs. Rewrites cache atomically.
"""
import argparse
import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse

from enrich_tmdb import norm, tmdb_get


def candidates_for(item, token):
    title = item["title"].strip()
    slug = urlparse(item["url"]).path.strip("/").rsplit("-", 1)[0].replace("-", " ")
    queries = list(dict.fromkeys(q for q in (title, slug) if q))
    results = {}
    for query in queries:
        data = tmdb_get("search/tv", {"query": query, "language": "en-US", "include_adult": "false"}, token)
        for candidate in data.get("results", []):
            if isinstance(candidate, dict) and isinstance(candidate.get("id"), int):
                results[candidate["id"]] = candidate
    return list(results.values())


def strict_match(item, candidates):
    import difflib
    raw_title = norm(item["title"])
    slug_title = norm(urlparse(item["url"]).path.strip("/").rsplit("-", 1)[0].replace("-", " "))
    year = int(item["year"])
    ranked = []
    for c in candidates:
        date = c.get("first_air_date") or ""
        if not re.match(r"^[0-9]{4}", date):
            continue
        diff = abs(int(date[:4]) - year)
        if diff > 1:
            continue
        names = [norm(x) for x in (c.get("name"), c.get("original_name")) if x]
        if not names:
            continue
        score = max(difflib.SequenceMatcher(None, q, n).ratio()
                    for q in (raw_title, slug_title) if q for n in names)
        # Exact-year candidates need >= .92; near-year require nearly identical titles.
        if score < (0.92 if diff == 0 else 0.98):
            continue
        ranked.append((score, diff, c))
    ranked.sort(key=lambda x: (x[0], -x[1]), reverse=True)
    if not ranked or (len(ranked) > 1 and ranked[0][0] - ranked[1][0] < 0.08):
        return None
    return ranked[0][2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--delay", type=float, default=0.5)
    args = parser.parse_args()
    if args.limit < 1 or args.delay < .25:
        parser.error("limit >= 1 and delay >= .25 required")
    token = os.getenv("TMDB_TOKEN", "")
    if not token:
        parser.error("TMDB_TOKEN missing")
    catalog = json.loads(Path("assets/catalog/filmstream_catalog.json").read_text(encoding="utf-8"))
    series = {i["url"]: i for i in catalog["items"] if i.get("type") == "series"}
    path = Path("assets/catalog/tmdb_cache.jsonl")
    records = [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines() if x.strip()]
    checked = found = 0
    for record in records:
        if checked >= args.limit:
            break
        if record.get("match_status") != "unmatched" or record.get("retry_v2_checked"):
            continue
        item = series.get(record.get("source_url"))
        if not item:
            continue
        try:
            candidates = candidates_for(item, token)
        except (HTTPError, URLError, TimeoutError) as exc:
            print("Stopping at temporary TMDB error:", exc)
            break
        winner = strict_match(item, candidates)
        record["retry_v2_checked"] = True
        if winner:
            record.update({
                "tmdb_id": winner["id"], "match_status": "matched",
                "poster_path": winner.get("poster_path"),
                "backdrop_path": winner.get("backdrop_path"),
                "overview": winner.get("overview"),
                "rating": winner.get("vote_average"),
                "genre_ids": winner.get("genre_ids", []),
            })
            found += 1
        checked += 1
        time.sleep(args.delay)
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in records), encoding="utf-8")
    tmp.replace(path)
    print(f"Retried unmatched: {checked}; safely matched: {found}; remaining need review.")


if __name__ == "__main__":
    main()
