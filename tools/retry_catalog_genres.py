"""Conservative second pass for FilmStream titles without verified TMDB genres.

Only changes metadata in assets/catalog/filmstream_catalog.json.
Keeps all existing genre_ids and other fields unchanged.
Progress is stored per catalog item in genre_retry_status; no extra JSON files.
"""
import argparse
import difflib
import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse, unquote
from urllib.request import Request, urlopen

CATALOG = Path("assets/catalog/filmstream_catalog.json")
FINAL_STATES = {"unmatched", "ambiguous", "no_genres", "invalid_year"}
GENRE_NAMES = {
    28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
    80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
    14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
    9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
    10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    10759: "Action & Adventure", 10762: "Kids", 10763: "News",
    10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
    10767: "Talk", 10768: "War & Politics",
}


def normalized(value):
    return re.sub(r"[^a-z0-9]+", " ", str(value).casefold()).strip()


def genre_ids(value):
    if not isinstance(value, list) or not value:
        return None
    ids = [x.get("id") if isinstance(x, dict) else x for x in value]
    if not all(type(x) is int and x > 0 for x in ids):
        return None
    return list(dict.fromkeys(ids))


def year_of(record, media):
    date = str(record.get("release_date" if media == "movie" else "first_air_date") or "")
    return int(date[:4]) if re.match(r"^\d{4}", date) else None


def variants(item):
    title = str(item.get("title") or "").strip()
    no_parentheses = re.sub(r"\([^)]*\)", " ", title).strip()
    slug = unquote(urlparse(str(item.get("url") or "")).path.rstrip("/").rsplit("/", 1)[-1])
    slug = re.sub(r"-(?:19|20)\d{2}$", "", slug).replace("-", " ").strip()
    values = [title, no_parentheses, slug]
    dedup = {}
    for value in values:
        key = normalized(value)
        if key and len(key) >= 3 and key not in dedup:
            dedup[key] = value
    return list(dedup.values())[:3]


def tmdb_get(endpoint, params, token):
    url = "https://api.themoviedb.org/3/" + endpoint + "?" + urlencode(params)
    req = Request(url, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "User-Agent": "FilmStreamGenreRetry/1.0",
    })
    with urlopen(req, timeout=25) as response:
        return json.load(response)


def similarity(candidate, alternatives):
    names = [candidate.get(k) for k in
             ("title", "original_title", "name", "original_name")]
    names = [normalized(n) for n in names if isinstance(n, str) and n.strip()]
    return max((difflib.SequenceMatcher(None, normalized(v), n).ratio()
                for v in alternatives for n in names), default=0.0)


def verified(item, result, media, alternatives):
    release = year_of(result, media)
    try:
        expected = int(item.get("year"))
    except (ValueError, TypeError):
        return None
    if release is None or abs(release - expected) > 1:
        return None
    score = similarity(result, alternatives)
    if score < 0.94:
        return None
    return (score, release == expected)


def pick(item, results, media, alternatives):
    options = {}
    for result in results:
        if not isinstance(result, dict) or type(result.get("id")) is not int:
            continue
        rank = verified(item, result, media, alternatives)
        if rank:
            previous = options.get(result["id"])
            if previous is None or rank > previous[0]:
                options[result["id"]] = (rank, result)
    ordered = sorted(options.values(), key=lambda v: v[0], reverse=True)
    if not ordered:
        return None, "unmatched"
    if len(ordered) > 1 and (ordered[0][0][0] - ordered[1][0][0]) < 0.07:
        return None, "ambiguous"
    return ordered[0][1], None


