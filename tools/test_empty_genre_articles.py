"""Offline regression tests for conservative missing-article TMDB matching."""
import unittest
from unittest.mock import patch

import third_pass_catalog_genres as search


class ArticleMatchingTests(unittest.TestCase):
    def test_search_variant_for_missing_the(self):
        self.assertIn("When I Meet the Moon",
                      search.article_search_queries("When I Meet Moon"))

    def test_article_equivalent_does_not_drop_content_words(self):
        self.assertTrue(search.article_equivalent(
            ["When I Meet Moon"], ["When I Meet the Moon"]))
        self.assertFalse(search.article_equivalent(
            ["When I Meet Moon"], ["When I Meet the Sun"]))
        self.assertFalse(search.article_equivalent(
            ["Moon"], ["The Moon"]))

    def api_stub(self, endpoint, token, params=None):
        if endpoint == "search/tv":
            if params["query"] == "When I Meet the Moon":
                return {"results": [{
                    "id": 701, "name": "When I Meet the Moon",
                    "first_air_date": "2026-11-05",
                }]}
            return {"results": []}
        if endpoint == "tv/701":
            return {
                "id": 701, "name": "When I Meet the Moon",
                "first_air_date": "2026-11-05",
                "genres": [{"id": 18, "name": "Drama"}],
            }
        if endpoint == "tv/701/alternative_titles":
            return {"results": []}
        raise AssertionError("Unexpected API endpoint " + endpoint)

    @patch.object(search.time, "sleep", return_value=None)
    def test_matching_only_with_article_mode(self, unused_sleep):
        item = {
            "title": "When I Meet Moon", "year": 2026,
            "type": "series", "url": "https://tv.nontondrama.vip/when-i-meet-moon-2026",
        }
        with patch.object(search, "api", side_effect=self.api_stub):
            result, status = search.assess(item, "tv", "token", 0.35, article_mode=True)
            self.assertEqual(result["id"], 701)
            self.assertIsNone(status)
            result_old, status_old = search.assess(item, "tv", "token", 0.35)
            self.assertIsNone(result_old)
            self.assertEqual(status_old, "unmatched")

    @patch.object(search.time, "sleep", return_value=None)
    def test_wrong_year_not_accepted(self, unused_sleep):
        item = {"title": "When I Meet Moon", "year": 2024,
                "type": "series", "url": "https://tv.nontondrama.vip/when-i-meet-moon-2024"}
        with patch.object(search, "api", side_effect=self.api_stub):
            result, status = search.assess(item, "tv", "token", 0.35, article_mode=True)
        self.assertIsNone(result)
        self.assertEqual(status, "unmatched")


if __name__ == "__main__":
    unittest.main()
