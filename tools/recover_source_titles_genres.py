"""Recover full source-page titles for entries with truly empty genres, then verify TMDB.

Only mutate titles when the source H1 is confidently the same work. Do not
overwrite any preexisting genres. All results stay in the main catalog JSON.
"""
import argparse
import html
import json
import os
import re
import time
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from retry_catalog_genres import CATALOG, genre_ids, normalized
from third_pass_catalog_genres import assess
from recover_empty_catalog_genres import has_genres, apply_only_if_empty

PASS = "source_titles_and_genres_v2"
ALLOWED_HOSTS = ("lk21official.cc", "nontondrama.vip")
SOURCE_GENRES = {
    "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime",
    "Documentary", "Drama", "Family", "Fantasy", "History", "Horror",
    "Musical", "Music", "Mystery", "Romance", "Sci-Fi", "Science Fiction",
    "Sport", "Thriller", "War", "Western", "Reality", "Soap", "Kids",
    "TV Movie", "War & Politics", "Action & Adventure", "Sci-Fi & Fantasy",
}



class TitleParser(HTMLParser):
    """Read the film H1 and only genre tags in its nearby metadata header.

    Genre menu links appear BEFORE the H1 and must never be collected.
    Related-movie/footer links appear AFTER the player and must be ignored.
    """
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_h1 = False
        self.h1 = []
        self.headings = []
        self.og_title = ""
        self.seen_h1 = False
        self.metadata_end = False
        self.metadata_links = 0
        self.in_link = False
        self.link_text = []
        self.genre_tags = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "h1":
            self.in_h1 = True
            self.h1 = []
        elif tag == "meta" and attrs.get("property") == "og:title":
            self.og_title = attrs.get("content", "")
        elif self.seen_h1 and tag == "h2":
            self.metadata_end = True
        elif self.seen_h1 and not self.metadata_end and tag == "a":
            self.metadata_links += 1
            if self.metadata_links <= 25:
                self.in_link = True
                self.link_text = []
            else:
                self.metadata_end = True

    def handle_data(self, data):
        if self.in_h1:
            self.h1.append(data)
        if self.in_link:
            self.link_text.append(data)
        # Source metadata genre badges precede the playback controls.
        if self.seen_h1 and not self.in_link and re.search(
            r"\b(?:Play Awal|Play Terbaru|Beri rating film ini)\b", data, re.I
        ):
            self.metadata_end = True

    def handle_endtag(self, tag):
        if tag == "h1" and self.in_h1:
            self.headings.append(" ".join(" ".join(self.h1).split()))
            self.in_h1 = False
            self.seen_h1 = True
        elif tag == "a" and self.in_link:
            label = " ".join(" ".join(self.link_text).split())
            if label in SOURCE_GENRES and label not in self.genre_tags:
                self.genre_tags.append(label)
            if label.casefold() in ("play awal", "play terbaru", "trailer"):
                self.metadata_end = True
            self.in_link = False
            self.link_text = []


def parse_source_metadata(page, expected_year):
    parser = TitleParser()
    parser.feed(page)
    for heading in parser.headings:
        match = re.match(r"^(.+?)\s*\((\d{4})\)\s*$", heading)
        if match and int(match.group(2)) == expected_year:
            title = html.unescape(match.group(1)).strip()
            if 2 <= len(title) <= 180:
                return title, parser.genre_tags
    return None, []


def extract_genres(page, expected_year):
    return parse_source_metadata(page, expected_year)[1]


def valid_source_url(raw):
    parsed = urlparse(str(raw))
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and any(
        host == domain or host.endswith("." + domain) for domain in ALLOWED_HOSTS
    ) and bool(parsed.path.strip("/"))


def extract_title(page, expected_year):
    return parse_source_metadata(page, expected_year)[0]


def token_subsequence(shorter, longer):
    source = normalized(shorter).split()
    target = normalized(longer).split()
    if len(source) < 2 or len(target) > len(source) + 4:
        return False
    it = iter(target)
    return all(any(part == expected for part in it) for expected in source)


def safe_title_upgrade(item, full_title):
    old = str(item.get("title") or "").strip()
    candidate = str(full_title or "").strip()
    if not old or not candidate:
        return False
    if normalized(old) == normalized(candidate):
        return True
    # Preserve ordered original content, accepting only missing words.
    if not token_subsequence(old, candidate):
        return False
    # Match the URL slug to the source title as a second independent signal.
    path = urlparse(str(item.get("url") or "")).path.strip("/").split("/")[-1]
    slug = re.sub(r"-(?:19|20)\d{2}$", "", path).replace("-", " ")
    if not token_subsequence(slug, candidate):
        return False
    return True


