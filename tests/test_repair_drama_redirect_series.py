import unittest
from unittest.mock import patch

from tools.repair_drama_redirect_series import (
    drama_slug, candidate_rows, verify_series_detail, series_title_evidence,
)


class DramaRedirectSeriesTests(unittest.TestCase):
    def test_only_explicit_drama_redirect(self):
        self.assertEqual(drama_slug(
            "https://tv12.lk21official.cc/nontondrama?page=game-of-thrones-2011"),
            "game-of-thrones-2011")
        for url in (
            "https://tv12.lk21official.cc/deadly-weekend-2013",
            "https://evil.example/nontondrama?page=game-of-thrones-2011",
            "https://tv12.lk21official.cc/nontondrama?page=../../secret",
            "https://tv12.lk21official.cc/nontondrama?page=a&page=b",
        ):
            self.assertIsNone(drama_slug(url))

    def test_candidate_redirect_does_not_change_film_type(self):
        url = "https://tv12.lk21official.cc/game-of-thrones-2011"
        catalog = {"items": [{"title": "Game of Thrones", "year": 2011,
                              "url": url, "type": "movie", "poster_url": ""}]}
        with patch("tools.repair_drama_redirect_series.validated", return_value=True):
            result = list(candidate_rows(catalog, {
                "checked": {url: "search_no_verified_match"},
                "search_checked": {url: "redirect"}}))
        self.assertEqual(len(result), 1)
        self.assertEqual(catalog["items"][0]["type"], "movie")

    @patch("tools.repair_drama_redirect_series.poster_from_detail",
           return_value="https://img.example.org/game.jpg")
    def test_verified_real_series_page(self, poster):
        html = """<html><h1>Game of Thrones (2011)</h1>
             <h2>Series Game of Thrones (2011)</h2>
             <p>Season 1 Episode 1</p></html>"""
        match, status = verify_series_detail(
            html, "https://tv.nontondrama.vip/game-of-thrones-2011",
            {"title": "Game of Thrones", "year": 2011})
        self.assertEqual(status, "verified_series")
        self.assertEqual(match["type"], "series")
        self.assertEqual(match["poster_url"], "https://img.example.org/game.jpg")

    @patch("tools.repair_drama_redirect_series.poster_from_detail",
           return_value="https://img.example.org/poster.jpg")
    def test_accepts_exact_observed_alternate_name_only(self, poster):
        html = """<html><head><meta property="og:title"
                    content="Alternate Display Name (2021)"></head>
                    <h1>Alternate Display Name (2021)</h1>
                    <div class="original-title">Source Catalog Title (2021)</div>
                    <p>Series Season 1 Episode 1</p></html>"""
        match, status = verify_series_detail(
            html, "https://tv.nontondrama.vip/source-catalog-title-2021",
            {"title": "Source Catalog Title", "year": 2021})
        self.assertEqual(status, "verified_series")
        self.assertEqual(match["type"], "series")
        match, status = verify_series_detail(
            html, "https://tv.nontondrama.vip/source-catalog-title-2021",
            {"title": "Unrelated Title", "year": 2021})
        self.assertIsNone(match)
        self.assertEqual(status, "title_mismatch")

    @patch("tools.repair_drama_redirect_series.poster_from_detail",
           return_value="https://img.example.org/something.jpg")
    def test_rejects_wrong_title_or_missing_series_evidence(self, poster):
        match, status = verify_series_detail(
            "<h1>Game of Thrones (2011)</h1><p>Season 1 Episode 1 Series</p>",
            "https://tv.nontondrama.vip/game-of-thrones-2011",
            {"title": "Deadly Weekend", "year": 2013})
        self.assertIsNone(match)
        self.assertEqual(status, "year_mismatch")
        match, status = verify_series_detail(
            "<h1>Game of Thrones (2011)</h1>", "https://tv.nontondrama.vip/game-of-thrones-2011",
            {"title": "Game of Thrones", "year": 2011})
        self.assertIsNone(match)
        self.assertEqual(status, "missing_series_evidence")


if __name__ == "__main__":
    unittest.main()
