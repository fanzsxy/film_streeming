"""Offline pipeline regression tests: catalog first, verify and merge with dedupe."""
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from tools.reconcile_tmdb_gaps import reconcile
from tools.merge_verified_lk21 import prepare


class CatalogFirstTests(unittest.TestCase):
    def test_catalog_dedupes_against_saved_tmdb_report(self):
        report = {"complete": True, "years": [2025, 2025],
                  "by_year": {"2025": {"tmdb_complete": True,
                    "missing_tmdb_titles": [
                      {"tmdb_id": 101, "title": "Existing", "original_title": "Existing"},
                      {"tmdb_id": 102, "title": "Nearby", "original_title": "Nearby"},
                      {"tmdb_id": 103, "title": "William Tell", "original_title": "William Tell"}]}}}
        catalog = {"items": [
            {"title": "Existing", "year": 2025, "url": "https://example.com/existing", "type": "movie"},
            {"title": "Nearby", "year": 2024, "url": "https://example.com/nearby", "type": "movie"}]}
        with TemporaryDirectory() as temp:
            result = reconcile(report, catalog, Path(temp)/"empty_cache.jsonl")
        self.assertEqual([x["tmdb_id"] for x in result["items"]], [103])
        self.assertEqual(result["stats"]["already_in_catalog"], 1)
        self.assertEqual(result["stats"]["possible_alias"], 1)

    def test_merge_rejects_duplicates_and_bad_urls(self):
        catalog = {"version": 1, "items": [{
            "type": "movie", "title": "Already", "year": 2025,
            "url": "https://tv12.lk21official.cc/already-2025", "tmdb_id": 100}]}
        proposals = {"applied": False, "new": [
            {"type": "movie", "title": "Already", "year": 2025,
             "url": "https://tv12.lk21official.cc/another-2025", "tmdb_id": 101},
            {"type": "movie", "title": "William Tell", "year": 2025,
             "url": "https://tv12.lk21official.cc/william-tell-2025",
             "poster_url": "https://poster.example/william.jpg", "tmdb_id": 102},
            {"type": "movie", "title": "Invalid", "year": 2025,
             "url": "https://untrusted.example/invalid-2025", "tmdb_id": 103}]}
        with TemporaryDirectory() as temp:
            added, stats = prepare(catalog, proposals, Path(temp)/"empty_cache.jsonl")
        self.assertEqual(stats, {"new": 1, "duplicates": 1, "invalid": 1})
        self.assertEqual(added[0]["poster_url"], "https://poster.example/william.jpg")
        self.assertEqual(len(catalog["items"]), 1)

    def test_reject_incomplete_tmdb(self):
        with self.assertRaises(ValueError):
            reconcile({"complete": False, "by_year": {}}, {"items": []})


if __name__ == "__main__":
    unittest.main()
