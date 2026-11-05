"""Offline tests: targeted missing-title search, not year pagination."""
import unittest
from tools.local_lk21_gap_match import discover_search_form, search_url, extract_matches, poster_from_detail

class TargetSearchTests(unittest.TestCase):
    def test_discover_get_form(self):
        form = '<form action="/" method="get"><input name="s" placeholder="Cari film"></form>'
        search = discover_search_form(form)
        self.assertIsNotNone(search)
        url = search_url(search, "The Batman")
        self.assertIn("s=The+Batman", url)
        self.assertNotIn("/year/", url)

    def test_cross_origin_form_rejected(self):
        html = '<form action="https://other.example/search" method="get"><input name="s"></form>'
        self.assertIsNone(discover_search_form(html))

    def test_reject_post_only_form(self):
        html = '<form method="post" action="/search"><input name="s"></form>'
        self.assertIsNone(discover_search_form(html))

    def test_poster_from_search_card(self):
        html = '<article><a href="/the-batman-2022"><img data-src="https://images.example/poster.jpg" alt="The Batman"></a></article>'
        result = extract_matches(html, "2022", ["The Batman"])
        self.assertEqual(result[0]["poster"], "https://images.example/poster.jpg")
        self.assertEqual(result[0]["title"], "The Batman")
        self.assertEqual(result[0]["year"], 2022)

    def test_poster_from_detail_metadata(self):
        html = '<meta property="og:image" content="https://images.example/batman.jpg">'
        self.assertEqual(poster_from_detail(html, "https://tv12.lk21official.cc/the-batman-2022"),
                         "https://images.example/batman.jpg")

    def test_year_and_title_match(self):
        html = '<article><a href="/the-batman-2022"><img alt="The Batman"></a></article>'
        result = extract_matches(html, "2022", ["The Batman"])
        self.assertEqual(len(result), 1)
        self.assertEqual(extract_matches(html, "2023", ["The Batman"]), [])

if __name__ == "__main__":
    unittest.main()
