import unittest
from tools.local_lk21_gap_match import extract_matches, detail_title_year

class FalseNegativeTests(unittest.TestCase):
    def test_unusual_search_card_slug(self):
        html = '<div><a href="/william-tell-2025">William Tell</a></div>'
        rows = extract_matches(html, "2025", ["William Tell"])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["url"], "https://tv12.lk21official.cc/william-tell-2025")

    def test_detail_heading(self):
        title, year = detail_title_year('<h1>William Tell (2025)</h1>')
        self.assertEqual((title, year), ("William Tell", 2025))

    def test_wrong_year_rejected(self):
        html = '<a href="/william-tell-2024">William Tell</a>'
        self.assertEqual(extract_matches(html, "2025", ["William Tell"]), [])

if __name__ == "__main__":
    unittest.main()
