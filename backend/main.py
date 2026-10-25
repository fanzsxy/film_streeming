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


# Optional Gemini fallback for deciding between ALREADY-DISCOVERED metadata candidates.
# Never allows Gemini to invent source URLs, and never exposes the API key to Flutter.
import os
import re
import requests
from typing import Literal

class AiMatchCandidate(BaseModel):
    title: str
    year: str = ""
    url: str

class AiMatchRequest(BaseModel):
    title: str
    year: str
    media_type: Literal["movie", "tv"]
    candidates: list[AiMatchCandidate]

@app.post("/ai/match")
def ai_match(payload: AiMatchRequest):
    from urllib.parse import urlparse
    if not 2 <= len(payload.title) <= 180 or not re.fullmatch(r"(?:19|20)\d{2}", payload.year):
        raise HTTPException(status_code=422, detail="Invalid film metadata")
    if not 1 <= len(payload.candidates) <= 12:
        raise HTTPException(status_code=422, detail="Supply 1-12 observed candidates")
    observed = []
    for item in payload.candidates:
        u = urlparse(item.url)
        if u.scheme != "https" or not u.hostname or not (
            u.hostname == "lk21official.cc" or u.hostname.endswith(".lk21official.cc")
        ):
            raise HTTPException(status_code=422, detail="Source URL must be a recognized HTTPS site")
        if len(item.title) > 180 or len(item.year) > 8 or len(item.url) > 500:
            raise HTTPException(status_code=422, detail="Candidate field too long")
        observed.append({"title": item.title, "year": item.year, "url": item.url})
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not key:
        return {"status": "not_configured", "matched": False}
    model = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
    if not re.fullmatch(r"gemini-[a-z0-9.-]+", model):
        raise HTTPException(status_code=500, detail="Invalid configured Gemini model")
    instruction = (
        "Compare TMDB film/TV metadata against webpage search candidates. "
        "Select an index ONLY if the candidate clearly names the same work and "
        "year is identical or within 1 year. Do not invent data or infer availability. "
        "If uncertainty remains, return index -1. Output JSON object "
        'with exactly keys "index" (integer) and "confidence" (number from 0 to 1).'
    )
    request_payload = {"contents": [{"role": "user", "parts": [{"text":
        instruction + "\nTMDB: " + json.dumps({"title": payload.title,
        "year": payload.year, "media_type": payload.media_type}, ensure_ascii=False) +
        "\nObserved candidates: " + json.dumps(
          [{"index": n, "title": x["title"], "year": x["year"]} for n,x in enumerate(observed)],
          ensure_ascii=False)
    }]}], "generationConfig": {"responseMimeType": "application/json",
        "temperature": 0, "maxOutputTokens": 140}}
    try:
        response = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            headers={"x-goog-api-key": key, "Content-Type": "application/json"},
            json=request_payload, timeout=8)
        response.raise_for_status()
        answer = response.json()["candidates"][0]["content"]["parts"][0]["text"]
        decision = json.loads(answer)
        index = decision.get("index", -1)
        confidence = float(decision.get("confidence", 0))
        if type(index) is not int or not 0 <= index < len(observed) or confidence < 0.9:
            return {"status": "no_confident_match", "matched": False}
        selected = observed[index]
        year_match = re.search(r"(?:19|20)\d{2}", selected["year"])
        if year_match:
            if abs(int(year_match.group()) - int(payload.year)) > 1:
                return {"status": "year_mismatch", "matched": False}
        else:
            # Missing year is not a conflicting year. Only permit an
            # undated result when its full normalized English title agrees.
            normalize = lambda value: re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()
            if normalize(selected["title"]) != normalize(payload.title):
                return {"status": "year_unverified", "matched": False}
        return {"status": "matched", "matched": True, "url": selected["url"]}
    except (requests.RequestException, ValueError, KeyError, IndexError, TypeError):
        return {"status": "unavailable", "matched": False}