def apply_genres(item, detail):
    ids = genre_ids(detail.get("genres"))
    if not ids:
        return False
    # Never overwrite previously verified metadata.
    if genre_ids(item.get("genre_ids")):
        return False
    raw = detail["genres"]
    if all(isinstance(x, dict) and isinstance(x.get("name"), str)
           and x.get("name", "").strip() for x in raw):
        names = [x["name"].strip() for x in raw]
    else:
        names = [GENRE_NAMES.get(i) for i in ids]
        if not all(names):
            return False
    item["genre_ids"] = ids
    item["genres"] = names
    lang = detail.get("original_language")
    if isinstance(lang, str) and lang.strip() and not item.get("original_language"):
        item["original_language"] = lang.strip()
    item["tmdb_id"] = detail["id"]
    item.pop("genre_retry_status", None)
    item.pop("genre_sync_status", None)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--delay", type=float, default=0.35)
    parser.add_argument("--github-output", default="")
    args = parser.parse_args()
    if not 0 <= args.limit <= 1000 or args.delay < 0.25:
        parser.error("limit must be 0..1000 and delay >= 0.25")

    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        parser.error("TMDB_TOKEN secret is required")
    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    attempted = filled = unresolved = 0
    paused = False
    for item in items:
        if attempted >= args.limit:
            break
        if item.get("type") not in ("movie", "series"):
            continue
        if genre_ids(item.get("genre_ids")) or item.get("genre_retry_status") in FINAL_STATES:
            continue
        media = "tv" if item["type"] == "series" else "movie"
        alternatives = variants(item)
        try:
            year = int(item.get("year"))
        except (ValueError, TypeError):
            year = 0
        if not alternatives or not 1900 <= year <= 2100:
            item["genre_retry_status"] = "invalid_year"
            unresolved += 1
            continue
        try:
            # Known IDs are checked, never assumed correct.
            known = item.get("tmdb_id")
            detail = None
            if type(known) is int and known > 0:
                try:
                    detail = tmdb_get(f"{media}/{known}", {"language": "en-US"}, token)
                except HTTPError as exc:
                    if exc.code == 404:
                        detail = None
                    else:
                        raise
                time.sleep(args.delay)
                if detail is not None and verified(item, detail, media, alternatives) is None:
                    detail = None
            if detail is None:
                results = []
                for title in alternatives[:2]:
                    params = {
                        "query": title, "language": "en-US", "include_adult": "false",
                        ("year" if media == "movie" else "first_air_date_year"): str(year),
                    }
                    response = tmdb_get(f"search/{media}", params, token)
                    time.sleep(args.delay)
                    results.extend(response.get("results", []))
                candidate, status = pick(item, results, media, alternatives)
                if candidate is None:
                    item["genre_retry_status"] = status
                    unresolved += 1
                    attempted += 1
                    continue
                detail = tmdb_get(f"{media}/{candidate['id']}", {"language": "en-US"}, token)
                time.sleep(args.delay)
                # Validate again: result and detail must refer to the same title and year.
                if detail.get("id") != candidate["id"] or verified(item, detail, media, alternatives) is None:
                    item["genre_retry_status"] = "ambiguous"
                    unresolved += 1
                    attempted += 1
                    continue
            if apply_genres(item, detail):
                filled += 1
            else:
                item["genre_retry_status"] = "no_genres"
                unresolved += 1
            attempted += 1
        except (HTTPError, URLError, TimeoutError, ValueError, KeyError) as exc:
            print(f"TMDB failure for {item.get('title')!r}: {exc}", flush=True)
            paused = True
            break
        if attempted % 100 == 0:
            print(f"Retry batch: {attempted} checked, {filled} recovered", flush=True)

    remaining = sum(x.get("type") in ("movie", "series")
                    and not genre_ids(x.get("genre_ids"))
                    and x.get("genre_retry_status") not in FINAL_STATES for x in items)
    total = sum(bool(genre_ids(x.get("genre_ids"))) for x in items)
    tmp = CATALOG.with_suffix(".retry.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(CATALOG)
    print(f"Genre available: {total}/{len(items)}")
    print(f"Second pass: attempted={attempted}; recovered={filled}; unresolved={unresolved}")
    print(f"Retry remaining={remaining}; paused={paused}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"pending={remaining}\n")
            out.write(f"attempted={attempted}\n")
            out.write(f"paused={'true' if paused else 'false'}\n")


if __name__ == "__main__":
    main()
