"""Secure, review-only upload of locally scanned catalog metadata to GitHub."""
import base64
import hmac
import json
import os
import re
from datetime import datetime, timezone
from uuid import uuid4
from urllib.parse import urlparse

import requests
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

router = APIRouter()
REPO = "fanzsxy/film_streeming"
HOSTS = {"movie": "tv12.lk21official.cc", "series": "tv.lk21online.de"}


class PhoneImport(BaseModel):
    items: list[dict] = Field(min_length=1, max_length=500)


def github(method, path, token, **kwargs):
    response = requests.request(
        method, "https://api.github.com" + path,
        headers={"Authorization": "Bearer " + token,
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
        timeout=25, **kwargs,
    )
    if not response.ok:
        raise HTTPException(502, "GitHub API rejected catalog PR operation")
    return response.json()


@router.post("/catalog/submit")
def submit_catalog(payload: PhoneImport, x_filmstream_sync_key: str = Header(default="")):
    configured = os.environ.get("FILMSTREAM_SYNC_KEY", "")
    token = os.environ.get("FILMSTREAM_GITHUB_TOKEN", "")
    if not configured or not token:
        raise HTTPException(503, "Catalog sync not configured on server")
    if not hmac.compare_digest(x_filmstream_sync_key, configured):
        raise HTTPException(401, "Invalid sync key")
    result = []
    used = set()
    for row in payload.items:
        kind = row.get("type")
        if kind not in HOSTS:
            continue
        title = re.sub(r"\\s+", " ", str(row.get("title") or "")).strip()
        url = str(row.get("url") or "").strip()
        try:
            year = int(row.get("year"))
        except (ValueError, TypeError):
            continue
        parsed = urlparse(url)
        if (not title or len(title) > 180 or not 1900 <= year <= datetime.now(timezone.utc).year + 2
            or parsed.scheme != "https" or parsed.hostname != HOSTS[kind] or parsed.port is not None
            or parsed.username or parsed.password or parsed.query or parsed.fragment):
            continue
        key = (kind, title.casefold(), year)
        if key in used:
            continue
        used.add(key)
        item = {"title": title, "year": year, "url": url, "type": kind}
        poster = str(row.get("poster_url") or "")
        img = urlparse(poster)
        if img.scheme == "https" and img.hostname and not img.username and not img.password:
            item["poster_url"] = poster
        rating = row.get("rating")
        if isinstance(rating, (int, float)) and not isinstance(rating, bool) and 0 < rating <= 10:
            item["rating"] = rating
        result.append(item)
    if not result:
        raise HTTPException(422, "No valid catalog entries")
    head = github("GET", f"/repos/{REPO}/git/ref/heads/main", token)["object"]["sha"]
    branch = "automation/phone-catalog-" + uuid4().hex[:12]
    github("POST", f"/repos/{REPO}/git/refs", token,
           json={"ref": "refs/heads/" + branch, "sha": head})
    filename = "crawler/imports/phone_" + branch.rsplit("-", 1)[1] + ".json"
    content = json.dumps({"version": 1, "source": "FilmStream Android WebView",
                          "items": result}, ensure_ascii=False, indent=2).encode()
    github("PUT", f"/repos/{REPO}/contents/{filename}", token,
           json={"message": "catalog: submit Android scanned titles for review",
                 "content": base64.b64encode(content).decode(), "branch": branch})
    pr = github("POST", f"/repos/{REPO}/pulls", token,
        json={"title": f"Review {len(result)} scanned FilmStream catalog titles",
              "head": branch, "base": "main",
              "body": "Phone scanner metadata submission. Review title, year, type, URLs and posters before merging. After merging, run Unify FilmStream crawler catalog to import these entries."})
    return {"status": "review_required", "submitted": len(result), "pull_request_url": pr["html_url"]}
