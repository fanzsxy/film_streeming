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


# Stateless Source Manager: inspect supplied HTML, never treat embed as direct media.
from typing import Literal

class SourceManagerInspectInput(BaseModel):
    tmdb_id: int
    media_type: Literal["movie", "tv"]
    html: str
    page_url: str
    season: int = 0
    episode: int = 0

@app.post("/source-manager/inspect")
def source_manager_inspect(payload: SourceManagerInspectInput):
    if payload.tmdb_id < 1 or payload.season < 0 or payload.episode < 0:
        raise HTTPException(status_code=422, detail="Invalid TMDB ID, season or episode")
    try:
        inspection = parse_player_html(payload.html, payload.page_url)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    candidates = []
    for source in inspection["sources"]:
        kind = source["type"]
        candidates.append({**source, "native_player_ready": False,
                           "category": ("embed_only" if kind == "embed" else
                                        "direct_media_candidate" if kind in ("file_candidate", "manifest_candidate")
                                        else "unknown_candidate")})
    return {
        "tmdb_id": payload.tmdb_id, "media_type": payload.media_type,
        "season": payload.season, "episode": payload.episode,
        "title": inspection["title"], "page_url": inspection["page_url"],
        "source_count": len(candidates), "sources": candidates,
        "available_for_native_playback": False,
        "status": "inspection_only",
        "note": "No automatic fetching or storage. Media candidates are not verified; /resolve uses separately configured authorized MP4/HLS sources."
    }

# Read-only, versioned inspection catalog. Commit reviewed records to GitHub;
# do not write runtime state to Vercel's ephemeral filesystem.
INSPECTION_DB_PATH = Path(__file__).with_name('inspected_sources.json')

@app.get('/source-manager/catalog')
def source_manager_catalog(tmdb_id: int = Query(ge=1), media_type: Literal['movie', 'tv'] = 'movie', season: int = Query(default=0, ge=0), episode: int = Query(default=0, ge=0)):
    try:
        records = json.loads(INSPECTION_DB_PATH.read_text(encoding='utf-8'))
    except (FileNotFoundError, ValueError):
        raise HTTPException(500, 'Inspection catalog is missing or invalid')
    if not isinstance(records, list):
        raise HTTPException(500, 'Inspection catalog must be a list')
    for record in records:
        if not isinstance(record, dict):
            continue
        if (record.get('tmdb_id'), record.get('media_type'), record.get('season', 0), record.get('episode', 0)) != (tmdb_id, media_type, season, episode):
            continue
        sources = [
            {'name': s['name'], 'type': 'embed', 'url': s['url'],
             'status': 'unverified', 'native_player_ready': False}
            for s in record.get('sources', [])
            if isinstance(s, dict) and s.get('type') == 'embed'
            and isinstance(s.get('name'), str) and isinstance(s.get('url'), str)
            and s['url'].startswith('https://')
        ]
        return {'found': True, 'tmdb_id': tmdb_id, 'media_type': media_type,
                'season': season, 'episode': episode, 'title': record.get('title', ''),
                'page_url': record.get('page_url', ''), 'source_count': len(sources),
                'sources': sources, 'available_for_native_playback': False,
                'status': 'inspection_only',
                'note': 'Archived, manually inspected embed metadata; not a live availability check or playable stream.'}
    return {'found': False, 'tmdb_id': tmdb_id, 'media_type': media_type,
            'season': season, 'episode': episode, 'source_count': 0, 'sources': [],
            'available_for_native_playback': False, 'status': 'not_inspected'}
