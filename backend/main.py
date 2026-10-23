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


# Optional public-page metadata research (not a playback provider).
from lk21_scraper import latest as lk21_latest, parse_detail as lk21_detail

@app.get("/lk21/latest")
def lk21_catalog(limit: int = Query(default=20, ge=1, le=40)):
    return lk21_latest(limit)

@app.get("/lk21/detail")
def lk21_page(path: str = Query(min_length=2, max_length=180)):
    return lk21_detail(path)


@app.get("/search/{title}")
def search_public_pages(title: str):
    """Compatibility endpoint for FilmStream's existing external-page search UI.

    Matches only titles present in the current public latest-page listing.
    This is NOT full-site search and does not supply any playable media.
    """
    query = title.strip().casefold()
    if len(query) < 2 or len(query) > 120:
        raise HTTPException(status_code=422, detail="Title must be 2-120 characters")
    try:
        listing = lk21_latest(40)
    except HTTPException as exc:
        if exc.status_code in (403, 502, 503):
            return {
                "results": [],
                "status": "source_unavailable",
                "message": "LK21 metadata source is currently unavailable; search was not completed.",
                "diagnostic": exc.detail,
            }
        raise
    return {"results": [
        {"title": item["title"], "url": item["source_page"], "year": ""}
        for item in listing.get("items", [])
        if query in item["title"].casefold()
    ], "status": "ok", "note": "Matches current public latest listing only; metadata, not playback"}


@app.get("/")
def root():
    return {"app": "FilmStream Source API", "health": "/health", "docs": "/docs"}

# Offline parser: paste HTML saved from a page you can access. Does not fetch LK21.
from player_parser import parse_player_html

class PlayerHtmlInput(BaseModel):
    html: str
    page_url: str

@app.post('/inspect/player-html')
def inspect_player_html(payload: PlayerHtmlInput):
    try:
        return parse_player_html(payload.html, payload.page_url)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
