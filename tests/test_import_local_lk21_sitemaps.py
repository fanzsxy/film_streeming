"""Offline regression tests for the saved-LK21-sitemap importer."""
import tempfile
import unittest
from pathlib import Path

from tools.import_local_lk21_sitemaps import clean_url, parse_slug, preview


def write_sitemap(path, urls):
    path.write_text(
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        + "".join(f"<url><loc>{url}</loc></url>" for url in urls)
        + "</urlset>", encoding="utf-8")


class SitemapImporterTests(unittest.TestCase):
    def test_rejects_wrong_host_and_non_post(self):
        self.assertIsNone(clean_url("https://evil.example/movie-2025"))
        self.assertIsNone(clean_url("http://tv12.lk21official.cc/movie-2025"))
        self.assertIsNone(clean_url("https://tv12.lk21official.cc/movie-2025?redirect=1"))
        self.assertIsNone(clean_url("https://tv12.lk21official.cc/latest/page/50"))
        self.assertEqual(clean_url("https://tv12.lk21official.cc/movie-2025/"),
                         "https://tv12.lk21official.cc/movie-2025")

    def test_slug_is_provisional_and_year_checked(self):
        row = parse_slug("https://tv12.lk21official.cc/the-mental-2021", 1900, 2027)
        self.assertEqual((row["title"], row["year"]), ("The Mental", 2021))
        self.assertEqual(row["metadata_status"], "sitemap_slug_unverified")
        self.assertIsNone(parse_slug("https://tv12.lk21official.cc/title-no-year", 1900, 2027))
        self.assertIsNone(parse_slug("https://tv12.lk21official.cc/title-2025", 2015, 2024))

    def test_duplicates_and_invalid_sitemap(self):
        existing = {"items": [{"title": "The Mental", "year": 2021,
                               "url": "https://tv12.lk21official.cc/another-2021",
                               "type": "movie"}]}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "sitemap-posts-1.xml"
            write_sitemap(path, [
                "https://tv12.lk21official.cc/another-2021",
                "https://tv12.lk21official.cc/the-mental-2021",
                "https://tv12.lk21official.cc/fresh-film-2023",
                "https://tv12.lk21official.cc/fresh-film-2023",
                "https://tv12.lk21official.cc/no-year",
            ])
            additions, review, stats = preview(existing, [path], 1900, 2027)
            self.assertEqual(len(additions), 1)
            self.assertEqual(additions[0]["title"], "Fresh Film")
            self.assertEqual(stats["new_provisional"], 1)
            self.assertEqual(stats["sitemap_url_entries"], 5)
            self.assertEqual(len(review), 1)


if __name__ == "__main__":
    unittest.main()
