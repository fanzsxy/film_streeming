"""Safely merge verified local sitemap-detail Chromium results into FilmStream.

DRY RUN by default. --apply makes a timestamped backup and atomic replacement.
Does not overwrite verified catalog data; only upgrades provisional sitemap rows.
"""
import argparse
import json
import os
from datetime import datetime
from pathlib import Path

from tools.import_local_lk21_sitemaps import CATALOG, identity
from tools.local_lk21_sitemap_details import OUTPUT, PROVISIONAL, FINAL
from tools.local_lk21_gap_match import write_json


def plan(catalog, report):
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Katalog invalid")
    if report.get("applied") is not False or not isinstance(report.get("verified"), list):
        raise ValueError("Hasil Chromium invalid atau sudah diterapkan")
    by_url = {str(r.get("url", "")).rstrip("/").lower(): i for i, r in enumerate(items)
              if isinstance(r, dict)}
    names = {identity(r.get("title", ""), r.get("year", "")) for r in items
             if isinstance(r, dict) and r.get("type") in ("movie", "tv", "series")
             and r.get("metadata_status") != PROVISIONAL}
    updates, additions, stats = [], [], {"duplicates": 0, "invalid": 0}
    planned_urls = set()
    for row in report["verified"]:
        if (not isinstance(row, dict) or row.get("metadata_status") != FINAL
                or row.get("type") != "movie" or not isinstance(row.get("year"), int)
                or not isinstance(row.get("title"), str) or not row["title"].strip()
                or not isinstance(row.get("poster_url"), str) or not row["poster_url"]
                or not isinstance(row.get("synopsis"), str) or not row["synopsis"].strip()):
            stats["invalid"] += 1
            continue
        from tools.import_local_lk21_sitemaps import clean_url
        from tools.local_lk21_gap_match import poster_url
        url = clean_url(row.get("url"))
        poster = poster_url(row["poster_url"], row["url"]) if url else None
        if not url or not poster or row["url"].rstrip("/") != url:
            stats["invalid"] += 1
            continue
        if url in planned_urls:
            stats["duplicates"] += 1
            continue
        planned_urls.add(url)
        key = identity(row["title"], row["year"])
        existing = by_url.get(url)
        normalized = {k: row[k] for k in (
            "title", "year", "url", "type", "poster_url", "synopsis", "metadata_status")}
        if existing is not None:
            old = items[existing]
            if old.get("metadata_status") != PROVISIONAL:
                stats["duplicates"] += 1
                continue
            # Avoid upgrading a provisional URL to an already cataloged film.
            if key in names:
                stats["duplicates"] += 1
                continue
            updates.append((existing, normalized))
            names.add(key)
        else:
            if key in names:
                stats["duplicates"] += 1
                continue
            additions.append(normalized)
            names.add(key)
    stats["updates"] = len(updates)
    stats["additions"] = len(additions)
    return updates, additions, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--results", type=Path, default=OUTPUT)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    raw = args.catalog.read_bytes()
    catalog = json.loads(raw.decode("utf-8-sig"))
    report = json.loads(args.results.read_text(encoding="utf-8-sig"))
    updates, additions, stats = plan(catalog, report)
    print("Hasil merge sitemap detail:", stats, flush=True)
    if not args.apply:
        print("DRY RUN: katalog belum diubah. Setelah review, gunakan --apply.", flush=True)
        return
    if not updates and not additions:
        print("Tidak ada penambahan/perbaikan yang memenuhi syarat.", flush=True)
        return
    backup = args.catalog.with_name(args.catalog.stem + ".backup_" +
        datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ".json")
    backup.write_bytes(raw)
    for i, updated in updates:
        catalog["items"][i] = {**catalog["items"][i], **updated}
    catalog["items"].extend(additions)
    temp = args.catalog.with_suffix(".sitemap_detail.tmp")
    try:
        temp.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n",
                        encoding="utf-8")
        os.replace(temp, args.catalog)
    finally:
        if temp.exists():
            temp.unlink()
    report["applied"] = True
    report["applied_stats"] = stats
    write_json(args.results, report)
    print(f"Katalog diperbarui: {len(updates)} metadata, {len(additions)} film baru. "
          f"Backup: {backup}", flush=True)


if __name__ == "__main__":
    main()
