"""Offline source-page title extraction and conservative title replacement checks."""
import unittest

from recover_source_titles_genres import extract_title, extract_genres, parse_source_metadata, safe_title_upgrade


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


    def test_source_genres_only_near_detail_header(self):
        page = """
        <html><nav><a href="/genre/horror">Horror</a></nav>
        <h1>When I Meet the Moon (2026)</h1>
        <div class="metadata">
          <a href="/country/china">China</a>
          <a href="/genre/drama">Drama</a>
          <a href="/genre/romance">Romance</a>
        </div>
        <a href="/watch">Play Awal</a>
        <section class="related"><a href="/genre/action">Action</a></section>
        </html>
        """
        self.assertEqual(
            parse_source_metadata(page, 2026),
            ("When I Meet the Moon", ["Drama", "Romance"]),
        )
        self.assertEqual(extract_genres(page, 2024), [])

    def test_history_and_fantasy_from_source(self):
        page = """
        <nav><a>Western</a></nav>
        <h1>The Remarried Empress (2026)</h1>
        <a>South Korea</a><a>Drama</a><a>Fantasy</a>
        <a>History</a><a>Romance</a><a>Play Awal</a>
        <section><h2>Related</h2><a>Horror</a></section>
        """
        self.assertEqual(extract_genres(page, 2026),
                         ["Drama", "Fantasy", "History", "Romance"])

    def test_menu_genre_must_not_fill_missing_genre(self):
        page = '<nav><a>Drama</a><a>Action</a></nav><h1>Unknown (2026)</h1><a>China</a><a>Play Awal</a>'
        self.assertEqual(extract_genres(page, 2026), [])

    def test_reject_unrelated_work(self):
        item = {"title": "When I Meet Moon", "year": 2026,
                "url": "https://tv.nontondrama.vip/when-i-meet-moon-2026"}
        self.assertFalse(safe_title_upgrade(item, "When I Met the Sun"))
        self.assertFalse(safe_title_upgrade(item, "The World of Love"))


if __name__ == "__main__":
    unittest.main()
