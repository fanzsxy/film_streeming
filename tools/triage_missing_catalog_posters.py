"""Triage remaining missing FilmStream posters without rerunning the crawler.

Read the current catalog and the two local Chromium checkpoints, then group all
missing poster rows by their *last observed* reason. Reuse only uniquely matched
poster URLs already saved in the catalog, prior sitemap results/state, or matched
TMDB cache. No network requests, no fresh TMDB search, no type/URL changes.
Default dry-run: --apply backs up the catalog and fills safe poster matches.
"""
import argparse
import json
from collections import Counter
from datetime import datetime
from pathlib import Path

from tools.repair_catalog_missing_posters import (
    CATALOG, RESULTS, TMDB_CACHE, PROGRESS, good_poster, poster_candidates,
    cache_posters, match_offline, save_catalog, write_json,
)
from tools.repair_catalog_types_by_domain import load_host_rules, expected_type

SITEMAP_PROGRESS = Path("crawler/data/local_sitemap_detail_progress.json")
REPORT = Path("crawler/data/remaining_missing_poster_triage.json")

def load_json(path, default):
    return json.loads(path.read_text(encoding="utf-8-sig")) if path.is_file() else default


def saved_sitemap_results(results, sitemap_state):
    data = {"verified": [], "age_restricted": []}
    for key in ("verified", "age_restricted"):
        data[key].extend(x for x in results.get(key, []) if isinstance(x, dict))
    for x in (sitemap_state.get("results") or {}).values():
        if isinstance(x, dict):
            data["verified"].append(x)
    return data


def group_status(status):
    if not status:
        return "not_checked"
    s = str(status).lower()
    if any(tag in s for tag in ("age_gate", "age_restrict", "restricted_age")):
        return "age_gate"
    if any(tag in s for tag in ("redirect", "moved")):
        return "redirect"
    if any(tag in s for tag in ("year_mismatch", "title_mismatch")):
        return "metadata_mismatch"
    if "search" in s or "ambiguous" in s:
        return "search_no_match"
    if any(tag in s for tag in ("poster", "heading", "detail")):
        return "detail_metadata_missing"
    if any(tag in s for tag in ("error", "denied", "blocked", "timeout", "unsupported")):
        return "access_or_navigation"
    return "other"


def status_for(url, poster_state, sitemap_state):
    key = url.rstrip("/")
    searched = (poster_state.get("search_checked") or {}).get(key)
    checked = (poster_state.get("checked") or {}).get(key)
    # A failed search is not proof an actual detail page was absent.
    sitemap = (sitemap_state.get("completed") or {}).get(key)
    observed = searched or checked or sitemap
    return {"status": observed or "not_checked",
            "category": group_status(observed),
            "poster_detail_status": checked,
            "search_status": searched,
            "sitemap_status": sitemap}


def analyze(catalog, poster_state, sitemap_state, prior_results, cached, rules):
    by_url, by_name = poster_candidates(catalog, saved_sitemap_results(prior_results, sitemap_state))
    grouped = Counter()
    entries = []
    recovered = []
    for index, row in enumerate(catalog.get("items") or []):
        if not isinstance(row, dict) or good_poster(row.get("poster_url")):
            continue
        url = str(row.get("url") or "").rstrip("/")
        expected = expected_type(url, rules)
        if expected is not None and row.get("type") != expected:
            raise ValueError(f"Catalog type/domain mismatch at index {index}: {url}")
        detail = status_for(url, poster_state, sitemap_state)
        poster, source = match_offline(row, by_url, by_name, cached)
        if not good_poster(poster):
            poster = None
        item = {"index": index, "title": row.get("title"), "year": row.get("year"),
                "type": row.get("type"), "url": url,
                **detail, "offline_match": source if poster else None}
        if poster:
            recovered.append({"index": index, "url": url, "poster_url": poster, "source": source})
            item["category"] = "recoverable_offline"
        grouped[item["category"]] += 1
        entries.append(item)
    return {"total_missing": len(entries), "by_category": dict(grouped),
            "recoverable_offline": len(recovered), "rows": entries,
            "proposed_fixes": recovered}


def run(args):
    catalog = load_json(args.catalog, {})
    if not isinstance(catalog.get("items"), list):
        raise SystemExit("Catalog must have an items list")
    poster_state = load_json(args.progress, {})
    sitemap_state = load_json(args.sitemap_progress, {})
    prior_results = load_json(args.results, {})
    cache = cache_posters(args.cache)
    rules = load_host_rules(args.domains)
    report = analyze(catalog, poster_state, sitemap_state, prior_results, cache, rules)
    print("POSTER KOSONG/TIDAK VALID:", report["total_missing"])
    print("DAPAT DIPULIHKAN DARI DATA LOKAL:", report["recoverable_offline"])
    for kind, count in sorted(report["by_category"].items(), key=lambda x: (-x[1], x[0])):
        print(f"  {kind}: {count}")
    applied = 0
    if args.apply and report["proposed_fixes"]:
        backup = args.catalog.with_name(
            args.catalog.stem + ".backup_" +
            datetime.now().strftime("%Y%m%d_%H%M%S_%f") + args.catalog.suffix)
        backup.write_bytes(args.catalog.read_bytes())
        for fix in report["proposed_fixes"]:
            item = catalog["items"][fix["index"]]
            if not good_poster(item.get("poster_url")) and good_poster(fix["poster_url"]):
                item["poster_url"] = fix["poster_url"]
                applied += 1
        if applied:
            save_catalog(args.catalog, catalog)
        report["backup"] = str(backup)
        print("Backup katalog:", backup)
    report["applied"] = applied
    write_json(args.output, report)
    print("BERHASIL DIPERBAIKI:", applied)
    print("SISA POSTER TIDAK LENGKAP:", report["total_missing"] - applied)
    print("Laporan:", args.output)
    if not args.apply:
        print("DRY RUN: katalog tidak diubah. --apply untuk pemulihan offline yang cocok.")
    print("Tidak membuka Chromium atau menggunakan TMDB API.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--results", type=Path, default=RESULTS)
    parser.add_argument("--sitemap-progress", type=Path, default=SITEMAP_PROGRESS)
    parser.add_argument("--progress", type=Path, default=PROGRESS)
    parser.add_argument("--cache", type=Path, default=TMDB_CACHE)
    parser.add_argument("--domains", type=Path, default=Path("config/source_domains.json"))
    parser.add_argument("--output", type=Path, default=REPORT)
    parser.add_argument("--apply", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
