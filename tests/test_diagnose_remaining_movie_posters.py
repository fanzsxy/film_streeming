import unittest
from unittest.mock import patch

from tools.diagnose_remaining_movie_posters import summary_rows, inspect_detail


class RemainingMoviePosterDiagnosticsTests(unittest.TestCase):
    def test_only_current_incomplete_movies(self):
        missing = {"type": "movie", "title": "Film", "year": 2019,
                   "url": "https://tv12.lk21official.cc/film-2019",
                   "poster_url": ""}
        catalog = {"items": [missing, {**missing, "type": "series"},
                              {**missing, "poster_url": "https://images.example/poster.jpg"}]}
        state = {"checked": {missing["url"]: {
            "status": "year_mismatch", "final_url": missing["url"]}}}
        with patch("tools.diagnose_remaining_movie_posters.validated", return_value=True):
            rows = summary_rows(catalog, state)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "year_mismatch")

    @patch("tools.diagnose_remaining_movie_posters.poster_from_detail",
           return_value=None)
    def test_inspection_reports_metadata_without_accepting_poster(self, _):
        html = """<html><head><meta property="og:image"
                   content="https://images.example/poster.jpg">
                   <meta property="og:title" content="Alternate name"></head>
                   <h1>Film (2019)</h1><article>
                   <img src="/images/film.jpg"></article></html>"""
        observed = inspect_detail(html, "https://tv12.lk21official.cc/film-2019")
        self.assertEqual(observed["parsed_year"], 2019)
        self.assertEqual(observed["detail_poster"], None)
        self.assertEqual(observed["meta"]["og:title"], "Alternate name")
        self.assertEqual(observed["image_candidates"],
                         ["https://tv12.lk21official.cc/images/film.jpg"])


if __name__ == "__main__":
    unittest.main()
