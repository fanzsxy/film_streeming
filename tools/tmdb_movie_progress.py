"""Summarize offline TMDB movie coverage in GitHub Actions."""
import json
import os
from pathlib import Path

catalog=json.loads(Path("assets/catalog/filmstream_catalog.json").read_text(encoding="utf-8"))["items"]
movies={x["url"]:x for x in catalog if x.get("type")=="movie"}
cache={}
path=Path("assets/catalog/tmdb_cache.jsonl")
if path.exists():
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            x=json.loads(line)
            if x.get("source_url") in movies and x.get("tmdb_type")=="movie":
                cache[x["source_url"]]=x
total=len(movies)
processed=len(cache)
matched=sum(x.get("match_status")=="matched" and isinstance(x.get("tmdb_id"),int) for x in cache.values())
unmatched=sum(x.get("match_status")=="unmatched" for x in cache.values())
localized=sum(bool(x.get("overview_id")) for x in cache.values())
needs_synopsis=sum(not (x.get("synopsis") or "").strip() for x in movies.values())
result="\n".join([
    "## FilmStream — Progres TMDB Film",
    "",
    f"**{'SEMUA SUDAH DIPERIKSA' if processed==total else 'MASIH BERJALAN'}** — **{processed:,} / {total:,} ({processed/total*100 if total else 0:.2f}%)**",
    "",
    "| Metrik | Jumlah |","|---|---:|",
    f"| Film total | {total:,} |",
    f"| Film belum punya sinopsis di katalog | {needs_synopsis:,} |",
    f"| Diperiksa TMDB | {processed:,} |",
    f"| Belum diperiksa | {total-processed:,} |",
    f"| Cocok TMDB | {matched:,} |",
    f"| Belum cocok | {unmatched:,} |",
    f"| Sinopsis ID dari TMDB | {localized:,} |",
    "",
    "> Prioritas: film terbaru yang belum memiliki sinopsis. Pemeriksaan lengkap berbeda dari kecocokan TMDB."
])+"\n"
print(result)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"],"a",encoding="utf-8") as f:f.write(result)
