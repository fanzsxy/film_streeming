"""Review series aliases across historic Nontondrama hosts in local catalog.

Read-only by default. Same exact path + year + poster + type can be merged
when removed row has no unique metadata. Different slugs sharing a poster
are REVIEW ONLY: the artwork alone does not prove identical content.
"""
import argparse
import json
from collections import defaultdict
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


def plan(document):
    items = document.get("items")
    if not isinstance(items, list):
        raise ValueError("Invalid catalog items")
    by_page, by_poster = defaultdict(list), defaultdict(list)
    for index, row in enumerate(items):
        if not isinstance(row, dict) or row.get("type") != "series":
            continue
        path = slug(row)
        poster = row.get("poster_url")
        if not path or path == "/" or not good_poster(poster):
            continue
        year = str(row.get("year") or "")
        if not year:
            continue
        by_page[(path, year, poster)].append(index)
        by_poster[(year, poster)].append(index)
    safe, review, seen_review = [], [], set()
    for (path, year, poster), indices in sorted(by_page.items()):
        if len(indices) < 2:
            continue
        indices.sort(key=lambda i: (KEEP_ORDER[urlparse(items[i]["url"]).hostname],
                                    -len(str(items[i].get("title") or "")), i))
        keep = indices[0]
        for drop in indices[1:]:
            a, b = items[keep], items[drop]
            extra = sorted(k for k in (set(a) | set(b)) - FIELDS
                           if b.get(k) not in (None, "", [], {})
                           and b.get(k) != a.get(k))
            rec = {"keep_index": keep, "remove_index": drop,
                   "keep_title": a.get("title"), "remove_title": b.get("title"),
                   "keep_url": a.get("url"), "remove_url": b.get("url"),
                   "year": year, "poster_url": poster, "slug": path,
                   "reason": "same_source_path_year_poster"}
            if extra:
                rec["reason"] = "metadata_conflict"
                rec["conflict_fields"] = extra
                review.append(rec)
            else:
                safe.append(rec)
    for (year, poster), indices in sorted(by_poster.items()):
        distinct_paths = {slug(items[i]) for i in indices}
        if len(indices) < 2 or len(distinct_paths) < 2:
            continue
        key = (year, poster)
        if key in seen_review:
            continue
        seen_review.add(key)
        review.append({"reason": "same_poster_different_slug_review_only",
                       "year": year, "poster_url": poster,
                       "entries": [{"index": i, "title": items[i].get("title"),
                                    "url": items[i].get("url")}
                                   for i in indices]})
    return {"total": len(items), "safe_remove_count": len(safe),
            "review_count": len(review), "safe_removals": safe,
            "needs_review": review}


def run(args):
    document = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    result = plan(document)
    print("TOTAL:", result["total"])
    print("DUPLIKAT AMAN (slug, tahun, poster identik):",
          result["safe_remove_count"])
    print("PERLU REVIEW (poster sama/metadata berbeda):", result["review_count"])
    for row in result["safe_removals"][:15]:
        print("  GABUNG:", row["remove_title"], "=>", row["keep_title"],
              "|", row["slug"])
    for row in result["needs_review"][:8]:
        if "entries" in row:
            print("  REVIEW:", " / ".join(x["title"] for x in row["entries"]))
        else:
            print("  REVIEW:", row["remove_title"], row["reason"])
    if args.apply:
        removals = result["safe_removals"]
        if removals:
            backup = args.catalog.with_name(
                args.catalog.stem + ".backup_" +
                datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
            backup.write_bytes(args.catalog.read_bytes())
            remove_indices = {x["remove_index"] for x in removals}
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
