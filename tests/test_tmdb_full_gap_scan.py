"""Network-free regressions for complete TMDB month-split gap scan."""
import unittest
from unittest.mock import patch
from datetime import date
from tools.tmdb_full_gap_scan import identity, months, missing_movies, discover_window

class FullGapTests(unittest.TestCase):
    def test_year_is_all_twelve_months(self):
        ranges = list(months(2020))
        self.assertEqual(len(ranges), 12)
        self.assertEqual(ranges[1][1], date(2020, 2, 29))
        self.assertEqual(ranges[-1][1], date(2020, 12, 31))

    def test_existing_movies_are_excluded(self):
        known = [{"type": "movie", "title": "Known", "year": 2020, "tmdb_id": 1}]
        incoming = [
          {"id": 1, "title": "Other", "original_title": "Other"},
          {"id": 2, "title": "Known", "original_title": "Known"},
          {"id": 3, "title": "New", "original_title": "New"}]
        self.assertEqual([x["tmdb_id"] for x in missing_movies(incoming, known, 2020)], [3])

    @patch("tools.tmdb_full_gap_scan.time.sleep")
    @patch("tools.tmdb_full_gap_scan.tmdb_get")
    def test_page_results_are_combined(self, api, sleep):
        api.side_effect = [
            {"total_pages":2, "results":[{"id":1, "title":"A", "release_date":"2020-01-01"}]},
            {"total_pages":2, "results":[{"id":2, "title":"B", "release_date":"2020-01-02"}]}]
        stats = {"requests": 0}
        found = discover_window(date(2020, 1, 1), date(2020, 1, 31), "token", 0.3, stats)
        self.assertEqual(set(found), {1,2})
        self.assertEqual(stats["requests"], 2)

    @patch("tools.tmdb_full_gap_scan.time.sleep")
    @patch("tools.tmdb_full_gap_scan.tmdb_get")
    def test_large_window_splits_in_half(self, api, sleep):
        api.side_effect = [
            {"total_pages":501, "results":[]},
            {"total_pages":1, "results":[{"id":1, "title":"A", "release_date":"2020-01-01"}]},
            {"total_pages":1, "results":[{"id":2, "title":"B", "release_date":"2020-01-03"}]}]
        result = discover_window(date(2020,1,1), date(2020,1,3), "token", 0.3, {"requests":0})
        self.assertEqual(set(result), {1,2})

    @patch("tools.tmdb_full_gap_scan.tmdb_get")
    def test_daily_cap_causes_error(self, api):
        api.return_value = {"total_pages":501, "results":[]}
        with self.assertRaises(RuntimeError):
            discover_window(date(2020,1,1), date(2020,1,1), "token", 0.3, {"requests":0})

if __name__ == "__main__":
    unittest.main()
