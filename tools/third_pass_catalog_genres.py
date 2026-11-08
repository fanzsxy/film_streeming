"""Third-pass TMDB genre recovery: alternative titles, IMDb IDs and plot checks.

Conservative by design: only verifies missing genre_ids; keeps previous genres unchanged.
Progress markers live in the same catalog file (genre_third_status).
"""
import argparse
import difflib
import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from retry_catalog_genres import CATALOG, genre_ids, normalized, variants, year_of, apply_genres

FINAL = {"unmatched", "ambiguous", "no_genres", "invalid_year"}
STOPWORDS = set(("yang dan dengan dalam dari untuk pada adalah sebuah seorang ketika "
                 "setelah sebelum menjadi mereka dia ini itu tentang tetapi karena "
                 "film kisah cerita menemukan terjadi sebagai kemudian dirinya "
                 "the and with from into when their them that this after before "
                 "where who while been being movie story").split())


def api(endpoint, token, params=None):
    address = "https://api.themoviedb.org/3/" + endpoint
    if params:
        address += "?" + urlencode(params)
    req = Request(address, headers={
        "Authorization": "Bearer " + token, "Accept": "application/json",
        "User-Agent": "FilmStreamThirdGenrePass/1.0",
    })
    with urlopen(req, timeout=25) as res:
        return json.load(res)


def words(text):
    return {word for word in re.findall(r"\w+", str(text).casefold())
            if len(word) >= 3 and word not in STOPWORDS and not word.isdigit()}


def plot_overlap(source, overview):
    one, two = words(source), words(overview)
    if len(one) < 8 or len(two) < 8:
        return 0.0
    shared = len(one & two)
    if shared < 6:
        return 0.0
    return shared / min(len(one), len(two))


def title_score(item_titles, record_titles):
    a = [normalized(v) for v in item_titles]
    b = [normalized(v) for v in record_titles if v]
    return max((difflib.SequenceMatcher(None, x, y).ratio()
                for x in a for y in b if x and y), default=0.0)


def record_titles(media, detail, extra):
    keys = ("title", "original_title") if media == "movie" else ("name", "original_name")
    names = [detail.get(key) for key in keys]
    names.extend(x.get("title") or x.get("name")
                 for x in extra if isinstance(x, dict))
    return [x for x in names if isinstance(x, str) and x.strip()]


def candidate_year(item, detail, media):
    try:
        source_year = int(item.get("year"))
    except (TypeError, ValueError):
        return False
    year = year_of(detail, media)
    return year is not None and abs(year - source_year) <= 1


def imdb_from_item(item):
    for name in ("imdb_id", "imdb"):
        value = item.get(name)
        if isinstance(value, str) and re.fullmatch(r"tt\d{6,12}", value.strip()):
            return value.strip()
    return None


def search_candidates(item, media, token, delay):
    found = {}
    imdb = imdb_from_item(item)
    if imdb:
        found_result = api("find/" + imdb, token, {"external_source": "imdb_id"})
        time.sleep(delay)
        for value in found_result.get(("movie_results" if media == "movie" else "tv_results"), []):
            if type(value.get("id")) is int:
                found[value["id"]] = ("imdb", value)
    alt = variants(item)
    for title in alt[:3]:
        # Search without year, since film metadata may use a different premiere year.
        result = api("search/" + media, token, {
            "query": title, "language": "en-US", "include_adult": "false",
        })
        time.sleep(delay)
        for value in result.get("results", [])[:20]:
            if type(value.get("id")) is int:
                found.setdefault(value["id"], ("search", value))
    return found


