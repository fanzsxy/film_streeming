"""Remove only two confirmed duplicate series pairs from the LOCAL catalog.

Pairs must have the same source slug, year, poster URL, and series type
across tv9.nontondrama.my and tv.nontondrama.vip. Keep the tv9 record with
the fuller canonical display title. Do not touch film/movie entries.
Dry run by default, back up before --apply, and reject unexpected metadata.
"""
import argparse
import json
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.audit_catalog_completeness import CATALOG, good_poster
from tools.repair_catalog_missing_posters import save_catalog, write_json

REPORT = Path("crawler/data/confirmed_series_duplicate_cleanup.json")
PAIR_SPECS = (
    ("25-years-you-2026", 2026, "25 Years of You", "25 Years You"),
    ("100-days-lies-2026", 2026, "100 Days of Lies", "100 Days Lies"),
)
KEEP_HOST = "tv9.nontondrama.my"
REMOVE_HOST = "tv.nontondrama.vip"


def matching_slug(url, slug, host):
    parsed = urlparse(str(url or ""))
    return (parsed.scheme == "https" and parsed.hostname == host
            and parsed.username is None and parsed.password is None
            and parsed.port is None and parsed.path.rstrip("/") == "/" + slug
            and not parsed.query and not parsed.fragment)


def plan(document):
    items = document.get("items")
    if not isinstance(items, list):
        raise ValueError("Catalog must have items list")
    removals, errors = [], []
    for slug, year, keep_title, remove_title in PAIR_SPECS:
        keep = [(i, x) for i, x in enumerate(items)
                if isinstance(x, dict) and matching_slug(x.get("url"), slug, KEEP_HOST)]
        drop = [(i, x) for i, x in enumerate(items)
                if isinstance(x, dict) and matching_slug(x.get("url"), slug, REMOVE_HOST)]
        if len(keep) != 1 or len(drop) != 1:
            errors.append({"slug": slug, "reason": "expected_exactly_one_record_each",
                           "keep_count": len(keep), "remove_count": len(drop)})
            continue
        ki, source = keep[0]
        di, alias = drop[0]
        def expected(row, title):
            return (row.get("title") == title and str(row.get("year")) == str(year)
                    and row.get("type") == "series")
        if not expected(source, keep_title) or not expected(alias, remove_title):
            errors.append({"slug": slug, "reason": "title_year_or_type_mismatch"})
            continue
        poster = source.get("poster_url")
        if not good_poster(poster) or poster != alias.get("poster_url"):
            errors.append({"slug": slug, "reason": "poster_not_identical_and_valid"})
            continue
        # Never discard independently stored metadata on the alias.
        # This conservatively rejects differences rather than silently losing
        # ratings, TMDB IDs, active URLs or synopsis.
        non_identity = set(source) | set(alias)
        non_identity -= {"title", "year", "type", "url", "poster_url"}
        conflict = [key for key in sorted(non_identity)
                    if alias.get(key) not in (None, "", [], {})
                    and alias.get(key) != source.get(key)]
        if conflict:
            errors.append({"slug": slug, "reason": "non_identity_metadata_conflict",
                           "fields": conflict})
            continue
        removals.append({"slug": slug, "keep_index": ki, "remove_index": di,
                         "keep_title": keep_title, "remove_title": remove_title,
                         "keep_url": source["url"], "remove_url": alias["url"]})
    return {"total_before": len(items), "remove_count": len(removals),
            "removals": removals, "errors": errors}


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    report = plan(catalog)
    print("TOTAL SEBELUM:", report["total_before"])
    print("DUPLIKAT TERKONFIRMASI:", report["remove_count"])
    for x in report["removals"]:
        print("  Pertahankan:", x["keep_title"], "|", x["keep_url"])
        print("  Hapus alias:", x["remove_title"], "|", x["remove_url"])
    for error in report["errors"]:
        print("  LEWATI:", error)
    if args.apply:
        if report["errors"] or report["remove_count"] != len(PAIR_SPECS):
            print("TIDAK DITERAPKAN: data tidak cocok dengan 2 pasang yang diverifikasi.")
        else:
            backup = args.catalog.with_name(
                args.catalog.stem + ".backup_" +
                datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
            backup.write_bytes(args.catalog.read_bytes())
            drop = {x["remove_index"] for x in report["removals"]}
            catalog["items"] = [row for i, row in enumerate(catalog["items"]) if i not in drop]
            save_catalog(args.catalog, catalog)
            report["applied"] = len(drop)
            report["backup"] = str(backup)
            print("DIPERBAIKI:", len(drop), "| TOTAL SETELAH:", len(catalog["items"]))
            print("Backup:", backup)
    else:
        print("DRY RUN: katalog tidak berubah.")
    write_json(args.report, report)
    print("Laporan:", args.report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--apply", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
