"""Read public movie metadata from a configured LK21 page, subject to robots/terms.
Does not parse embeds, scripts, video hosts, or media stream links.
"""
from urllib.parse import urljoin, urlparse
from urllib.robotparser import RobotFileParser
import re
import requests
from bs4 import BeautifulSoup
from fastapi import HTTPException

BASE = 'https://tv12.lk21official.cc'
USER_AGENT = 'FilmStreamMetadataResearch/1.0 (+personal catalog; respects robots.txt)'

def allowed_url(url: str) -> bool:
    p = urlparse(url)
    return p.scheme == 'https' and p.hostname == 'tv12.lk21official.cc' and p.port is None and not p.username and not p.password

def get_html(path: str):
    url = urljoin(BASE + '/', path)
    if not allowed_url(url):
        raise HTTPException(400, 'Only public pages on the configured domain are supported')
    rp = RobotFileParser()
    try:
        r = requests.get(BASE + '/robots.txt', headers={'User-Agent': USER_AGENT}, timeout=10, allow_redirects=False)
        if r.status_code == 200:
            rp.parse(r.text.splitlines())
            if not rp.can_fetch(USER_AGENT, url):
                raise HTTPException(403, 'Disallowed by robots.txt')
        elif r.status_code not in (404, 410):
            raise HTTPException(503, 'Cannot establish robots.txt policy')
        response = requests.get(url, headers={'User-Agent': USER_AGENT, 'Accept': 'text/html'}, timeout=12, allow_redirects=False)
        if response.status_code in (301,302,303,307,308):
            raise HTTPException(502, 'Page redirects; no cross-domain redirects followed')
        response.raise_for_status()
        if 'text/html' not in response.headers.get('Content-Type',''):
            raise HTTPException(415, 'Not an HTML page')
        return url, BeautifulSoup(response.text[:2_000_000], 'html.parser')
    except requests.RequestException as exc:
        raise HTTPException(502, f'Source page unavailable: {type(exc).__name__}') from exc

def parse_detail(path: str):
    url, soup = get_html(path)
    title_node = soup.select_one('h1') or soup.select_one('meta[property="og:title"]') or soup.title
    title = (title_node.get('content') if title_node and title_node.name == 'meta' else title_node.get_text(' ',strip=True) if title_node else '')
    desc_node = soup.select_one('meta[name="description"]') or soup.select_one('meta[property="og:description"]')
    poster_node = soup.select_one('meta[property="og:image"]')
    year_match = re.search(r'\b(?:19|20)\d{2}\b', title or '')
    return {'title': title, 'year': int(year_match.group()) if year_match else None,
            'description': desc_node.get('content','') if desc_node else '',
            'poster_url': urljoin(url,poster_node.get('content','')) if poster_node else None,
            'source_page': url, 'playback_available': False}

def latest(limit: int = 20):
    url, soup = get_html('/')
    # The public page has a "Film Terbaru" section; use its next sibling list if present.
    marker = next((h for h in soup.find_all(['h2','h3']) if 'film terbaru' in h.get_text(' ',strip=True).lower()), None)
    if not marker:
        return {'items': [], 'note': 'Listing selector may need adjustment for current HTML'}
    container = marker.find_parent('section') or marker.parent.parent
    items, seen = [], set()
    for a in container.select('a[href]'):
        href = urljoin(url,a['href'])
        if not allowed_url(href) or href in seen or urlparse(href).path in ('','/'):
            continue
        title = a.get('title') or (a.select_one('img').get('alt','') if a.select_one('img') else '') or a.get_text(' ',strip=True)
        if len(title.strip()) < 3:
            continue
        seen.add(href)
        items.append({'title':title.strip()[:180], 'source_page':href})
        if len(items) >= limit:
            break
    return {'items':items, 'note':'Public metadata only; no video URL or embed extracted'}
