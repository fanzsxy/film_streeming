import unittest
from tools.repair_catalog_missing_posters import search_poster_from_listing

URL = "https://tv12.lk21official.cc/search?s=example"
IMAGE = "https://cdn.example.com/poster.jpg"


def listing(kind=""):
    return f'''<html><body><article class="item">
      <a href="https://tv12.lk21official.cc/sample-movie-2024">
       <img src="{IMAGE}" alt="Sample Movie"></a>
      <h3>Sample Movie</h3><span>2024 {kind}</span>
    </article></body></html>'''


class UnlabeledMovieTests(unittest.TestCase):
    def test_movie_card_without_movie_badge(self):
        poster, status = search_poster_from_listing(
            listing(), URL, {"title": "Sample Movie", "year": 2024, "type": "movie"})
        self.assertEqual((poster, status), (IMAGE, "search_verified"))

    def test_series_label_rejects_movie(self):
        poster, status = search_poster_from_listing(
            listing("Series"), URL, {"title": "Sample Movie", "year": 2024, "type": "movie"})
        self.assertEqual((poster, status), (None, "catalog_type_mismatch_series"))

    def test_unlabeled_card_not_guessed_as_series(self):
        poster, _ = search_poster_from_listing(
            listing(), URL, {"title": "Sample Movie", "year": 2024, "type": "series"})
        self.assertIsNone(poster)

    def test_year_mismatch_not_used(self):
        poster, _ = search_poster_from_listing(
            listing(), URL, {"title": "Sample Movie", "year": 2023, "type": "movie"})
        self.assertIsNone(poster)


if __name__ == "__main__":
    unittest.main()
