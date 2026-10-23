import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from player_parser import parse_player_html

def test_offline_html():
    html = '''<html><title>Mufasa: The Lion King</title><iframe title="HYDRAX" src="https://example.org/embed/abc"></iframe><video><source src="/media/demo.mp4"/></video></html>'''
    result = parse_player_html(html, 'https://example.com/mufasa')
    assert result['title'] == 'Mufasa: The Lion King'
    assert result['sources'][0]['type'] == 'embed'
    assert result['sources'][1]['type'] == 'file_candidate'
    assert result['direct_video_verified'] is False

if __name__ == '__main__':
    test_offline_html()
    print('Offline parser test: PASS')
