"""Clean implausible 12+ genre lists caused by global navigation scraping.

Run from repo root:
    py crawler/fix_cached_genres.py
Offline only: no web requests. Creates a timestamped backup once per run.
"""
import json
from datetime import datetime
from pathlib import Path

SOURCE = Path("crawler/data/detail_metadata.json")


def main():
    if not SOURCE.exists():
        raise SystemExit(f"Missing {SOURCE}")
    raw = SOURCE.read_bytes()
    data = json.loads(raw.decode("utf-8-sig"))
    suspicious = [(url, entry) for url, entry in data.items()
                  if isinstance(entry.get("genres"), list)
                  and len(entry["genres"]) >= 12]
    if not suspicious:
        print("No suspicious genre lists detected.")
        return
    backup = SOURCE.with_name(
        f"detail_metadata.backup_{datetime.now():%Y%m%d_%H%M%S}.json"
    )
    backup.write_bytes(raw)
    for url, entry in suspicious:
        entry["genres"] = []
    temp = SOURCE.with_suffix(".cleanup.tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(SOURCE)
    print(f"Cleared {len(suspicious)} suspicious genre lists.")
    print(f"Backup saved: {backup}")
    print("Poster, synopsis, rating, and URLs were not changed.")
    print("Missing genres can be filled using category_metadata.py where available.")


if __name__ == "__main__":
    main()
