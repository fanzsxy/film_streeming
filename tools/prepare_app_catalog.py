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

CATALOG = Path("assets/catalog/filmstream_catalog.json")
METADATA = Path("crawler/data/detail_metadata.json")


def main():
    if not CATALOG.is_file() or not METADATA.is_file():
        raise SystemExit("Missing catalog or local metadata file; do not run crawlers.")
    raw = CATALOG.read_bytes()
    catalog = json.loads(raw.decode("utf-8-sig"))
    metadata = json.loads(METADATA.read_text(encoding="utf-8-sig"))
    counts = {"movie": 0, "series": 0}
    for entry in catalog.get("items", []):
        url = entry.get("url", "")
        record = metadata.get(url)
        if not isinstance(record, dict):
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
        counts[kind] += 1
    backup = CATALOG.with_name(
        "filmstream_catalog.backup_" + datetime.now().strftime("%Y%m%d_%H%M%S") + ".json"
    )
    backup.write_bytes(raw)
    temp = CATALOG.with_suffix(".prepared.tmp")
    temp.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    temp.replace(CATALOG)
    print("Merged metadata into existing Flutter catalog:", counts)
    print("Backup:", backup)
    print("No source URLs or titles changed. No server requests made.")


if __name__ == "__main__":
    main()
