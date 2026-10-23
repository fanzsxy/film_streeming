"""Offline inspection of user-provided HTML; no network calls or protection bypass."""
from urllib.parse import urljoin, urlparse
from bs4 import BeautifulSoup

MEDIA_EXT = ('.mp4', '.m3u8', '.webm', '.mpd')

def parse_player_html(html: str, page_url: str) -> dict:
    p = urlparse(page_url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password:
        raise ValueError('page_url must be an absolute HTTPS URL')
    if len(html) > 1_000_000:
        raise ValueError('HTML exceeds 1 MB')
    soup = BeautifulSoup(html, 'html.parser')
    title = (soup.select_one('h1') or soup.title)
    title_text = title.get_text(' ', strip=True)[:180] if title else ''
    found, seen = [], set()
    for tag in soup.select('iframe[src], iframe[data-src], video[src], video[data-src], video source[src], source[src]'):
        raw = tag.get('src') or tag.get('data-src')
        if not raw:
            continue
        url = urljoin(page_url, raw.strip())
        u = urlparse(url)
        if u.scheme != 'https' or not u.hostname or u.username or u.password:
            continue
        if url in seen:
            continue
        seen.add(url)
        ext = u.path.lower()
        if tag.name == 'iframe':
            kind = 'embed'
        elif ext.endswith(('.m3u8', '.mpd')):
            kind = 'manifest_candidate'
        elif ext.endswith(('.mp4', '.webm')):
            kind = 'file_candidate'
        else:
            kind = 'unknown_candidate'
        label = tag.get('title') or tag.get('data-server') or tag.get('id') or tag.name
        found.append({'name': str(label)[:80], 'type': kind, 'url': url, 'status': 'unverified'})
    return {'title': title_text, 'page_url': page_url, 'sources': found,
            'direct_video_verified': False,
            'note': 'Offline HTML inspection only. URLs are not fetched or tested; an iframe is not a direct stream.'}
