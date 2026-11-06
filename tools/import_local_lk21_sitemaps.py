"""Import locally saved LK21 post sitemaps into FilmStream catalog.

No network requests. Default DRY RUN; --apply backs up the catalog and writes
atomically. Sitemap slugs provide PROVISIONAL titles, not verified metadata.
"""
import argparse
import json
import os
import re
import unicodedata
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

CATALOG = Path("assets/catalog/filmstream_catalog.json")
SITEMAPS = Path("coba sitemap")
REPORT = Path("crawler/data/local_sitemap_import_report.json")
HOST = "tv12.lk21official.cc"
YEAR = re.compile(r"^(.+)-(19\d{2}|20\d{2})$")
SITEMAP_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"


def identity(title, year):
    plain = unicodedata.normalize("NFKD", str(title).casefold())
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    return (re.sub(r"[^a-z0-9]", "", plain), str(year))


def clean_url(raw):
    url = urlparse(str(raw).strip())
    if (url.scheme != "https" or url.hostname != HOST or url.port is not None
            or url.username or url.password or url.query or url.fragment
            or not url.path or url.path == "/" or "//" in url.path):
        return None
    segments = url.path.strip("/").split("/")
    if len(segments) != 1:
        return None
    slug = segments[0].lower()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
        return None
    return f"https://{HOST}/{slug}"


def parse_slug(url, start_year, end_year):
    slug = url.rsplit("/", 1)[-1]
    match = YEAR.fullmatch(slug)
    if not match:
        return None
    stem, year_text = match.groups()
    year = int(year_text)
    if not start_year <= year <= end_year:
        return None
    parts = stem.split("-")
    # Numeric suffixes like "godzilla-2014-2" may encode a duplicate URL.
    # Ambiguous release-year markers inside the title require review.
    if len(parts) < 1 or any(re.fullmatch(r"(19|20)\d{2}", p) for p in parts):
        return None
    title = " ".join(parts).strip().title()
    if not title or len(title) > 180 or not re.search("[a-z]", stem):
        return None
    return {"title": title, "year": year, "url": url, "type": "movie",
            "metadata_status": "sitemap_slug_unverified"}


def load_sitemap(path):
    root = ET.parse(path).getroot()
    if root.tag != SITEMAP_NS + "urlset":
        raise ValueError(f"{path}: not an XML sitemap urlset")
    return [elem.text.strip() for elem in root.findall(
        f"{SITEMAP_NS}url/{SITEMAP_NS}loc") if elem.text and elem.text.strip()]


def preview(catalog, paths, start_year, end_year):
    items = catalog.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Katalog kosong/tidak valid; tidak akan diubah")
    known_urls = {str(item.get("url", "")).rstrip("/").lower() for item in items
                  if isinstance(item, dict)}
    known_names = {identity(item.get("title", ""), item.get("year", ""))
                   for item in items if isinstance(item, dict)
                   and item.get("type") in ("movie", "series", "tv")}
    additions, review = [], []
    stats = Counter()
    for path in paths:
        locations = load_sitemap(path)
        stats["sitemap_files"] += 1
        stats["sitemap_url_entries"] += len(locations)
        for raw in locations:
            url = clean_url(raw)
            if url is None:
                stats["invalid_url"] += 1
                review.append({"url": raw, "reason": "invalid_url"})
                continue
            if url.lower() in known_urls:
                stats["existing_url_or_repeated"] += 1
                continue
            row = parse_slug(url, start_year, end_year)
            if row is None:
                stats["ambiguous_or_outside_year_range"] += 1
                review.append({"url": url, "reason": "ambiguous_or_outside_year_range"})
                continue
            key = identity(row["title"], row["year"])
            if key in known_names:
                stats["existing_title_year_or_repeated"] += 1
                known_urls.add(url.lower())
                continue
            additions.append(row)
            known_urls.add(url.lower())
            known_names.add(key)
    stats["new_provisional"] = len(additions)
    return additions, review, dict(stats)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sitemap-dir", type=Path, default=SITEMAPS)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--report", type=Path, default=REPORT)
    parser.add_argument("--start-year", type=int, default=1900)
    parser.add_argument("--end-year", type=int, default=datetime.now().year + 1)
    parser.add_argument("--apply", action="store_true",
                        help="Append provisional movie entries after backup")
    args = parser.parse_args()
    if args.start_year > args.end_year:
        parser.error("start-year must be <= end-year")
    paths = [args.sitemap_dir / f"sitemap-posts-{n}.xml" for n in range(1, 9)]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        parser.error("8 sitemap files required; missing: " + ", ".join(missing))
    raw = args.catalog.read_bytes()
    catalog = json.loads(raw.decode("utf-8-sig"))
    additions, review, stats = preview(catalog, paths, args.start_year, args.end_year)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": "locally_saved_sitemap_posts", "stats": stats,
              "provisional_additions": additions, "needs_review": review,
              "applied": False}
    print("Sitemap scan:", stats, flush=True)
    print("Catatan: judul dari slug URL; tanpa poster/TMDB dan belum diverifikasi.", flush=True)
    if not args.apply:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")
        print(f"DRY RUN: katalog tidak berubah. Laporan: {args.report}", flush=True)
        return
    if not additions:
        print("Tidak ada film baru untuk dimasukkan.", flush=True)
        return
    backup = args.catalog.with_name(
        args.catalog.stem + ".backup_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ".json")
    backup.write_bytes(raw)
    catalog["items"].extend(additions)
    temp = args.catalog.with_suffix(".sitemap_import.tmp")
    try:
        temp.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n",
                        encoding="utf-8")
        os.replace(temp, args.catalog)
    finally:
        if temp.exists():
            temp.unlink()
    report["applied"] = True
    report["backup"] = str(backup)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    print(f"Ditambahkan {len(additions)} entri sementara. Backup: {backup}", flush=True)


if __name__ == "__main__":
    main()
