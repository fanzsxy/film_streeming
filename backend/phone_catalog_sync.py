"""Secure, review-only upload of locally scanned catalog metadata to GitHub."""
import base64
import hmac
import json
import os
import re
import logging
from datetime import datetime, timezone
from uuid import uuid4
from urllib.parse import urlparse

import requests
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)
router = APIRouter()
REPO = "fanzsxy/film_streeming"
HOSTS = {"movie": {"tv12.lk21official.cc"},
         "series": {"tv.lk21online.de", "tv9.nontondrama.my", "tv.nontondrama.vip"}}


class PhoneImport(BaseModel):
    items: list[dict] = Field(min_length=1, max_length=100)


def github(method, path, token, **kwargs):
    response = requests.request(
        method, "https://api.github.com" + path,
        headers={"Authorization": "Bearer " + token,
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
        timeout=25, **kwargs,
    )
    if not response.ok:
        logger.error("Catalog GitHub operation failed: %s %s status=%s", method, path.split("?")[0], response.status_code)
        raise HTTPException(502, f"GitHub catalog operation failed: HTTP {response.status_code}")
    return response.json()


def source_identity(row):
    """Identity comes from the source URL, never a title/poster guess.

    Series aliases on the three supported hosts share one identity when
    their paths match. Movie identities use the actual movie source path.
    """
    kind = row.get("type")
    if kind == "tv":
        kind = "series"
    if kind not in HOSTS:
        return None
    try:
        uri = urlparse(str(row.get("url") or "").strip())
        if (uri.scheme != "https" or uri.hostname not in HOSTS[kind] or
                uri.username or uri.password or uri.port is not None or
                uri.query or uri.fragment or uri.params or
                not uri.path or uri.path == "/"):
            return None
        return kind, uri.path.rstrip("/").lower()
    except (TypeError, ValueError):
        return None


def known_source_identities(token):
    """Read main catalog + currently open scanner submissions.

    Fail closed if GitHub cannot be reached: do not generate duplicate PRs
    when upstream state is unknown.
    """
    raw = requests.get(
        f"https://raw.githubusercontent.com/{REPO}/main/assets/catalog/filmstream_catalog.json",
        timeout=35)
    if not raw.ok:
        raise HTTPException(502, "Cannot check current catalog before PR submission")
    try:
        catalog = raw.json()
        items = catalog["items"]
        if not isinstance(items, list):
            raise ValueError("Invalid catalog")
    except (ValueError, KeyError, TypeError):
        raise HTTPException(502, "Cannot decode current catalog")
    seen = set()
    for row in items:
        if isinstance(row, dict):
            key = source_identity(row)
            if key:
                seen.add(key)

    # Check all open scanner PRs, including submissions not yet in main.
    for page in range(1, 11):
        prs = github("GET", f"/repos/{REPO}/pulls", token,
                     params={"state": "open", "per_page": 100, "page": page})
        if not isinstance(prs, list):
            raise HTTPException(502, "Cannot enumerate open scan PRs")
        for pr in prs:
            head = pr.get("head") or {}
            name = head.get("ref", "")
            if not name.startswith("automation/phone-catalog-"):
                continue
            # The service writes one import file named after branch suffix.
            suffix = name.rsplit("-", 1)[-1]
            if not re.fullmatch(r"[a-f0-9]{12}", suffix):
                continue
            filename = f"crawler/imports/phone_{suffix}.json"
            file = github("GET", f"/repos/{REPO}/contents/{filename}",
                          token, params={"ref": name})
            try:
                decoded = base64.b64decode(file["content"]).decode("utf-8")
                pending = json.loads(decoded)["items"]
                if not isinstance(pending, list):
                    raise ValueError("Invalid PR import")
            except (KeyError, ValueError, TypeError):
                raise HTTPException(502, "Cannot inspect an open scan PR")
            for row in pending:
                if isinstance(row, dict):
                    key = source_identity(row)
                    if key:
                        seen.add(key)
        if len(prs) < 100:
            break
    else:
        raise HTTPException(503, "Too many open PRs to verify safely")
    return seen


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
        if len(url) > 700:
            continue
        parsed = urlparse(url)
        if (not title or len(title) > 180 or not 1900 <= year <= datetime.now(timezone.utc).year + 2
            or parsed.scheme != "https" or parsed.hostname not in HOSTS[kind] or parsed.port is not None
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.params or not parsed.path.startswith("/")):
            continue
        key = source_identity({"type": kind, "url": url})
        if key is None or key in used:
            continue
        used.add(key)
        item = {"title": title, "year": year, "url": url, "type": kind}
        poster = str(row.get("poster_url") or "")
        try:
            img = urlparse(poster) if len(poster) <= 900 else urlparse("")
            poster_ok = (img.scheme == "https" and bool(img.hostname)
                         and not img.username and not img.password
                         and img.port is None and not img.query and not img.fragment)
        except ValueError:
            poster_ok = False
        if poster_ok:
            item["poster_url"] = poster
        rating = row.get("rating")
        if isinstance(rating, (int, float)) and not isinstance(rating, bool) and 0 < rating <= 10:
            item["rating"] = rating
        result.append(item)
    if not result:
        raise HTTPException(422, "No valid catalog entries")
    known = known_source_identities(token)
    missing = [row for row in result if source_identity(row) not in known]
    if not missing:
        return {"status": "already_known", "submitted": 0,
                "skipped": len(result), "pull_request_url": None}
    skipped = len(result) - len(missing)
    result = missing
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
    return {"status": "review_required", "submitted": len(result),
            "skipped": skipped, "pull_request_url": pr["html_url"]}
