import unittest

from tools.repair_misclassified_series import series_card_matches, candidates

BASE = "https://tv12.lk21official.cc/search?s=true+blood"
POSTER = "https://img.example.com/true-blood.jpg"


def card(name="True Blood", year=2008, label="Series", url_year=2008):
    return (f'<article class="item"><a href="https://tv12.lk21official.cc/'
            f'true-blood-{url_year}"><img src="{POSTER}" alt="{name}"></a>'
            f'<h3>{name}</h3><p>({year}) - {label}</p></article>')


class SeriesTypeCorrectionTests(unittest.TestCase):
    def test_verified_series_card(self):
        rows = series_card_matches(card(), BASE,
                                   {"title": "True Blood", "year": 2008, "type": "movie"})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["type"], "series")
        self.assertEqual(rows[0]["poster_url"], POSTER)

    def test_movie_label_rejected(self):
        self.assertEqual(series_card_matches(card(label="Movie"), BASE,
            {"title": "True Blood", "year": 2008}), [])

    def test_wrong_title_or_year_rejected(self):
        self.assertEqual(series_card_matches(card(name="Other Blood"), BASE,
            {"title": "True Blood", "year": 2008}), [])
        self.assertEqual(series_card_matches(card(url_year=2009), BASE,
            {"title": "True Blood", "year": 2008}), [])
        self.assertEqual(series_card_matches(card(year=2009), BASE,
            {"title": "True Blood", "year": 2008}), [])

    def test_only_problematic_movie_rows_are_checked(self):
        doc = {"items": [
            {"title": "True Blood", "year": 2008, "type": "movie",
             "url": "https://tv12.lk21official.cc/true-blood-2008", "poster_url": ""},
            {"title": "Another", "year": 2008, "type": "series",
             "url": "https://tv12.lk21official.cc/another-2008", "poster_url": ""},
        ]}
        previous = {"checked": {"https://tv12.lk21official.cc/true-blood-2008": "redirect"}}
        self.assertEqual(len(list(candidates(doc, previous))), 1)


if __name__ == "__main__":
    unittest.main()