def assess(item, media, token, delay):
    titles = variants(item)
    if not titles:
        return None, "unmatched"
    try:
        int(item.get("year"))
    except (TypeError, ValueError):
        return None, "invalid_year"

    records = search_candidates(item, media, token, delay)
    known = item.get("tmdb_id")
    if type(known) is int and known > 0:
        records.setdefault(known, ("known", {}))
    if not records:
        return None, "unmatched"

    # Before fetching details, rank by year and title. Preserve IMDb exact identity.
    ranked = []
    for tmdb_id, (origin, record) in records.items():
        if record and not candidate_year(item, record, media):
            continue
        quick = title_score(titles, record_titles(media, record, []))
        if origin == "imdb":
            quick += 2.0
        elif origin == "known":
            quick += 0.5
        ranked.append((quick, tmdb_id, origin))
    ranked.sort(reverse=True)
    # Limit API requests. Check all strong candidates and a few possible aliases.
    selected = ranked[:6]
    matches = []
    for _quick, tmdb_id, origin in selected:
        try:
            detail = api(media + "/" + str(tmdb_id), token, {"language": "en-US"})
        except HTTPError as exc:
            if exc.code == 404:
                continue
            raise
        time.sleep(delay)
        if not candidate_year(item, detail, media):
            continue

        # Look up alternate titles registered at TMDB.
        alternate_endpoint = ("alternative_titles" if media == "movie" else "alternative_titles")
        extra = api(media + "/" + str(tmdb_id) + "/" + alternate_endpoint, token)
        time.sleep(delay)
        entries = extra.get("titles" if media == "movie" else "results", [])
        names = record_titles(media, detail, entries)
        score = title_score(titles, names)
        plot = 0.0
        synopsis = item.get("synopsis") or ""
        if synopsis:
            overview_id = api(media + "/" + str(tmdb_id), token, {"language": "id-ID"})
            time.sleep(delay)
            plot = max(plot_overlap(synopsis, detail.get("overview", "")),
                       plot_overlap(synopsis, overview_id.get("overview", "")))

        # Independent identity evidence is required for name changes.
        # An IMDb exact match is sufficient with matching release year.
        trusted = (origin == "imdb" and imdb_from_item(item) is not None)
        accepted = trusted or score >= 0.965 or (score >= 0.57 and plot >= 0.68)
        if accepted:
            matches.append((100 if trusted else 3 * score + 2 * plot, tmdb_id, detail))
    matches.sort(reverse=True, key=lambda r: r[0])
    if not matches:
        return None, "unmatched"
    if len(matches) > 1 and matches[0][0] - matches[1][0] < 0.20:
        return None, "ambiguous"
    chosen = matches[0][2]
    if not genre_ids(chosen.get("genres")):
        return None, "no_genres"
    return chosen, None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--delay", type=float, default=0.35)
    p.add_argument("--github-output", default="")
    args = p.parse_args()
    if args.limit < 0 or args.limit > 500 or args.delay < 0.3:
        p.error("limit must be 0..500 and delay >= 0.3")
    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        p.error("TMDB_TOKEN secret is required")

    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    attempted = recovered = unresolved = 0
    paused = False
    for item in items:
        if attempted >= args.limit:
            break
        if item.get("type") not in ("movie", "series"):
            continue
        if genre_ids(item.get("genre_ids")) or item.get("genre_third_status") in FINAL:
            continue
        media = "movie" if item["type"] == "movie" else "tv"
        try:
            detail, status = assess(item, media, token, args.delay)
            if detail and apply_genres(item, detail):
                recovered += 1
                item.pop("genre_third_status", None)
            else:
                item["genre_third_status"] = status or "no_genres"
                unresolved += 1
            attempted += 1
        except (HTTPError, URLError, TimeoutError, KeyError, ValueError) as exc:
            print("TMDB transient failure; stopping batch safely:", str(exc), flush=True)
            paused = True
            break
        if attempted % 25 == 0:
            print(f"Third pass: {attempted} checked; {recovered} recovered", flush=True)

    pending = sum(item.get("type") in ("movie", "series")
                  and not genre_ids(item.get("genre_ids"))
                  and item.get("genre_third_status") not in FINAL for item in items)
    total = sum(bool(genre_ids(item.get("genre_ids"))) for item in items)
    temp = CATALOG.with_suffix(".third.tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(CATALOG)
    print(f"Genre available: {total}/{len(items)}")
    print(f"Third pass: attempted={attempted}; recovered={recovered}; unresolved={unresolved}")
    print(f"Third remaining={pending}; paused={paused}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"pending={pending}\nattempted={attempted}\npaused={str(paused).lower()}\n")


if __name__ == "__main__":
    main()
