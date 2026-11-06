"""Audit FilmStream title, URL, poster, and movie/series type; synopsis ignored.

Offline read-only scan of full catalog. Outputs JSON and CSV of incomplete rows.
"""
import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/catalog_incomplete_report.json")
CSV = Path("crawler/data/catalog_incomplete_report.csv")
TYPES = {"movie", "series", "tv"}  # tv is an accepted series alias


def valid_url(value):
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        parsed = urlparse(value.strip())
        return (parsed.scheme == "https" and bool(parsed.hostname)
                and not parsed.username and not parsed.password)
    except ValueError:
        return False


def issues(row):
    if not isinstance(row, dict):
        return ["invalid_record"]
    failed = []
    if not isinstance(row.get("title"), str) or not row["title"].strip():
        failed.append("title")
    if not valid_url(row.get("url")):
        failed.append("url")
    if not valid_url(row.get("poster_url")):
        failed.append("poster")
    if row.get("type") not in TYPES:
        failed.append("type")
    return failed


def audit(document):
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        raise ValueError("Catalog must contain an items list")
    counts = Counter()
    incomplete, duplicates, seen_urls = [], [], {}
    for i, row in enumerate(items):
        kind = row.get("type") if isinstance(row, dict) else None
        group = "movie" if kind == "movie" else "series" if kind in ("series", "tv") else "unknown"
        counts[group + "_total"] += 1
        flags = issues(row)
        if flags:
            counts[group + "_incomplete"] += 1
            for issue in flags:
                counts["missing_" + issue] += 1
                counts[group + "_missing_" + issue] += 1
            incomplete.append({
                "index": i, "title": row.get("title", "") if isinstance(row, dict) else "",
                "year": row.get("year", "") if isinstance(row, dict) else "",
                "type": kind, "url": row.get("url", "") if isinstance(row, dict) else "",
                "poster_url": row.get("poster_url", "") if isinstance(row, dict) else "",
                "issues": flags,
            })
        if isinstance(row, dict) and isinstance(row.get("url"), str) and row["url"].strip():
            key = row["url"].strip().rstrip("/").casefold()
            if key in seen_urls:
                duplicates.append({"index": i, "first_index": seen_urls[key], "url": row["url"]})
            else:
                seen_urls[key] = i
    counts.update(total=len(items), incomplete=len(incomplete),
                  complete=len(items) - len(incomplete), duplicate_url=len(duplicates))
    return {"summary": dict(counts), "incomplete": incomplete, "duplicate_urls": duplicates}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--output", type=Path, default=REPORT)
    parser.add_argument("--csv", type=Path, default=CSV)
    args = parser.parse_args()
    document = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    report = audit(document)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    with args.csv.open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=(
            "index", "title", "year", "type", "url", "poster_url", "issues"))
        writer.writeheader()
        for row in report["incomplete"]:
            writer.writerow({**row, "issues": ", ".join(row["issues"])})
    stats = report["summary"]
    print("TOTAL KATALOG:", stats["total"])
    print("LENGKAP:", stats["complete"])
    print("TIDAK LENGKAP:", stats["incomplete"])
    print("Judul kosong/tidak valid:", stats.get("missing_title", 0))
    print("URL kosong/tidak valid:", stats.get("missing_url", 0))
    print("Poster kosong/tidak valid:", stats.get("missing_poster", 0))
    print("Jenis tidak valid:", stats.get("missing_type", 0))
    print("Movie tidak lengkap:", stats.get("movie_incomplete", 0))
    print("Series tidak lengkap:", stats.get("series_incomplete", 0))
    print("URL duplikat:", stats["duplicate_url"])
    print("Laporan:", args.output, "dan", args.csv)
    print("Catatan: tidak mengetes apakah link/poster merespons secara online.")


if __name__ == "__main__":
    main()
