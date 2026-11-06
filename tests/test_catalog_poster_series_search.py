import unittest

from tools.repair_catalog_missing_posters import search_poster_from_listing

BASE = "https://tv12.lk21official.cc/search?s=true+blood"
POSTER = "https://images.example/true-blood.jpg"

def card(title="True Blood", year="2008", kind="Series"):
    return f"""<html><body><article class="item">
        <a href="https://tv12.lk21official.cc/true-blood-2008">
          <img src="{POSTER}" alt="{title}"/>
        </a>
        <h3>{title}</h3><span>({year}) - {kind}</span>
        </article></body></html>"""


class SeriesRedirectSearchTests(unittest.TestCase):
    def test_series_poster_from_visible_search_result(self):
        poster, status = search_poster_from_listing(
            card(), BASE, {"title": "True Blood", "year": 2008, "type": "series"})
        self.assertEqual((poster, status), (POSTER, "search_verified"))

    def test_movie_type_mismatch_reported_not_assigned(self):
        poster, status = search_poster_from_listing(
            card(), BASE, {"title": "True Blood", "year": 2008, "type": "movie"})
        self.assertIsNone(poster)
        self.assertEqual(status, "catalog_type_mismatch_series")

    def test_wrong_year_rejected(self):
        poster, status = search_poster_from_listing(
            card(year="2009"), BASE, {"title": "True Blood", "year": 2008, "type": "series"})
        self.assertIsNone(poster)

    def test_wrong_title_rejected(self):
        poster, status = search_poster_from_listing(
            card(title="Other Blood"), BASE, {"title": "True Blood", "year": 2008, "type": "series"})
        self.assertIsNone(poster)


if __name__ == "__main__":
    unittest.main()
