"""Offline tests: sitemap URL queue, detail parsing, merge without duplicates."""
import tempfile
import unittest
from pathlib import Path

from tools.local_lk21_sitemap_details import (
    detail_metadata, queue_from_sitemaps,
)
from tools.apply_lk21_sitemap_details import plan

BASE = "https://tv12.lk21official.cc/"


def sitemap(path, slugs):
    body = "".join("<url><loc>" + BASE + slug + "</loc></url>" for slug in slugs)
    path.write_text('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
                    + body + "</urlset>", encoding="utf-8")


class LocalSitemapDetailTests(unittest.TestCase):
    def test_queue_skips_existing_but_rechecks_provisional(self):
        catalog = {"items": [
            {"title": "Existing", "year": 2021, "url": BASE + "existing-2021", "type": "movie"},
            {"title": "New Title", "year": 2022, "url": BASE + "new-title-2022",
             "type": "movie", "metadata_status": "sitemap_slug_unverified"},
        ]}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "sitemap.xml"
            sitemap(path, ["existing-2021", "new-title-2022", "fresh-2023",
                           "fresh-2023", "unknown"])
            queue, counts = queue_from_sitemaps(catalog, [path], 1900, 2027)
        self.assertEqual([(r["mode"], r["url"]) for r in queue], [
            ("update", BASE + "new-title-2022"),
            ("add", BASE + "fresh-2023"),
        ])
        self.assertEqual(counts["sitemap_urls"], 5)

    def test_parse_requires_heading_poster_synopsis_and_matching_year(self):
        html = """<html><head><meta property="og:image"
            content="https://images.example/poster.jpg"></head><body>
            <h1>Beautiful Film (2023)</h1>
            <div class="synopsis">This movie follows the long adventures of
            three friends who cross the world to find a missing family.</div>
            </body></html>"""
        row, status = detail_metadata(html, BASE + "beautiful-film-2023", 2023)
        self.assertEqual(status, "verified")
        self.assertEqual(row["title"], "Beautiful Film")
        self.assertIn("three friends", row["synopsis"])
        self.assertEqual(row["metadata_status"], "sitemap_detail_verified")
        self.assertEqual(detail_metadata(html, BASE + "beautiful-film-2023", 2022)[1],
                         "year_mismatch")

    def test_age_gate_detected_and_cataloged_without_fake_metadata(self):
        html = """<html><body><h1>Kabukicho Love Hotel (2015)</h1>
        <p>PERINGATAN! MATERI KHUSUS DEWASA</p>
        <p>Anda dapat membuka halaman ini jika telah berusia 18 tahun ke atas.</p>
        <p>Untuk mengkonfirmasi umur anda silahkan login.</p>
        </body></html>"""
        row, status = detail_metadata(html, BASE + "kabukicho-love-hotel-2015", 2015)
        self.assertIsNone(row)
        self.assertEqual(status, "age_restricted")
        age_entry = {"title": "Kabukicho Love Hotel", "year": 2015,
                     "url": BASE + "kabukicho-love-hotel-2015", "type": "movie",
                     "metadata_status": "sitemap_age_restricted", "age_restricted": True}
        existing = {"items": [{"title": "Existing", "year": 2010,
                               "url": BASE + "existing-2010", "type": "movie"}]}
        updates, additions, stats = plan(
            existing, {"applied": False, "verified": [],
                       "age_restricted": [age_entry]})
        self.assertEqual(len(updates), 0)
        self.assertEqual(stats["age_restricted_additions"], 1)
        self.assertEqual(additions[0]["title"], "Kabukicho Love Hotel")
        self.assertNotIn("poster_url", additions[0])
        self.assertNotIn("synopsis", additions[0])
        existing["items"].append(additions[0])
        self.assertEqual(plan(existing, {"applied": False, "verified": [],
                       "age_restricted": [age_entry]})[2]["additions"], 0)

    def test_plan_upgrades_provisional_and_adds_new_without_tmdb(self):
        catalog = {"items": [
            {"title": "A Film", "year": 2021, "url": BASE + "a-film-2021",
             "type": "movie", "metadata_status": "sitemap_slug_unverified"},
            {"title": "Already", "year": 2020, "url": BASE + "already-2020",
             "type": "movie"},
        ]}
        def row(title, year, slug):
            return {"title": title, "year": year, "url": BASE + slug,
                    "type": "movie", "poster_url": "https://images.example/p.jpg",
                    "synopsis": "A valid movie synopsis.", "metadata_status": "sitemap_detail_verified"}
        report = {"applied": False, "verified": [
            row("A Film", 2021, "a-film-2021"),
            row("Different", 2023, "different-2023"),
            row("Already", 2020, "another-already-2020"),
        ]}
        updates, additions, stats = plan(catalog, report)
        self.assertEqual(len(updates), 1)
        self.assertEqual(len(additions), 1)
        self.assertEqual(stats["duplicates"], 1)


if __name__ == "__main__":
    unittest.main()
