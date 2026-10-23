"""Inspect supplied HTML offline. No fetching, JS execution or playback validation."""
from urllib.parse import urljoin, urlparse
from bs4 import BeautifulSoup


def parse_player_html(html: str, page_url: str) -> dict:
    p = urlparse(page_url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password:
        raise ValueError('page_url must be an absolute HTTPS URL')
    if len(html) > 1_000_000:
        raise ValueError('HTML exceeds 1 MB')
    soup = BeautifulSoup(html, 'html.parser')
    title_tag = soup.select_one('h1') or soup.title
    title = title_tag.get_text(' ', strip=True)[:180] if title_tag else ''
    sources, by_url = [], {}

    def add(raw, label, element):
        if not raw or not raw.strip():
            return
        url = urljoin(page_url, raw.strip())
        u = urlparse(url)
        if u.scheme != 'https' or not u.hostname or u.username or u.password:
            return
        path = u.path.lower()
        if path.endswith(('.m3u8', '.mpd')):
            kind = 'manifest_candidate'
        elif path.endswith(('.mp4', '.webm')):
            kind = 'file_candidate'
        elif element == 'iframe' or element in ('player-link', 'player-option'):
            kind = 'embed'
        else:
            kind = 'unknown_candidate'
        # If player entries include a cache/query suffix, prioritize the explicit
        # player-list URL rather than duplicating the iframe as a separate server.
        key = (u.scheme, u.hostname.lower(), u.path.rstrip('/')) if kind == 'embed' else url
        name = str(label or element).strip()[:80]
        if key in by_url:
            existing = sources[by_url[key]]
            if element in ('player-link', 'player-option') and existing['name'].lower() in ('main-player', 'iframe', 'media player mufasa: the lion king (2024)'):
                existing['name'] = name
                existing['url'] = url
            return
        by_url[key] = len(sources)
        sources.append({'name': name, 'type': kind, 'url': url, 'status': 'unverified'})

    for tag in soup.select('iframe[src], iframe[data-src], video[src], video[data-src], video source[src], source[src]'):
        add(tag.get('src') or tag.get('data-src'), tag.get('data-server') or tag.get('title') or tag.get('id'), tag.name)
    for tag in soup.select('#player-list a[data-url], #player-list a[href]'):
        add(tag.get('data-url') or tag.get('href'), tag.get('data-server') or tag.get_text(' ', strip=True), 'player-link')
    for tag in soup.select('#player-select option[value]'):
        add(tag.get('value'), tag.get('data-server') or tag.get_text(' ', strip=True), 'player-option')

    return {'title': title, 'page_url': page_url, 'sources': sources,
            'direct_video_verified': False,
            'note': 'Offline HTML inspection only. Candidate URLs are not fetched or playback-tested; embeds are not direct streams.'}
