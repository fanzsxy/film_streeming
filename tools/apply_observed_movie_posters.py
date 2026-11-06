"""Apply five directly observed LK21 movie OG poster URLs to the local catalog.

The URLs were recorded from a headed Chromium detail-page inspection and
supplied by the user. No title search or browser is needed here.
Default dry-run. --apply makes a timestamped backup first and changes only
poster_url on exactly matching movie URL/title/year rows.
"""
import argparse
import json
from datetime import datetime
from pathlib import Path

from tools.audit_catalog_completeness import good_poster
from tools.repair_catalog_missing_posters import CATALOG, save_catalog

# Keyed by the *existing* catalog source URL, not title search results.
OBSERVED = {
    "https://tv12.lk21official.cc/avatar-fire-ash-2025": (
        "Avatar: Fire and Ash", 2025,
        "https://poster.assetsy.de/wp-content/uploads/2025/12/film-avatar-fire-ash-2025-lk21.jpg",
    ),
    "https://tv12.lk21official.cc/avatar-the-way-of-water-2022": (
        "Avatar: The Way of Water", 2022,
        "https://poster.assetsy.de/wp-content/uploads/2022/12/film-avatar-the-way-of-water-2022-lk21-d21.jpg",
    ),
    "https://tv12.lk21official.cc/the-kings-avatar-for-the-glory-quan-zhi-gao-shou-zhi-dian-feng-rong-yao-2019": (
        "The King's Avatar: For the Glory (Quan zhi gao shou zhi dian feng rong yao)", 2019,
        "https://poster.assetsy.de/wp-content/uploads/2019/10/film-the-kings-avatar-for-the-glory-quan-zhi-gao-shou-zhi-dian-feng-rong-yao-2019-lk21.jpg",
    ),
    "https://tv12.lk21official.cc/avatar-2009": (
        "Avatar", 2009,
        "https://poster.assetsy.de/wp-content/uploads/2016/01/film-avatar-2009.jpg",
    ),
    "https://tv12.lk21official.cc/mahavatar-narsimha-2025": (
        "Mahavatar Narsimha", 2025,
        "https://poster.assetsy.de/wp-content/uploads/2025/09/film-mahavatar-narsimha-2025-lk21.jpg",
    ),
}


def proposed_updates(catalog):
    pending, rejected = [], []
    seen = set()
    for index, row in enumerate(catalog.get("items") or []):
        if not isinstance(row, dict):
            continue
        url = str(row.get("url") or "").strip().rstrip("/")
        if url not in OBSERVED:
            continue
        name, year, poster = OBSERVED[url]
        seen.add(url)
        if (row.get("type") != "movie" or row.get("title") != name
                or str(row.get("year")) != str(year) or not good_poster(poster)):
            rejected.append((index, url, "title/year/type mismatch"))
        elif good_poster(row.get("poster_url")):
            rejected.append((index, url, "already has valid poster"))
        else:
            pending.append((index, url, poster))
    missing = sorted(set(OBSERVED) - seen)
    return pending, rejected, missing


def run(catalog_path, apply):
    catalog = json.loads(catalog_path.read_text(encoding="utf-8-sig"))
    updates, rejected, missing = proposed_updates(catalog)
    for index, url, poster in updates:
        print(f"Siap [{index}]: {url}\n  Poster: {poster}", flush=True)
    for index, url, reason in rejected:
        print(f"Lewati [{index}]: {url} ({reason})", flush=True)
    for url in missing:
        print(f"Tidak ada dalam katalog: {url}", flush=True)
    print("Poster siap dipasang:", len(updates), "| tidak cocok/sudah ada:",
          len(rejected), "| tidak ditemukan:", len(missing))
    if apply and updates:
        backup = catalog_path.with_name(
            catalog_path.stem + ".backup_" +
            datetime.now().strftime("%Y%m%d_%H%M%S_%f") + catalog_path.suffix)
        backup.write_bytes(catalog_path.read_bytes())
        for index, _, poster in updates:
            catalog["items"][index]["poster_url"] = poster
        save_catalog(catalog_path, catalog)
        print("Backup:", backup)
        print("Poster dipasang:", len(updates))
    elif not apply:
        print("DRY RUN: katalog tidak berubah. --apply untuk memasang hasil.")
    else:
        print("Tidak ada perubahan.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=CATALOG)
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    run(args.catalog, args.apply)


if __name__ == "__main__":
    main()
