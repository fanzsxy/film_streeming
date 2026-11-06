"""Read-only audit of catalog title vs source URL slug, without network requests.

This detects suspicious *catalog* title/URL pairs. It cannot prove that the
live page displays the correct title; that requires a separate page inspection.
"""
import argparse
import csv
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlparse

from tools.audit_catalog_completeness import CATALOG

REPORT = Path("crawler/data/catalog_url_title_mismatches.json")
CSV = Path("crawler/data/catalog_url_title_mismatches.csv")
YEAR = re.compile(r"-(?:19|20)\d{2}$")
COPY_SUFFIX = re.compile(r"-(?:copy|duplicate|part|episode)-?\d+$")


def normalized(value):
    text = unicodedata.normalize("NFKD", str(value or "").casefold())
    return re.sub(r"[^a-z0-9]", "", "".join(
        c for c in text if not unicodedata.combining(c)))


def url_title(url):
    try:
        parsed = urlparse(str(url or "").strip())
        slug = unquote(parsed.path.rstrip("/").split("/")[-1])
    except ValueError:
        return "", ""
    if not slug:
        return "", ""
    stem = YEAR.sub("", slug)
    return normalized(stem), slug


def audit(document):
    counts = Counter()
    mismatches = []
    uncheckable = []
    for index, row in enumerate(document.get("items") or []):
        if not isinstance(row, dict):
            uncheckable.append({"index": index, "reason": "not_an_object"})
            continue
        url = row.get("url") or ""
        title = row.get("title") or ""
        name, slug = url_title(url)
        record = {"index": index, "title": title, "year": row.get("year"),
                  "type": row.get("type"), "url": url, "url_slug": slug}
        if not name or not normalized(title):
            uncheckable.append(record)
            continue
        counts["checkable"] += 1
        title_key = normalized(title)
        if title_key == name:
            counts["exact"] += 1
            continue
        # Review evidence, NOT proof of a wrong URL. Aliases, translations,
        # season markers, release-year differences, and slug aliases are common.
        record["reason"] = "title_url_slug_differ"
        mismatches.append(record)
    return {"total": len(document.get("items") or []),
            "exact_match_count": counts["exact"],
            "possible_mismatch_count": len(mismatches),
            "uncheckable_count": len(uncheckable),
            "possible_mismatches": mismatches,
            "uncheckable": uncheckable}


def run(args):
    document = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    result = audit(document)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    with args.csv.open("w", encoding="utf-8-sig", newline="") as stream:
        fields = ("index", "title", "year", "type", "url", "url_slug", "reason")
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(result["possible_mismatches"])
    print("TOTAL KATALOG:", result["total"])
    print("JUDUL SESUAI SLUG URL:", result["exact_match_count"])
    print("PERLU DITINJAU (JUDUL != SLUG):", result["possible_mismatch_count"])
    print("TIDAK BISA DIBANDINGKAN:", result["uncheckable_count"])
    for row in result["possible_mismatches"][:20]:
        print(" ", row["title"], "|", row["url"])
    print("Laporan:", args.report, "dan", args.csv)
    print("READ ONLY: judul berbeda dari slug belum membuktikan halaman salah.")
    print("Audit ini tidak membuka halaman web; judul LIVE belum diverifikasi.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--csv", type=Path, default=CSV)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
