import unittest

from tools.apply_observed_movie_posters import OBSERVED, proposed_updates
from tools.audit_catalog_completeness import good_poster


class ObservedMoviePosterTests(unittest.TestCase):
    def test_real_avatar_movie_posters_are_valid(self):
        for _url, (_title, _year, poster) in OBSERVED.items():
            self.assertTrue(good_poster(poster), poster)
        self.assertFalse(good_poster("https://example.org/avatars/user.png"))
        self.assertFalse(good_poster("https://example.org/img/default-avatar.jpg"))
        self.assertFalse(good_poster("https://example.org/img/placeholder.png"))
        self.assertFalse(good_poster("https://example.org/img/favicon.ico"))

    def test_five_exact_urls_are_eligible(self):
        rows = [
            {"url": url, "title": title, "year": year,
             "type": "movie", "poster_url": ""}
            for url, (title, year, poster) in OBSERVED.items()
        ]
        updates, rejected, missing = proposed_updates({"items": rows})
        self.assertEqual(len(updates), 5)
        self.assertEqual(rejected, [])
        self.assertEqual(missing, [])

    def test_catalog_display_title_and_year_do_not_block_exact_url(self):
        url, (title, year, poster) = next(iter(OBSERVED.items()))
        catalog = {"items": [{"url": url, "title": title + " (local name)",
                              "year": str(year) + " (catalog variant)",
                              "type": "movie", "poster_url": ""}]}
        updates, rejected, missing = proposed_updates(catalog)
        self.assertEqual(updates, [(0, url, poster)])
        self.assertEqual(rejected, [])

    def test_duplicate_url_is_not_modified(self):
        url, (title, year, poster) = next(iter(OBSERVED.items()))
        row = {"url": url, "title": title, "year": year,
               "type": "movie", "poster_url": ""}
        updates, rejected, missing = proposed_updates({"items": [row, dict(row)]})
        self.assertEqual(updates, [])
        self.assertEqual(len(rejected), 2)

    def test_non_movie_and_existing_poster_are_never_overwritten(self):
        url, (title, year, _) = next(iter(OBSERVED.items()))
        catalog = {"items": [
            {"url": url, "title": "Wrong title", "year": year,
             "type": "series", "poster_url": ""},
            {"url": url, "title": title, "year": year,
             "type": "movie", "poster_url": "https://image.example.org/already.jpg"},
        ]}
        updates, rejected, missing = proposed_updates(catalog)
        self.assertEqual(updates, [])
        self.assertEqual(len(rejected), 2)
        self.assertEqual(len(missing), 4)


if __name__ == "__main__":
    unittest.main()
