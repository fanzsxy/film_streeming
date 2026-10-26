"""Offline cleanup of retired episode scrape and series release years.

Run from repository root, with all crawlers stopped:
  py crawler/cleanup_series_metadata.py
Creates timestamped backup. Does not fetch websites or change film records.
"""
import json
import re
from datetime import datetime
from pathlib import Path

PATH = Path("crawler/data/detail_metadata.json")
TRAILING_YEAR = re.compile(r"-(19\d{2}|20\d{2})/?$")


def main():
    if not PATH.is_file():
        raise SystemExit(f"Missing: {PATH}")
    original = PATH.read_bytes()
    data = json.loads(original.decode("utf-8-sig"))
    removed, corrected = 0, 0
    for url, item in data.items():
        if item.get("type") != "series":
            continue
        had = False
        for key in ("episodes", "episode_status"):
            if key in item:
                del item[key]
                had = True
        removed += int(had)
        # The final four-digit slug component is the release year for this source.
        # This corrects titles such as 2099-2025 and wolf-2039-2021.
        match = TRAILING_YEAR.search(url.split("?", 1)[0])
        if match:
            year = int(match.group(1))
            if str(item.get("year")) != str(year):
                item["year"] = year
                corrected += 1
    if not removed and not corrected:
        print("Nothing to clean.")
        return
    backup = PATH.with_name(f"detail_metadata.backup_series_{datetime.now():%Y%m%d_%H%M%S}.json")
    backup.write_bytes(original)
    temp = PATH.with_suffix(".series-cleanup.tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(PATH)
    print(f"Series episode fields cleared: {removed}")
    print(f"Series release years corrected: {corrected}")
    print(f"Backup: {backup}")
    print("Poster, synopsis, rating, genres, source URLs and all movie records retained.")


if __name__ == "__main__":
    main()
