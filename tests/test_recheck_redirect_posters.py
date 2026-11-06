import unittest
from unittest.mock import patch

from tools.recheck_redirect_posters import targets, classify, source_metadata


class RedirectPosterRecheckTests(unittest.TestCase):
    def test_only_unfilled_movies_with_observed_redirect(self):
        one = {"title": "Deadly Weekend", "year": 2013,
               "type": "movie", "poster_url": "",
               "url": "https://tv12.lk21official.cc/deadly-weekend-2013"}
        two = {"**": "nothing", **one, "title": "Has Poster",
               "poster_url": "https://images.example/valid.jpg"}
        three = {**one, "type": "series"}
        with patch("tools.recheck_redirect_posters.validated", return_value=True):
            result = list(targets({"items": [one, two, three]},
                                  {"checked": {one["url"]: "redirect"}}))
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0], 0)

    def test_search_checkpoint_redirect_is_included(self):
        item = {"title": "Sample Film", "year": 2020, "type": "movie",
                "url": "https://tv12.lk21official.cc/sample-film-2020",
                "poster_url": ""}
        progress = {"checked": {item["url"]: "search_no_verified_match"},
                    "search_checked": {item["url"]: "redirect"}}
        with patch("tools.recheck_redirect_posters.validated", return_value=True):
            found = list(targets({"items": [item]}, progress))
        self.assertEqual(len(found), 1)

    def test_sitemap_checkpoint_redirect_is_included(self):
        item = {"title": "Sample Film", "year": 2020, "type": "movie",
                "url": "https://tv12.lk21official.cc/sample-film-2020",
                "poster_url": ""}
        progress = {"checked": {item["url"]: "year_mismatch"},
                    "search_checked": {item["url"]: "search_no_verified_match"}}
        sitemap = {"completed": {item["url"]: "redirect"}}
        with patch("tools.recheck_redirect_posters.validated", return_value=True):
            found = list(targets({"items": [item]}, progress, sitemap_state=sitemap))
        self.assertEqual(len(found), 1)

    def test_compound_redirect_agrees_with_triage(self):
        item = {"title": "Example", "year": 2020, "type": "movie",
                "url": "https://tv12.lk21official.cc/example-2020",
                "poster_url": ""}
        from tools.triage_missing_catalog_posters import status_for
        # The old equality check rejected these statuses even though
        # triage classified both as redirect.
        for source in ("checked", "search_checked"):
            progress = {source: {item["url"]: "redirect_to_home"}}
            self.assertEqual(
                status_for(item["url"], progress, {})["category"], "redirect"
            )
            with patch("tools.recheck_redirect_posters.validated", return_value=True):
                self.assertEqual(len(list(targets({"items": [item]}, progress))), 1)
        sitemap = {"completed": {item["url"]: "redirected_to_listing"}}
        self.assertEqual(status_for(item["url"], {}, sitemap)["category"], "redirect")
        with patch("tools.recheck_redirect_posters.validated", return_value=True):
            self.assertEqual(len(list(targets(
                {"items": [item]}, {}, sitemap_state=sitemap))), 1)

    def test_all_missing_includes_search_failures_and_unchecked(self):
        rows = [
            {"title": "Movie A", "year": 2020, "type": "movie",
             "url": "https://tv12.lk21official.cc/movie-a-2020", "poster_url": ""},
            {"title": "Movie B", "year": 2021, "type": "movie",
             "url": "https://tv12.lk21official.cc/movie-b-2021", "poster_url": ""},
            {"title": "Already Complete", "year": 2022, "type": "movie",
             "url": "https://tv12.lk21official.cc/complete-2022",
             "poster_url": "https://img.example.org/poster.jpg"},
        ]
        prior = {"search_checked": {rows[0]["url"]: "search_no_verified_match"}}
        with patch("tools.recheck_redirect_posters.validated", return_value=True):
            self.assertEqual(len(list(targets({"items": rows}, prior))), 0)
            actual = list(targets({"items": rows}, prior, all_missing=True))
        self.assertEqual([index for index, _ in actual], [0, 1])

    def test_source_metadata_ignores_old_catalog_title_year(self):
        html = """<h1>Gangnam Blues (Gangnam 1970) (2015)</h1>
        <meta property="og:image" content="https://poster.assetsy.de/wp-content/uploads/2015/12/film-gangnam-blues-2015.jpg">"""
        result, status = source_metadata(
            html, "https://tv12.lk21official.cc/gangnam-blues-2015")
        self.assertEqual(status, "verified_source_metadata")
        self.assertEqual(result["observed_title"], "Gangnam Blues (Gangnam 1970)")
        self.assertEqual(result["poster_url"],
            "https://poster.assetsy.de/wp-content/uploads/2015/12/film-gangnam-blues-2015.jpg")

    def test_source_metadata_requires_heading_and_real_poster(self):
        url = "https://tv12.lk21official.cc/movie-2020"
        self.assertEqual(source_metadata(
            '<meta property="og:image" content="https://example.org/a.jpg">', url),
            (None, "missing_detail_heading"))
        self.assertEqual(source_metadata("<h1>Movie Example (2020)</h1>", url),
                         (None, "no_detail_poster"))
        self.assertEqual(source_metadata(
            '<h1>Home</h1><meta property="og:image" content="https://example.org/a.jpg">', url),
            (None, "generic_heading"))

    @patch("tools.recheck_redirect_posters.extract_catalog_poster")
    def test_accepts_only_verified_matching_poster(self, extract):
        extract.return_value = ("https://images.example/poster.jpg", "found")
        status, poster = classify("<html></html>", "https://tv12.lk21official.cc/a",
                                  {"title": "A", "year": 2020})
        self.assertEqual(status, "verified_poster")
        self.assertEqual(poster, "https://images.example/poster.jpg")
        extract.return_value = (None, "title_mismatch")
        self.assertEqual(classify("<html></html>", "https://tv12.lk21official.cc/a",
                                  {"title": "A", "year": 2020}),
                         ("title_mismatch", None))


if __name__ == "__main__":
    unittest.main()
