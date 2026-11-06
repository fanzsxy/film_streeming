"""Review series aliases across historic Nontondrama hosts in local catalog.

Read-only by default. Compare identical URL PATHS across the approved
series hosts (rather than title or poster). Matching paths and years with
no conflicting metadata can be merged. Poster or metadata conflicts are
reported for review, never silently discarded.
"""
import argparse
import json
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.audit_catalog_completeness import CATALOG, good_poster
from tools.repair_catalog_missing_posters import save_catalog, write_json

REPORT = Path("crawler/data/all_series_alias_duplicates_report.json")
SERIES_HOSTS = {"tv9.nontondrama.my", "tv.nontondrama.vip",
                "tv.lk21online.de"}
KEEP_ORDER = {"tv9.nontondrama.my": 0, "tv.nontondrama.vip": 1,
              "tv.lk21online.de": 2}
FIELDS = {"url", "title", "type", "year", "poster_url"}


def slug(row):
    try:
        u = urlparse(str(row.get("url") or ""))
        if (u.scheme != "https" or u.hostname not in SERIES_HOSTS or
                u.port is not None or u.username or u.password or
                u.query or u.fragment):
            return None
        return u.path.rstrip("/").lower()
    except ValueError:
        return None


def meaningful(value):
    return value not in (None, "", [], {})


def reconcile_metadata(kept, removed):
    """Preserve useful data instead of treating missing metadata as conflict."""
    updates, conflicts = {}, []
    for key in sorted((set(kept) | set(removed)) - FIELDS):
        old, new = kept.get(key), removed.get(key)
        if meaningful(new) and not meaningful(old):
            updates[key] = new
        elif meaningful(new) and meaningful(old) and new != old:
            conflicts.append(key)
    old_poster, new_poster = kept.get("poster_url"), removed.get("poster_url")
    if not good_poster(old_poster) and good_poster(new_poster):
        updates["poster_url"] = new_poster
    elif (good_poster(old_poster) and good_poster(new_poster)
          and old_poster != new_poster):
        conflicts.append("poster_url")
    return updates, conflicts


def plan(document):
    items = document.get("items")
    if not isinstance(items, list):
        raise ValueError("Invalid catalog items")
    by_page = defaultdict(list)
    for index, row in enumerate(items):
        if not isinstance(row, dict) or row.get("type") != "series":
            continue
        path = slug(row)
        poster = row.get("poster_url")
        if not path or path == "/":
            continue
        year = str(row.get("year") or "")
        if not year:
            continue
        by_page[(path, year)].append(index)
    safe, review = [], []
    for (path, year), indices in sorted(by_page.items()):
        if len(indices) < 2:
            continue
        indices.sort(key=lambda i: (KEEP_ORDER[urlparse(items[i]["url"]).hostname],
                                    -len(str(items[i].get("title") or "")), i))
        keep = indices[0]
        if len(indices) > 2:
            review.append({"reason": "three_or_more_rows_same_path",
                           "slug": path, "year": year, "indices": indices})
            continue
        drop = indices[1]
        a, b = items[keep], items[drop]
        updates, conflict_fields = reconcile_metadata(a, b)
        rec = {"keep_index": keep, "remove_index": drop,
               "keep_title": a.get("title"), "remove_title": b.get("title"),
               "keep_url": a.get("url"), "remove_url": b.get("url"),
               "year": year, "slug": path,
               "keep_poster": a.get("poster_url"),
               "remove_poster": b.get("poster_url"),
               "updates": updates,
               "reason": "same_url_path_and_year"}
        if conflict_fields:
            rec["reason"] = ("poster_conflict_same_url_path"
                             if conflict_fields == ["poster_url"]
                             else "metadata_conflict_same_url_path")
            rec["conflict_fields"] = conflict_fields
            review.append(rec)
        else:
            safe.append(rec)
    return {"total": len(items), "safe_remove_count": len(safe),
            "review_count": len(review), "safe_removals": safe,
            "needs_review": review}


def run(args):
    document = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    result = plan(document)
    print("TOTAL:", result["total"])
    print("DUPLIKAT AMAN (path URL dan tahun sama):",
          result["safe_remove_count"])
    print("PERLU REVIEW (path sama, metadata berbeda):", result["review_count"])
    print("DUPLIKAT AMAN DENGAN METADATA DIPERTAHANKAN:",
          sum(bool(row["updates"]) for row in result["safe_removals"]))
    reasons = Counter(row["reason"] for row in result["needs_review"])
    print("ALASAN REVIEW:", dict(reasons))
    fields = Counter(field for row in result["needs_review"]
                     for field in row.get("conflict_fields", []))
    print("FIELD METADATA BENTROK:", dict(fields.most_common()))
    for row in result["safe_removals"][:15]:
        print("  GABUNG:", row["remove_title"], "=>", row["keep_title"],
              "|", row["slug"])
    for row in result["needs_review"][:8]:
        print("  REVIEW:", row["remove_title"], row["reason"])
    if args.apply:
        removals = result["safe_removals"]
        if removals:
            backup = args.catalog.with_name(
                args.catalog.stem + ".backup_" +
                datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
            backup.write_bytes(args.catalog.read_bytes())
            remove_indices = {x["remove_index"] for x in removals}
            for entry in removals:
                document["items"][entry["keep_index"]].update(entry["updates"])
            document["items"] = [row for i, row in enumerate(document["items"])
                                 if i not in remove_indices]
            save_catalog(args.catalog, document)
            result["applied"] = len(remove_indices)
            result["backup"] = str(backup)
            print("DIPERBAIKI:", len(remove_indices), "Backup:", backup)
        else:
            print("Tidak ada duplikat otomatis yang aman dihapus.")
    else:
        print("DRY RUN: tidak mengubah katalog.")
    write_json(args.report, result)
    print("Laporan:", args.report)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--report", type=Path, default=REPORT)
    p.add_argument("--apply", action="store_true")
    run(p.parse_args())


if __name__ == "__main__":
    main()
