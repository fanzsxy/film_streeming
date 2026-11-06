import unittest
from unittest.mock import patch

from tools.recheck_redirect_posters import targets, classify


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
