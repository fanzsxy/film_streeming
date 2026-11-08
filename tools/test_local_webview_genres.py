"""Offline tests for local visible-browser source metadata recovery."""
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import recover_genres_local_webview as local_browser

from recover_genres_local_webview import browse_source, recover_item


class FakeResponse:
    def __init__(self, status):
        self.status = status


class FakePage:
    def __init__(self, status=200, html=""):
        self.status = status
        self.html = html
        self.url = ""

    def goto(self, url, **_):
        self.url = url
        return FakeResponse(self.status)

    def wait_for_timeout(self, _):
        pass

    def content(self):
        return self.html


class LocalBrowserTests(unittest.TestCase):
    def setUp(self):
        self.item = {
            "title": "When I Meet Moon",
            "type": "series",
            "year": 2026,
            "url": "https://tv.nontondrama.vip/when-i-meet-moon-2026",
            "genres": [],
        }

    def test_page_source_title_and_genres(self):
        html = ('<nav><a>Horror</a></nav>'
                '<h1>When I Meet the Moon (2026)</h1>'
                '<a>Drama</a><a>Romance</a>'
                '<a>Play Awal</a><a>Action</a>')
        title, genres, status = browse_source(FakePage(html=html), self.item, 0)
        self.assertEqual((title, genres, status),
                         ("When I Meet the Moon", ["Drama", "Romance"], "verified"))

    def test_blocked_site_must_not_be_scraped(self):
        result = browse_source(FakePage(status=401), self.item, 0)
        self.assertEqual(result[2], "blocked_401")

    def test_source_fallback_does_not_invent_tmdb_ids(self):
        with patch("recover_genres_local_webview.assess", return_value=(None, "unmatched")):
            status, corrected, from_tmdb, from_source = recover_item(
                self.item, "When I Meet the Moon", ["Drama", "Romance"], "verified", "token", 0)
        self.assertEqual((status, corrected, from_tmdb, from_source),
                         ("matched_source", True, False, True))
        self.assertEqual(self.item["genres"], ["Drama", "Romance"])
        self.assertNotIn("genre_ids", self.item)
        self.assertEqual(self.item["genre_data_source"], "lk21_source")

    def test_tmdb_401_falls_back_to_source_genres(self):
        with patch.object(local_browser, "TMDB_AUTH_FAILED", False):
            with patch("recover_genres_local_webview.assess",
                       side_effect=HTTPError("https://api.themoviedb.org/3/search/tv", 401,
                                             "Unauthorized", None, None)):
                status, corrected, from_tmdb, from_source = recover_item(
                    self.item, "When I Meet the Moon", ["Drama", "Romance"],
                    "verified", "invalid_token", 0)
            self.assertEqual(status, "matched_source")
            self.assertTrue(corrected)
            self.assertFalse(from_tmdb)
            self.assertTrue(from_source)
            self.assertNotIn("genre_ids", self.item)

    def test_title_conflict_never_overwrites(self):
        with patch("recover_genres_local_webview.assess") as mock_assess:
            status, corrected, _, _ = recover_item(
                self.item, "When I Meet the Sun", ["Drama"], "verified", "token", 0)
        self.assertEqual(status, "title_conflict")
        self.assertFalse(corrected)
        self.assertEqual(self.item["title"], "When I Meet Moon")
        mock_assess.assert_not_called()


if __name__ == "__main__":
    unittest.main()
