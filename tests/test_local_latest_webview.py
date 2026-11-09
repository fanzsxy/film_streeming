"""Offline regression tests for visible local latest-title scanner."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from tools.discover_new_titles_local_webview import (
    load_robots, read_browser, select_new,
    scan_listings, scan_details, write_json_atomic, valid_source_base,
)

BASE = "https://tv12.lk21official.cc"


def allowed():
    robots = Mock()
    robots.can_fetch.return_value = True
    return robots


class LatestLocalWebviewTests(unittest.TestCase):
    def test_only_configured_source_hosts_can_be_selected(self):
        self.assertTrue(valid_source_base(
            "https://tv12.lk21official.cc", "movie"))
        self.assertTrue(valid_source_base(
            "https://tv13.lk21official.cc", "movie"))
        self.assertFalse(valid_source_base(
            "https://other.example", "movie"))
        self.assertFalse(valid_source_base(
            "http://tv12.lk21official.cc", "movie"))
        self.assertFalse(valid_source_base(
            "https://tv12.lk21official.cc/latest", "movie"))
        self.assertTrue(valid_source_base(
            "https://tv.lk21online.de", "series", ["tv.lk21online.de"]))
        self.assertFalse(valid_source_base(
            "https://outside.example", "series", ["tv.lk21online.de"]))

    def test_existing_catalog_and_duplicate_page_cards_never_added(self):
        existing = [
            {"type": "movie", "title": "Existing", "year": 2026,
             "url": BASE + "/existing-2026"},
        ]
        proposed = [
            dict(existing[0]),
            {"type": "movie", "title": "Existing!", "year": 2026,
             "url": BASE + "/renamed-existing-2026"},
            {"type": "movie", "title": "New Film", "year": 2026,
             "url": BASE + "/new-film-2026"},
            {"type": "movie", "title": "New Film", "year": 2026,
             "url": BASE + "/new-film-copy-2026"},
            {"type": "series", "title": "New Film", "year": 2026,
             "url": BASE + "/new-series-2026"},
        ]
        result = select_new(existing, proposed)
        self.assertEqual([e["url"] for e in result],
                         [BASE + "/new-film-2026", BASE + "/new-series-2026"])
        self.assertEqual(len(select_new(existing, proposed, max_new=1)), 1)
        self.assertEqual(existing[0]["title"], "Existing")

    def test_browser_redirect_rejected_before_content_read(self):
        page = Mock()
        page.url = "https://unrelated.example/moved"
        page.goto.return_value = Mock(status=200)
        html, status = read_browser(page, allowed(), BASE + "/latest")
        self.assertIsNone(html)
        self.assertEqual(status, "unexpected_redirect")
        page.content.assert_not_called()

    def test_browser_blocked_status_rejected(self):
        page = Mock()
        page.url = BASE + "/latest"
        page.goto.return_value = Mock(status=403)
        html, status = read_browser(page, allowed(), BASE + "/latest")
        self.assertIsNone(html)
        self.assertEqual(status, "blocked_http_403")
        page.content.assert_not_called()

    def test_browser_respects_robots_policy(self):
        page = Mock()
        robots = Mock()
        robots.can_fetch.return_value = False
        html, status = read_browser(page, robots, BASE + "/latest")
        self.assertIsNone(html)
        self.assertEqual(status, "robots_disallow")
        page.goto.assert_not_called()

    def test_browser_can_read_normal_listing(self):
        page = Mock()
        page.url = BASE + "/latest"
        page.goto.return_value = Mock(status=200)
        page.content.return_value = '<article><h2>New Film</h2></article>'
        html, status = read_browser(page, allowed(), BASE + "/latest")
        self.assertEqual(status, "ok")
        self.assertIn("New Film", html)

    def test_scans_only_valid_dated_source_card_urls(self):
        doc = ('<article><a href="/new-film-2026">'
               '<img alt="New Film"></a></article>'
               '<article><a href="https://evil.example/bad-2026">'
               '<img alt="Bad"></a></article>')
        page = Mock()
        with patch("tools.discover_new_titles_local_webview.read_browser",
                   return_value=(doc, "ok")) as browse:
            records, failures = scan_listings(
                page, allowed(), BASE, "/latest", "movie", pages=1,
                delay=2, wait_ms=850)
        self.assertEqual(failures, [])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["title"], "New Film")
        self.assertEqual(records[0]["year"], 2026)
        browse.assert_called_once()

    def test_genres_added_only_to_new_items_from_verified_detail(self):
        new = [{"title": "Shortened", "year": 2026, "type": "movie",
                "url": BASE + "/new-film-2026"}]
        details = ('<nav><a>Horror</a></nav>'
                   '<h1>The Original Full Film Title (2025)</h1>'
                   '<p><a>Drama</a><a>Romance</a></p>'
                   '<h2>More films</h2><a>Action</a>')
        with patch("tools.discover_new_titles_local_webview.read_browser",
                   return_value=(details, "ok")):
            summary = scan_details(
                Mock(), {"movie": allowed()}, {"movie": BASE}, new,
                limit=1, delay=2, wait_ms=850)
        self.assertEqual(summary["genres_added"], 1)
        self.assertEqual(new[0]["genres"], ["Drama", "Romance"])
        self.assertEqual(new[0]["genre_data_source"], "lk21_source")

    def test_blocked_detail_is_not_trusted_and_stops(self):
        new = [{"title": f"Film {i}", "year": 2026, "type": "movie",
                "url": BASE + f"/film-{i}-2026"} for i in range(3)]
        with patch("tools.discover_new_titles_local_webview.read_browser",
                   return_value=(None, "blocked_http_403")) as browse:
            summary = scan_details(Mock(), {"movie": allowed()},
                                   {"movie": BASE}, new, 3, 2, 850)
        self.assertEqual(summary["checked"], 1)
        self.assertEqual(summary["genres_added"], 0)
        self.assertTrue(all("genres" not in x for x in new))
        browse.assert_called_once()

    def test_robots_txt_unavailable_blocks_source(self):
        page = Mock()
        page.goto.return_value = Mock(status=403)
        with self.assertRaisesRegex(RuntimeError, "robots.txt unavailable"):
            load_robots(page, BASE)

    def test_atomic_report_writer_does_not_change_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "catalog.json"
            raw = '{"items":[{"title":"Existing"}]}\n'
            target.write_text(raw, encoding="utf-8")
            new = {"items": [{"title": "Existing"}, {"title": "New"}]}
            write_json_atomic(target, new, original=raw)
            data = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(len(data["items"]), 2)
            self.assertFalse(target.with_suffix(".scan.tmp").exists())


if __name__ == "__main__":
    unittest.main()
