"""Offline regressions for TMDB-first gap detection."""
import unittest
from unittest.mock import Mock, patch
from tools.discover_lk21_years_tmdb import identity, missing_tmdb, confirmed_missing, lk21_year_entries


class GapTests(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(identity("A: Film!", 2020), identity("A Film", "2020"))

    def test_existing_excluded_by_title_or_tmdb_id(self):
        existing = [{"type":"movie", "title":"Known", "year":2020, "tmdb_id":1}]
        incoming = [{"id":1, "title":"Alternate", "original_title":"Alternate"},
                    {"id":2, "title":"Known", "original_title":"Known"},
                    {"id":3, "title":"New", "original_title":"New"}]
        self.assertEqual([x["id"] for x in missing_tmdb(incoming, existing, 2020)], [3])

    def test_verify_actual_source_url(self):
        movies = [{"id":3, "title":"New", "original_title":"New"}]
        entries = [{"title":"New", "year":2020, "type":"movie",
                    "url":"https://tv12.lk21official.cc/new-2020"}]
        found, ambiguous = confirmed_missing(movies, entries, 2020)
        self.assertEqual(found[0]["tmdb_id"], 3)
        self.assertEqual(len(ambiguous), 0)

    def test_robots_denial(self):
        session, robots = Mock(), Mock()
        robots.can_fetch.return_value = False
        entries, errors = lk21_year_entries(session, robots, 2020, 2, 2)
        self.assertEqual(entries, [])
        self.assertTrue(errors)
        session.get.assert_not_called()


if __name__ == "__main__":
    unittest.main()
