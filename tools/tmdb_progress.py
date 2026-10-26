"""Print overall series TMDB matching/localization progress to GitHub Actions summary."""
import json
import os
from pathlib import Path

CATALOG = Path("assets/catalog/filmstream_catalog.json")
CACHE = Path("assets/catalog/tmdb_cache.jsonl")


def report():
    items = json.loads(CATALOG.read_text(encoding="utf-8"))["items"]
    series = {e["url"] for e in items if e.get("type") == "series"}
    cached = {}
    if CACHE.exists():
        for line in CACHE.read_text(encoding="utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                if record.get("source_url") in series:
                    cached[record["source_url"]] = record
    total = len(series)
    processed = len(cached)
    matched = sum(r.get("match_status") == "matched" and isinstance(r.get("tmdb_id"), int) for r in cached.values())
    unmatched = sum(r.get("match_status") == "unmatched" for r in cached.values())
    id_checked = sum(r.get("overview_id_checked") is True for r in cached.values())
    localized = sum(bool((r.get("overview_id") or "").strip()) for r in cached.values())
    pending = total - processed
    unclassified = processed - matched - unmatched
    percent = 100 * processed / total if total else 0
    status = "SEMUA SUDAH DIPERIKSA" if pending == 0 else "MASIH BERJALAN"
    lines = [
        "## FilmStream — Progres TMDB Series",
        "",
        f"**Status: {status}** · **{processed:,} / {total:,} ({percent:.2f}%)**",
        "",
        "| Metrik | Jumlah |",
        "|---|---:|",
        f"| Total series di katalog | {total:,} |",
        f"| Sudah diperiksa | {processed:,} |",
        f"| Belum diperiksa | {pending:,} |",
        f"| Cocok dengan TMDB | {matched:,} |",
        f"| Tidak cocok (butuh peninjauan) | {unmatched:,} |",
        f"| Status lain/tidak lengkap | {unclassified:,} |",
        f"| Sinopsis Indonesia tersedia dari TMDB | {localized:,} |",
        f"| Sudah dicek bahasa Indonesia | {id_checked:,} |",
        f"| Belum dicek bahasa Indonesia (dari yang cocok) | {matched - id_checked:,} |",
        "",
        "> Selesai diperiksa bukan berarti semuanya cocok atau memiliki sinopsis Indonesia.",
    ]
    summary = "\n".join(lines) + "\n"
    print(summary)
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if destination:
        with open(destination, "a", encoding="utf-8") as out:
            out.write(summary)


if __name__ == "__main__":
    report()
