"""Offline regression checks for visible-browser LK21 title matching."""
import unittest
from unittest.mock import patch, MagicMock

from tools.local_lk21_browser_search import find_candidate


class VisibleBrowserTests(unittest.TestCase):
    @patch("tools.local_lk21_browser_search.browse")
    @patch("tools.local_lk21_browser_search.extract_matches")
    @patch("tools.local_lk21_browser_search.detail_title_year")
    @patch("tools.local_lk21_browser_search.poster_from_detail")
    def test_dark_nuns_verified_from_browser_result(self, poster, detail, matches, browse):
        browser = MagicMock()
        browser.url = "https://tv12.lk21official.cc/search?s=dark+nuns"
        movie = {"title": "Dark Nuns", "original_title": "Dark Nuns", "year": 2025,
                 "tmdb_id": 9999}
        matches.return_value = [{
            "title": "Dark Nuns", "year": 2025,
            "url": "https://tv12.lk21official.cc/dark-nuns-2025",
            "poster_url": "https://images.example/dark-nuns.jpg"}]
        browse.return_value = "<html></html>"
        detail.return_value = ("Dark Nuns", 2025)
        poster.return_value = "https://images.example/dark-nuns.jpg"
        status, candidate = find_candidate(
            browser, MagicMock(), ("https://tv12.lk21official.cc/search", "s", []),
            movie, 3)
        self.assertEqual(status, "verified")
        self.assertEqual(candidate["title"], "Dark Nuns")
        self.assertEqual(candidate["year"], 2025)
        self.assertEqual(candidate["poster_url"], "https://images.example/dark-nuns.jpg")
        self.assertEqual(browse.call_count, 2)

    @patch("tools.local_lk21_browser_search.browse")
    @patch("tools.local_lk21_browser_search.extract_matches")
    def test_no_extra_pause_after_last_unsuccessful_title(self, matches, browse):
        browser = MagicMock()
        browser.url = "https://tv12.lk21official.cc/search"
        matches.return_value = []
        browse.return_value = "<html></html>"
        result = find_candidate(
            browser, MagicMock(), ("https://tv12.lk21official.cc/search", "s", []),
            {"title": "Quiet Life", "original_title": "Quiet Life",
             "year": 2025, "tmdb_id": 23}, 2)
        self.assertEqual(result, ("search_no_match", None))
        browser.wait_for_timeout.assert_not_called()
        self.assertEqual(browse.call_args.kwargs["render_wait_ms"], 800)

    @patch("tools.local_lk21_browser_search.browse")
    @patch("tools.local_lk21_browser_search.extract_matches")
    def test_unmatched_search_not_declared_missing_from_site(self, matches, browse):
        browser = MagicMock()
        browser.url = "https://tv12.lk21official.cc/search"
        matches.return_value = []
        browse.return_value = "<html></html>"
        result = find_candidate(
            browser, MagicMock(), ("https://tv12.lk21official.cc/search", "s", []),
            {"title": "Not recognised", "original_title": "", "year": 2025,
             "tmdb_id": 42}, 2)
        self.assertEqual(result, ("search_no_match", None))


if __name__ == "__main__":
    unittest.main()
