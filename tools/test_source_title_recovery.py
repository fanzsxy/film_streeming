"""Offline source-page title extraction and conservative title replacement checks."""
import unittest

from recover_source_titles_genres import extract_title, safe_title_upgrade


class SourceTitleTests(unittest.TestCase):
    def test_extract_expected_h1_only(self):
        document = '<html><head><title>Ad headline</title></head><body><h1>The World of Love (2015)</h1></body></html>'
        self.assertEqual(extract_title(document, 2015), "The World of Love")
        self.assertIsNone(extract_title(document, 2026))

    def test_upgrade_missing_words(self):
        fixtures = [
            ("World Love", "The World of Love", 2015, "world-love-2015"),
            ("When I Meet Moon", "When I Meet the Moon", 2026, "when-i-meet-moon-2026"),
            ("Remarried Empress", "The Remarried Empress", 2026, "remarried-empress-2026"),
        ]
        for old, new, year, slug in fixtures:
            with self.subTest(old=old):
                item = {"title": old, "year": year,
                        "url": "https://tv.nontondrama.vip/" + slug}
                self.assertTrue(safe_title_upgrade(item, new))

    def test_reject_unrelated_work(self):
        item = {"title": "When I Meet Moon", "year": 2026,
                "url": "https://tv.nontondrama.vip/when-i-meet-moon-2026"}
        self.assertFalse(safe_title_upgrade(item, "When I Met the Sun"))
        self.assertFalse(safe_title_upgrade(item, "The World of Love"))


if __name__ == "__main__":
    unittest.main()
