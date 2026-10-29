"""Unify existing LK21 crawler datasets into the canonical Flutter catalog.

Run: python tools/unify_crawler_catalog.py
No network requests. Source files are read-only. Existing catalog metadata wins.
"""
import argparse
import csv
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

CATALOG = Path("assets/catalog/filmstream_catalog.json")
DATA = Path("crawler/data")
SOURCES = [
    ("browser_catalog.json", "movie"),
    ("series_catalog.json", "series"),
    ("browser_series.json", "series"),
    ("catalog.json", "movie"),
    ("browser_catalog.csv", "movie"),
    ("series_catalog.csv", "series"),
    ("browser_series.csv", "series"),
]
DETAILS = DATA / "detail_metadata.json"


def read_rows(path):
    if not path.exists():
        return []
    if path.suffix == ".csv":
        with path.open(encoding="utf-8-sig", newline="") as handle:
            return list(csv.DictReader(handle))
    doc = json.loads(path.read_text(encoding="utf-8-sig"))
    if isinstance(doc, dict) and isinstance(doc.get("items"), list):
        return doc["items"]
    if isinstance(doc, dict):
        return list(doc.values())
    return doc if isinstance(doc, list) else []


def norm_title(title):
    return re.sub(r"\s+", " ", title).strip().casefold()


def canonical(row, expected_kind):
    if not isinstance(row, dict):
        return None
    kind = row.get("type", expected_kind)
    if kind == "tv":
        kind = "series"
    if kind not in ("movie", "series") or kind != expected_kind:
        return None
    title = re.sub(r"\s+", " ", str(row.get("title") or "")).strip()
    url = str(row.get("url") or "").strip()
    try:
        year = int(row.get("year"))
    except (ValueError, TypeError):
        return None
    u = urlsplit(url)
    if (not title or len(title) > 180 or year < 1900 or year > 2100 or
        u.scheme != "https" or not u.hostname or u.username or u.password or
        u.query or u.fragment):
        return None
    return {"title": title, "year": year, "url": url, "type": kind}


def extra_metadata(item, details):
    record = details.get(item["url"])
    if not isinstance(record, dict):
        return
    if record.get("type") not in (None, item["type"]):
        return
    for field in ("poster_url", "synopsis"):
        val = record.get(field)
        if isinstance(val, str) and val.strip() and not item.get(field):
            item[field] = val.strip()
    rating = record.get("rating")
    if isinstance(rating, (int, float)) and not isinstance(rating, bool) and 0 < rating <= 10 and item.get("rating") is None:
        item["rating"] = rating
    genres = record.get("genres")
    if isinstance(genres, list) and not item.get("genres"):
        valid = [x for x in genres if isinstance(x, str) and x.strip()]
        if valid and len(valid) <= 10:
            item["genres"] = valid


def merge():
    document = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    existing = document.get("items")
    if not isinstance(existing, list) or not existing:
        raise RuntimeError("Catalog missing/empty; refusing to overwrite")
    by_url = {}
    by_identity = {}
    for item in existing:
        if not isinstance(item, dict):
            continue
        kind = item.get("type")
        if kind not in ("movie", "series"):
            continue
        by_url[(kind, str(item.get("url", "")).rstrip("/"))] = item
        by_identity[(kind, str(item.get("year")), norm_title(str(item.get("title", ""))))] = item

    details = {}
    if DETAILS.exists():
        data = json.loads(DETAILS.read_text(encoding="utf-8-sig"))
        if isinstance(data, dict):
            details = data
    counts = {}
    added = 0
    enriched = 0
    ambiguous = 0
    for filename, kind in SOURCES:
        rows = read_rows(DATA / filename)
        counts[filename] = len(rows)
        for row in rows:
            item = canonical(row, kind)
            if item is None:
                continue
            url_key = (kind, item["url"].rstrip("/"))
            id_key = (kind, str(item["year"]), norm_title(item["title"]))
            known_url = by_url.get(url_key)
            known_id = by_identity.get(id_key)
            if known_url is not None and known_id is not None and known_url is not known_id:
                ambiguous += 1
                continue
            target = known_url or known_id
            if target is None:
                target = item
                existing.append(target)
                by_url[url_key] = target
                by_identity[id_key] = target
                added += 1
            before = {key: target.get(key) for key in ("poster_url", "synopsis", "rating", "genres")}
            extra_metadata(target, details)
            if any(target.get(k) != before[k] for k in before):
                enriched += 1

    if added or enriched:
        # Preserve existing records and their order; add new ones with canonical metadata.
        CATALOG.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    return {"source_rows": counts, "catalog_items": len(existing),
            "added": added, "enriched": enriched, "ambiguous_skipped": ambiguous}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="", help="Optional summary output JSON path")
    args = parser.parse_args()
    result = merge()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.report:
        target = Path(args.report)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