def fetch_title(item, delay):
    url = str(item.get("url") or "")
    if not valid_source_url(url):
        return None, [], "invalid_source"
    request = Request(url, headers={
        "User-Agent": "Mozilla/5.0 (compatible; FilmStreamMetadataAudit/1.0)",
        "Accept": "text/html",
    })
    with urlopen(request, timeout=22) as response:
        actual = response.geturl()
        if not valid_source_url(actual):
            return None, [], "invalid_redirect"
        if urlparse(actual).hostname != urlparse(url).hostname:
            return None, [], "invalid_redirect"
        if urlparse(actual).path.rstrip("/") != urlparse(url).path.rstrip("/"):
            return None, "invalid_redirect"
        if "html" not in response.headers.get("Content-Type", "").lower():
            return None, [], "not_html"
        body = response.read(700_000).decode("utf-8", errors="replace")
    time.sleep(delay)
    try:
        year = int(item.get("year"))
    except (TypeError, ValueError):
        return None, [], "invalid_year"
    title, genres = parse_source_metadata(body, year)
    return (title, genres, "verified") if title else (None, [], "no_source_title")


def audit(items):
    titles = [x for x in items if x.get("type") in ("movie", "series")]
    blanks = [x for x in titles if not has_genres(x)]
    pending = [x for x in blanks if x.get("genre_source_pass") != PASS]
    return len(titles), sum(has_genres(x) for x in titles), len(blanks), len(pending)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--delay", type=float, default=0.65)
    p.add_argument("--github-output", default="")
    args = p.parse_args()
    if not 0 <= args.limit <= 1000 or args.delay < 0.5:
        p.error("limit must be 0..1000, delay >= 0.5")
    token = os.getenv("TMDB_TOKEN", "").strip()
    if args.limit and not token:
        p.error("TMDB_TOKEN is required for genre recovery")

    data = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    items = data["items"]
    print("Source-title audit BEFORE:", audit(items), flush=True)
    attempted = corrected = filled = from_source = from_tmdb = unresolved = 0
    paused = False
    if args.limit:
        for item in items:
            if attempted >= args.limit:
                break
            if item.get("type") not in ("movie", "series") or has_genres(item):
                continue
            if item.get("genre_source_pass") == PASS:
                continue
            if genre_ids(item.get("genre_ids")):
                item["genre_source_status"] = "existing_tmdb_ids"
                item["genre_source_pass"] = PASS
                attempted += 1
                unresolved += 1
                continue

            old = item.get("title")
            try:
                title, source_genres, source_status = fetch_title(item, args.delay)
                if title and not safe_title_upgrade(item, title):
                    source_status = "title_conflict"
                elif title:
                    if normalized(title) != normalized(old):
                        item["title"] = title
                        item.setdefault("title_before_source_check", old)
                        corrected += 1
                        if corrected <= 30:
                            print(f"Source title corrected: {old!r} -> {title!r}", flush=True)

                if source_status == "title_conflict":
                    result, status = None, "title_conflict"
                else:
                    media = "tv" if item["type"] == "series" else "movie"
                    result, status = assess(item, media, token, args.delay)
                if result and apply_only_if_empty(item, result):
                    filled += 1
                    from_tmdb += 1
                    status = "matched_tmdb"
                    item["genre_data_source"] = "tmdb"
                    if filled <= 30:
                        print(f"Verified TMDB genres: {item['title']!r} -> {result['id']}", flush=True)
                elif source_status == "verified" and source_genres and not has_genres(item):
                    # Source metadata is useful independently of TMDB. Do not
                    # set genre_ids: these were NOT verified from TMDB.
                    item["genres"] = source_genres
                    item["genre_data_source"] = "lk21_source"
                    filled += 1
                    from_source += 1
                    status = "matched_source"
                    if filled <= 30:
                        print(f"Source genres: {item['title']!r} -> {source_genres!r}", flush=True)
                else:
                    status = status or "unmatched"
                    unresolved += 1
                    if unresolved <= 30:
                        print(f"Still empty: {item.get('title')!r}; source={source_status}; match={status}", flush=True)
                item["genre_source_status"] = status
                item["genre_source_pass"] = PASS
                attempted += 1
            except HTTPError as exc:
                # A missing source page is a stable failure; rate limits are transient.
                if exc.code in (404, 410):
                    item["genre_source_status"] = "no_source_title"
                    item["genre_source_pass"] = PASS
                    attempted += 1
                    unresolved += 1
                else:
                    paused = True
                    print(f"Source error {exc.code}; stopping safely", flush=True)
                    break
            except (URLError, TimeoutError, ValueError, KeyError) as exc:
                paused = True
                print(f"Temporary source/TMDB error: {exc}; stopping safely", flush=True)
                break
            if attempted % 25 == 0:
                print(f"Source batch: checked={attempted}; titles_fixed={corrected}; genres_filled={filled}; from_tmdb={from_tmdb}; from_source={from_source}", flush=True)

        temp = CATALOG.with_suffix(".source.tmp")
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temp.replace(CATALOG)

    numbers = audit(items)
    print(f"Source-title audit AFTER: supported={numbers[0]}; with_genres={numbers[1]}; truly_empty={numbers[2]}; pending={numbers[3]}", flush=True)
    print(f"Source batch: checked={attempted}; titles_fixed={corrected}; genres_filled={filled}; from_tmdb={from_tmdb}; from_source={from_source}; unresolved={unresolved}; paused={paused}", flush=True)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"pending={numbers[3]}\nattempted={attempted}\npaused={str(paused).lower()}\n")


if __name__ == "__main__":
    main()
