"""Audit (and optionally correct) movie/series types using SOURCE HOST ONLY.

Catalog policy:
  tv12.lk21official.cc -> movie
  tv.nontondrama.vip   -> series

Never search by title, follow redirects, or change URL, poster or year.
Default: read-only audit. --apply creates timestamped backup before type-only edits.
Unknown URL hosts are reported and never automatically changed.
"""
import argparse
import json
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.audit_catalog_completeness import CATALOG
from tools.repair_catalog_missing_posters import save_catalog, write_json

REPORT = Path("crawler/data/catalog_type_by_domain_report.json")
DOMAINS = {"tv12.lk21official.cc": "movie", "tv.nontondrama.vip": "series"}


def expected_type(url):
    if not isinstance(url, str):
        return None
    try:
        parsed = urlparse(url.strip())
        if (parsed.scheme != "https" or parsed.username or parsed.password
                or parsed.port is not None):
            return None
        return DOMAINS.get(parsed.hostname or "")
    except ValueError:
        return None


def audit(document):
    wrong, unknown = [], []
    counts = Counter()
    for index, row in enumerate(document.get("items") or []):
        if not isinstance(row, dict):
            unknown.append({"index": index, "reason": "invalid_row"})
            continue
        source = row.get("url")
        desired = expected_type(source)
        if desired is None:
            unknown.append({"index": index, "title": row.get("title"),
                            "url": source, "type": row.get("type")})
            continue
        counts[desired] += 1
        actual = row.get("type")
        if actual not in (("series", "tv") if desired == "series" else ("movie",)):
            wrong.append({"index": index, "title": row.get("title"),
                          "url": source, "type": actual, "expected_type": desired})
    return {"total": len(document.get("items") or []),
            "expected_by_domain": dict(counts),
            "mismatches": wrong, "unknown_hosts": unknown,
            "mismatch_count": len(wrong), "unknown_count": len(unknown)}


def run(args):
    doc = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    result = audit(doc)
    write_json(args.report, result)
    print("TOTAL KATALOG:", result["total"])
    print("MOVIE (host tv12):", result["expected_by_domain"].get("movie", 0))
    print("SERIES (host nontondrama):",
          result["expected_by_domain"].get("series", 0))
    print("TYPE TIDAK SESUAI HOST:", result["mismatch_count"])
    print("HOST TIDAK DIKENAL:", result["unknown_count"])
    for row in result["mismatches"][:20]:
        print("  ", row["type"], "->", row["expected_type"], "|",
              row["title"], "|", row["url"])
    print("Laporan:", args.report)
    if not args.apply:
        print("READ ONLY: katalog tidak diubah. --apply untuk memperbaiki type saja.")
        return
    if not result["mismatches"]:
        print("Tidak ada type yang perlu diubah.")
        return
    backup = args.catalog.with_name(
        args.catalog.stem + ".backup_" +
        datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
    backup.write_bytes(args.catalog.read_bytes())
    for row in result["mismatches"]:
        doc["items"][row["index"]]["type"] = row["expected_type"]
    save_catalog(args.catalog, doc)
    print("Backup:", backup)
    print("TYPE DIPERBAIKI:", result["mismatch_count"])
    print("URL, judul, poster, dan tahun tidak diubah.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--apply", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
