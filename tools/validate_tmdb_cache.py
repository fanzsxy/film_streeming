"""Validate and safely normalize the offline TMDB JSONL cache.

Malformed lines are excluded and reported; all parseable records are retained.
An excluded record will be fetched again by enrich_tmdb.py on a later run.
"""
import json
from pathlib import Path

PATH = Path("assets/catalog/tmdb_cache.jsonl")


def main():
    if not PATH.exists():
        print("TMDB cache not found; nothing to repair.")
        return
    raw = PATH.read_text(encoding="utf-8")
    lines = raw.splitlines()
    valid = []
    bad = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict) or not isinstance(record.get("source_url"), str):
                raise ValueError("No source_url")
            valid.append(record)
        except (json.JSONDecodeError, ValueError):
            bad.append((number, line))
    print(f"TMDB cache check: {len(valid)} valid records, {len(bad)} malformed lines.")
    if len(bad) > 20:
        raise SystemExit("Too many invalid records; refusing automatic cleanup.")
    if bad:
        # Preserve unparseable content for inspection in the workflow runner.
        backup = PATH.with_suffix(".bad-lines.txt")
        backup.write_text("".join(f"Line {n}: {line}\\n" for n, line in bad), encoding="utf-8")
        print("Malformed lines saved locally to:", backup)
    expected = "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in valid)
    if raw != expected:
        temp = PATH.with_suffix(".jsonl.tmp")
        temp.write_text(expected, encoding="utf-8")
        temp.replace(PATH)
        print("JSONL normalized. Missing items can be retried.")


if __name__ == "__main__":
    main()
