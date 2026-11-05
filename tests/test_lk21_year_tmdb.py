"""Offline safety and matching tests for year-specific LK21 discovery."""
import unittest
from unittest.mock import Mock, patch

from tools.discover_lk21_years_tmdb import identity, fetch_listing, select_missing


class YearDiscoveryTests(unittest.TestCase):
    def test_normalized_identity(self):
        self.assertEqual(identity("A: Film!", 2020), identity("A Film", "2020"))

    def test_robots_denial_prevents_request(self):
        session = Mock()
        robot = Mock()
        robot.can_fetch.return_value = False
        html, error = fetch_listing(session, robot, 2020, 1)
        self.assertIsNone(html)
        self.assertIn("robots.txt", error)
        session.get.assert_not_called()

    @patch("tools.discover_lk21_years_tmdb.time.sleep")
    @patch("tools.discover_lk21_years_tmdb.tmdb_get")
    def test_duplicates_and_unmatched_skipped(self, api, sleep):
        existing = [{"type": "movie", "title": "Existing Movie", "year": 2020,
                     "url": "https://tv12.lk21official.cc/existing-movie-2020"}]
        entries = [
            {"type": "movie", "title": "Existing Movie", "year": 2020,
             "url": "https://tv12.lk21official.cc/existing-movie-2020"},
            {"type": "movie", "title": "Missing Movie", "year": 2020,
             "url": "https://tv12.lk21official.cc/missing-movie-2020"},
        ]
        api.return_value = {"results": []}
        new, rejected = select_missing(existing, entries, 2020, "token", Mock(), 0.25)
        self.assertEqual(new, [])
        self.assertEqual(len(rejected), 1)
        api.assert_called_once()


if __name__ == "__main__":
    unittest.main()
