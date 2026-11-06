import unittest

from tools.local_lk21_gap_match import detail_title_year


class DetailHeadingReleaseYearTests(unittest.TestCase):
    def test_alternate_title_contains_year(self):
        title, year = detail_title_year(
            "<h1>Gangnam Blues (Gangnam 1970) (2015)</h1>")
        self.assertEqual((title, year), ("Gangnam Blues (Gangnam 1970)", 2015))

    def test_standard_movie_heading(self):
        self.assertEqual(detail_title_year("<h1>Deadly Weekend (2014)</h1>"),
                         ("Deadly Weekend", 2014))

    def test_missing_final_year_is_not_guessed_from_alternate_title(self):
        self.assertEqual(detail_title_year(
            "<h1>Gangnam Blues (Gangnam 1970)</h1>"),
            ("Gangnam Blues", 1970))
        self.assertEqual(detail_title_year("<h1>Film with no release year</h1>"),
                         (None, None))


if __name__ == "__main__":
    unittest.main()
