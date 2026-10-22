"""FilmStream authorized playback registry. Run with uvicorn main:app."""
import json
from pathlib import Path
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel

app = FastAPI(title="FilmStream Source API", version="1.0.0")
DB_PATH = Path(__file__).with_name("sources.json")

class Source(BaseModel):
    tmdb_id: int
    type: str
    season: int = 0
    episode: int = 0
    provider: str
    playback_type: str
    url: str
    subtitle_url: str = ""

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/resolve")
def resolve(tmdb_id: int = Query(ge=1), type: str = Query(pattern="^(movie|tv)$"), season: int = Query(default=0, ge=0), episode: int = Query(default=0, ge=0)):
    entries = json.loads(DB_PATH.read_text(encoding="utf-8"))
    for entry in entries:
        item = Source.model_validate(entry)
        if (item.tmdb_id, item.type, item.season, item.episode) != (tmdb_id, type, season, episode):
            continue
        if item.playback_type not in ("mp4", "hls") or not item.url.startswith("https://") or (item.subtitle_url and not item.subtitle_url.startswith("https://")):
            raise HTTPException(422, "Invalid source configuration")
        return {"available": True, "provider": item.provider, "playback": {"type": item.playback_type, "url": item.url}, "subtitle_url": item.subtitle_url}
    return {"available": False}
