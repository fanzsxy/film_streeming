"""Enrich FilmStream catalog with TMDB metadata, conservatively and resumably.

Set TMDB_TOKEN in your environment (v4 read access token), then run:
py tools/enrich_tmdb.py --limit 100 --delay 0.35

Never overrides crawler title, year, source URL or type. An ambiguous or absent match
is preserved with TMDB fields null and a placeholder poster.
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


def norm(value):
    return re.sub(r'[^a-z0-9]+', ' ', value.casefold()).strip()


def tmdb_get(endpoint, params, token):
    url = 'https://api.themoviedb.org/3/' + endpoint + '?' + urlencode(params)
    request = Request(url, headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json', 'User-Agent': 'FilmStreamCatalog/1.0'})
    with urlopen(request, timeout=20) as reply:
        return json.load(reply)


def match(item, candidates):
    query = norm(item['title'])
    year = item['year']
    matches = []
    for candidate in candidates:
        titles = [candidate.get('title', ''), candidate.get('original_title', ''), candidate.get('name', ''), candidate.get('original_name', '')]
        similarity = max((difflib.SequenceMatcher(None, query, norm(t)).ratio() for t in titles if t), default=0)
        date = candidate.get('release_date') or candidate.get('first_air_date') or ''
        candidate_year = int(date[:4]) if re.fullmatch(r'\d{4}', date[:4]) else None
        if candidate_year is None or abs(year - candidate_year) > 1 or similarity < 0.94:
            continue
        exact_year = candidate_year == year
        matches.append((similarity, exact_year, candidate))
    matches.sort(key=lambda x: (x[0], x[1]), reverse=True)
    if not matches:
        return None
    # Reject competing plausible results rather than attaching the wrong poster.
    if len(matches) > 1 and matches[0][0] - matches[1][0] < 0.07:
        return None
    return matches[0][2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--catalog', default='assets/catalog/filmstream_catalog.json')
    parser.add_argument('--cache', default='assets/catalog/tmdb_cache.jsonl')
    parser.add_argument('--limit', type=int, default=100, help='Maximum new TMDB requests in this run')
    parser.add_argument('--delay', type=float, default=0.35)
    parser.add_argument('--type', choices=['series', 'movie', 'all'], default='series')
    args = parser.parse_args()
    if args.limit < 1 or args.delay < 0.25:
        parser.error('--limit >= 1 and --delay >= 0.25')
    token = os.environ.get('TMDB_TOKEN', '').strip()
    if not token:
        parser.error('TMDB_TOKEN not set. Do not commit your token to GitHub.')
    catalog = json.loads(Path(args.catalog).read_text(encoding='utf-8'))['items']
    cache_path = Path(args.cache)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cached = {}
    if cache_path.exists():
        for line in cache_path.read_text(encoding='utf-8').splitlines():
            if line.strip():
                obj = json.loads(line)
                cached[obj['source_url']] = obj
    completed = 0
    with cache_path.open('a', encoding='utf-8') as out:
        for item in catalog:
            if args.type != 'all' and item['type'] != args.type:
                continue
            if completed >= args.limit:
                break
            if item['url'] in cached:
                continue
            endpoint = 'search/movie' if item['type'] == 'movie' else 'search/tv'
            params = {'query': item['title'], 'include_adult': 'false', 'language': 'en-US'}
            params['year' if item['type'] == 'movie' else 'first_air_date_year'] = str(item['year'])
            try:
                results = tmdb_get(endpoint, params, token).get('results', [])
                candidate = match(item, results)
                record = {
                    'source_url': item['url'], 'tmdb_id': candidate.get('id') if candidate else None,
                    'tmdb_type': 'movie' if item['type'] == 'movie' else 'tv',
                    'match_status': 'matched' if candidate else 'unmatched',
                    'poster_path': candidate.get('poster_path') if candidate else None,
                    'backdrop_path': candidate.get('backdrop_path') if candidate else None,
                    'overview': candidate.get('overview') if candidate else None,
                    'rating': candidate.get('vote_average') if candidate else None,
                    'genre_ids': candidate.get('genre_ids') if candidate else [],
                }
            except (HTTPError, URLError, TimeoutError) as err:
                print('TMDB unavailable; stopping without caching errors:', err)
                break
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
            out.flush()
            cached[item['url']] = record
            completed += 1
            if completed % 10 == 0:
                print('Processed', completed, 'new; cache size', len(cached))
            time.sleep(args.delay)
    print('Finished: new', completed, 'cached', len(cached), 'of', len(catalog))
    print('Run prepare_app_catalog.py afterward to copy verified matches into the APK catalog.')


if __name__ == '__main__':
    main()
