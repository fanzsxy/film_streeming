"""Read-only audit of duplicate entries in the local FilmStream JSON.

Does not delete records, change type, or rewrite poster/URL metadata.
The source catalog, not Flutter display filtering, is the subject of this audit.
"""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

from tools.repair_catalog_types_by_domain import load_host_rules, expected_type
from tools.repair_catalog_missing_posters import write_json

CATALOG = Path("assets/catalog/filmstream_catalog.json")
REPORT = Path("crawler/data/catalog_duplicate_review.json")


def normalized(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").casefold())


def scan(document, rules):
    items = document.get("items") or []
    by_url, by_title_year = defaultdict(list), defaultdict(list)
    conflicts = []
    aliases = []
    for index, row in enumerate(items):
        if not isinstance(row, dict):
            continue
        url = str(row.get("url") or "").rstrip("/").casefold()
        title = normalized(row.get("title"))
        year = str(row.get("year") or "")
        if url:
            by_url[url].append(index)
        if title and year:
            by_title_year[(title, year)].append(index)
        domain_type = expected_type(row.get("url"), rules)
        if domain_type and row.get("type") != domain_type:
            conflicts.append({"index": index, "title": row.get("title"),
                              "url": row.get("url"), "type": row.get("type"),
                              "expected_type": domain_type})
        if title in {"100dayslies", "100daysoflies"}:
            aliases.append({"index": index, "title": row.get("title"),
                            "year": row.get("year"), "url": row.get("url"),
                            "type": row.get("type"), "poster_url": row.get("poster_url")})
    groups = []
    for category, source in (("same_url", by_url),
                             ("same_title_year", by_title_year)):
        for key, indices in source.items():
            if len(indices) < 2:
                continue
            groups.append({"category": category, "key": str(key),
                           "entries": [
                               {"index": i, "title": items[i].get("title"),
                                "year": items[i].get("year"),
                                "url": items[i].get("url"),
                                "type": items[i].get("type"),
                                "poster_url": items[i].get("poster_url")}
                               for i in indices]})
    return {"total": len(items), "duplicate_groups": groups,
            "duplicate_group_count": len(groups),
            "domain_type_conflicts": conflicts,
            "alias_100_days_lies_review": aliases}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--domains", type=Path, default=Path("config/source_domains.json"))
    p.add_argument("--report", type=Path, default=REPORT)
    args = p.parse_args()
    document = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    result = scan(document, load_host_rules(args.domains))
    write_json(args.report, result)
    print("TOTAL KATALOG:", result["total"])
    print("GRUP DUPLIKAT URL/JUDUL-TAHUN:", result["duplicate_group_count"])
    print("TYPE TIDAK SESUAI DOMAIN:", len(result["domain_type_conflicts"]))
    print("100 DAYS LIES (perlu tinjauan):",
          len(result["alias_100_days_lies_review"]))
    for group in result["duplicate_groups"]:
        if any(normalized(row["title"]) == "gameofthrones" and
               str(row["year"]) == "2011" for row in group["entries"]):
            print("GAME OF THRONES:", json.dumps(group["entries"], ensure_ascii=False))
    print("Laporan:", args.report)
    print("READ ONLY: tidak mengubah atau menghapus entri katalog.")


if __name__ == "__main__":
    main()
