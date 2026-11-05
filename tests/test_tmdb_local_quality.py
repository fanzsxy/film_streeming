"""Offline checks for the local scan's quality filters."""
import unittest
from unittest.mock import patch
from datetime import date
from tools.tmdb_full_gap_scan import discover_window

class QualityFilterTests(unittest.TestCase):
    @patch("tools.tmdb_full_gap_scan.tmdb_get")
    def test_filter_passed_to_tmdb(self, tmdb):
        tmdb.return_value = {"total_pages": 1, "results": [
            {"id": 5, "title": "Good Film", "release_date": "2025-01-01"}]}
        filters = {"with_runtime.gte": "70", "vote_average.gte": "5.0",
                   "vote_count.gte": "10"}
        result = discover_window(date(2025,1,1), date(2025,1,31),
                                 "token", .3, {"requests": 0}, filters)
        self.assertEqual(list(result), [5])
        args = tmdb.call_args.args
        self.assertEqual(args[1]["with_runtime.gte"], "70")
        self.assertEqual(args[1]["vote_average.gte"], "5.0")
        self.assertEqual(args[1]["vote_count.gte"], "10")

if __name__ == "__main__":
    unittest.main()
