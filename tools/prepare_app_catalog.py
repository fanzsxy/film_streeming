"""Merge local crawler metadata into FilmStream's bundled catalog without web requests.

Run from repository root after the local crawler has finished:
    py tools/prepare_app_catalog.py

Reads:
    assets/catalog/filmstream_catalog.json
    crawler/data/detail_metadata.json
Writes:
    assets/catalog/filmstream_catalog.json (creates timestamped backup)
"""
import json
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

CATALOG = Path("assets/catalog/filmstream_catalog.json")
METADATA = Path("crawler/data/detail_metadata.json")
TMDB_CACHE = Path("assets/catalog/tmdb_cache.jsonl")


def main():
    if not CATALOG.is_file() or not METADATA.is_file():
        raise SystemExit("Missing catalog or local metadata file; do not run crawlers.")
    raw = CATALOG.read_bytes()
    catalog = json.loads(raw.decode("utf-8-sig"))
    metadata = json.loads(METADATA.read_text(encoding="utf-8-sig"))
    tmdb_by_source = {}
    if TMDB_CACHE.is_file():
        for line in TMDB_CACHE.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            item = json.loads(line)
            if item.get("match_status") == "matched" and isinstance(item.get("tmdb_id"), int):
                tmdb_by_source[item["source_url"]] = item
    matched_tmdb = 0
    counts = {"movie": 0, "series": 0}
    active_count = 0
    missing_active = 0
    # Browser-confirmed pages missing from category metadata.
    verified_series = {
        "gotham-2014": "https://tv.nontondrama.vip/gotham-2014",
        "pinocchio-2014": "https://tv.nontondrama.vip/pinocchio-2014",
    }
    for entry in catalog.get("items", []):
        url = entry.get("url", "")
        record = metadata.get(url)
        if not isinstance(record, dict):
            record = {}
        if entry.get("type") == "series":
            verified = verified_series.get(urlparse(url).path.strip("/"))
            if verified:
                record = {**record, "type": "series", "active_source_url": verified}
        if not record:
            continue
        kind = entry.get("type")
        if kind not in counts or record.get("type") != kind:
            continue
        # Only merge fields known to be useful and of expected type.
        for key in ("poster_url", "synopsis"):
            value = record.get(key)
            if isinstance(value, str) and value.strip():
                entry[key] = value.strip()
        if isinstance(record.get("rating"), (float, int)) and 0 <= record["rating"] <= 10:
            entry["rating"] = record["rating"]
        if isinstance(record.get("genres"), list):
            genres = [x for x in record["genres"] if isinstance(x, str) and x.strip()]
            if genres and len(genres) <= 10:
                entry["genres"] = genres
        if kind == "series":
            active = record.get("active_source_url")
            if isinstance(active, str):
                parsed = urlparse(active)
                if (parsed.scheme == "https" and parsed.hostname == "tv.nontondrama.vip"
                        and parsed.path.rstrip("/") == urlparse(url).path.rstrip("/")):
                    entry["active_source_url"] = active
                    active_count += 1
        if kind == "series" and not entry.get("active_source_url"):
            missing_active += 1
        tmdb = tmdb_by_source.get(url)
        if tmdb and tmdb.get("tmdb_type") == ("tv" if kind == "series" else "movie"):
            entry["tmdb_id"] = tmdb["tmdb_id"]
            # Fill gaps only; crawler metadata retains priority.
            if not entry.get("synopsis") and tmdb.get("overview"):
                entry["synopsis"] = tmdb["overview"]
            if not entry.get("poster_url") and tmdb.get("poster_path"):
                entry["tmdb_poster_path"] = tmdb["poster_path"]
            matched_tmdb += 1
        counts[kind] += 1
    backup = CATALOG.with_name(
        "filmstream_catalog.backup_" + datetime.now().strftime("%Y%m%d_%H%M%S") + ".json"
    )
    backup.write_bytes(raw)
    temp = CATALOG.with_suffix(".prepared.tmp")
    temp.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    temp.replace(CATALOG)
    print("Merged metadata into existing Flutter catalog:", counts)
    print("Series with verified active URL:", active_count)
    print("Cached verified TMDB IDs applied:", matched_tmdb)
    print("Series still without active URL:", missing_active)
    print("Backup:", backup)
    print("No source URLs or titles changed. No server requests made.")


if __name__ == "__main__":
    main()
