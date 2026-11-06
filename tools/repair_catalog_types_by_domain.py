"""Correct catalog movie/series types using the URL's *exact* trusted hostname.

The series hostnames come from config/source_domains.json, including legacy
domains. Never infer type from redirects, missing posters or title. Dry run is
default; --apply backs up catalog and modifies ONLY the 'type' field.
"""
import argparse
import json
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from tools.audit_catalog_completeness import valid_url
from tools.repair_catalog_missing_posters import save_catalog, write_json

CATALOG = Path("assets/catalog/filmstream_catalog.json")
DOMAINS = Path("config/source_domains.json")
REPORT = Path("crawler/data/catalog_type_by_host_report.json")
MOVIE_HOSTS = {"tv12.lk21official.cc"}


def load_host_rules(path=DOMAINS):
    config = json.loads(path.read_text(encoding="utf-8-sig"))
    series = config["series"]
    series_hosts = set()
    for key in ("legacy_hosts", "allowed_hosts"):
        for name in series.get(key, []):
            if not isinstance(name, str) or not name.strip():
                raise ValueError(f"Invalid series hostname in {key}")
            series_hosts.add(name.strip().lower())
    active_url = series.get("active_base_url", "")
    parsed = urlparse(active_url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("Invalid active series URL")
    series_hosts.add(parsed.hostname.lower())
    if not series_hosts or series_hosts & MOVIE_HOSTS:
        raise ValueError("Overlapping or missing movie and series host rules")
    return {"movie": set(MOVIE_HOSTS), "series": series_hosts}


def expected_type(url, rules):
    if not valid_url(url):
        return None
    parsed = urlparse(url.strip())
    # Bare hostname matching: no partial-domain or subdomain guessing.
    if parsed.port is not None:
        return None
    hostname = parsed.hostname.lower()
    if hostname in rules["movie"]:
        return "movie"
    if hostname in rules["series"]:
        return "series"
    return None


def scan(catalog, rules):
    items = catalog.get("items") if isinstance(catalog, dict) else None
    if not isinstance(items, list):
        raise ValueError("Invalid catalog items")
    changes, unknown = [], []
    counts = Counter()
    for index, row in enumerate(items):
        counts["total"] += 1
        if not isinstance(row, dict):
            unknown.append({"index": index, "reason": "invalid_row"})
            continue
        url = row.get("url")
        kind = expected_type(url, rules)
        if kind is None:
            counts["unknown_host"] += 1
            unknown.append({"index": index, "title": row.get("title"),
                            "url": url, "type": row.get("type"), "reason": "unrecognized_url_host"})
            continue
        counts["url_" + kind] += 1
        if row.get("type") == kind:
            counts["already_correct"] += 1
            continue
        counts["change_to_" + kind] += 1
        changes.append({"index": index, "title": row.get("title"),
                        "url": url, "old_type": row.get("type"), "new_type": kind})
    counts["changes"] = len(changes)
    return {"summary": dict(counts), "changes": changes, "unknown": unknown,
            "rules": {kind: sorted(hosts) for kind, hosts in rules.items()}}


def run(args):
    catalog = json.loads(args.catalog.read_text(encoding="utf-8-sig"))
    rules = load_host_rules(args.domains)
    report = scan(catalog, rules)
    summary = report["summary"]
    print("TOTAL KATALOG:", summary["total"])
    print("Movie berdasarkan URL:", summary.get("url_movie", 0))
    print("Series berdasarkan URL (termasuk domain lama):",
          summary.get("url_series", 0))
    print("Sudah sesuai:", summary.get("already_correct", 0))
    print("Perlu menjadi movie:", summary.get("change_to_movie", 0))
    print("Perlu menjadi series:", summary.get("change_to_series", 0))
    print("Domain tidak dikenal/tidak valid:", len(report["unknown"]))
    if args.apply and report["changes"]:
        backup = args.catalog.with_name(
            args.catalog.stem + ".backup_" +
            datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
        backup.write_bytes(args.catalog.read_bytes())
        for change in report["changes"]:
            catalog["items"][change["index"]]["type"] = change["new_type"]
        save_catalog(args.catalog, catalog)
        report["applied"] = len(report["changes"])
        report["backup"] = str(backup)
        print("Katalog diperbarui:", len(report["changes"]), "jenis.")
        print("Backup:", backup)
    else:
        report["applied"] = 0
        print("DRY RUN atau tidak ada perubahan: katalog tidak diubah.")
    write_json(args.report, report)
    print("Laporan:", args.report)
    print("Judul, URL, poster, sinopsis, dan metadata lain tidak diubah.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--domains", type=Path, default=DOMAINS)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--apply", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
