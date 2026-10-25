"""Build a FilmStream catalog from separate movie and series CSVs.

Usage: py tools/build_catalog.py --movies crawler/data/browser_catalog.csv --series crawler/data/series_catalog.csv
No requests to remote hosts; does not edit crawler source files.
"""
import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

FIELDS = ('title', 'year', 'url', 'type')


def normalize_title(title):
    return re.sub(r'\s+', ' ', title).strip()


def load_csv(path, expected_type):
    with Path(path).open('r', encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        if not set(FIELDS).issubset(set(reader.fieldnames or [])):
            raise ValueError(f'{path}: missing columns {FIELDS}')
        for line, row in enumerate(reader, 2):
            title = normalize_title(row['title'] or '')
            year = str(row['year'] or '').strip()
            url = (row['url'] or '').strip()
            typ = (row['type'] or '').strip()
            parsed = urlparse(url)
            if not title or not re.fullmatch(r'(?:19|20)\d{2}', year):
                raise ValueError(f'{path}:{line}: invalid title/year')
            if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError(f'{path}:{line}: invalid URL')
            if typ != expected_type:
                raise ValueError(f'{path}:{line}: expected {expected_type!r}, got {typ!r}')
            yield {'title': title, 'year': int(year), 'url': url, 'type': typ}


def build(movies, series, output):
    seen = {}
    for kind, path in [('movie', movies), ('series', series)]:
        for row in load_csv(path, kind):
            key = (row['type'], row['url'].rstrip('/'))
            if key not in seen:
                seen[key] = row
    records = sorted(seen.values(), key=lambda x: (x['type'], -x['year'], x['title'].casefold()))
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({'version': 1, 'items': records}, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print(json.dumps({'items': len(records), 'types': dict(Counter(x['type'] for x in records)), 'output': str(target)}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--movies', default='crawler/data/browser_catalog.csv')
    parser.add_argument('--series', default='crawler/data/series_catalog.csv')
    parser.add_argument('--output', default='assets/catalog/filmstream_catalog.json')
    args = parser.parse_args()
    build(args.movies, args.series, args.output)
