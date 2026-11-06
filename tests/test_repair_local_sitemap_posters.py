"""Offline tests for focused poster repair; no browser or network required."""
import unittest

from tools.repair_local_sitemap_posters import (
    missing_rows, known_poster, extract_detail_poster, apply_poster,
)

HOST = "https://tv12.lk21official.cc/"


class PosterRepairTests(unittest.TestCase):
    def test_missing_only_and_keep_existing(self):
        document = {"verified": [
            {"title": "Already Complete", "year": 2021,
             "url": HOST + "already-complete-2021", "poster_url": "https://img.example/old.jpg"},
            {"title": "Missing", "year": 2015, "url": HOST + "missing-2015",
             "poster_url": ""},
        ], "age_restricted": []}
        state = {"results": {HOST + "missing-2015": {
            "title": "Missing", "year": 2015, "url": HOST + "missing-2015",
            "poster_url": ""}}}
        self.assertEqual(len(missing_rows(document)), 1)
        self.assertTrue(apply_poster(document, state, HOST + "missing-2015",
                                     "https://img.example/new.jpg"))
        self.assertEqual(document["verified"][0]["poster_url"], "https://img.example/old.jpg")
        self.assertEqual(state["results"][HOST + "missing-2015"]["poster_url"],
                         "https://img.example/new.jpg")
        self.assertFalse(apply_poster(document, state, HOST + "missing-2015",
                                      "https://img.example/another.jpg"))

    def test_existing_catalog_poster_same_url(self):
        row = {"title": "Missing", "year": 2015, "url": HOST + "missing-2015"}
        catalog = {"items": [{"title": "Some Other Title", "year": 2015,
                              "url": HOST + "missing-2015",
                              "poster_url": "https://img.example/correct.jpg"}]}
        self.assertEqual(known_poster(row, catalog), "https://img.example/correct.jpg")

    def test_reject_gate_and_accept_actual_poster(self):
        row = {"title": "Missing", "year": 2015, "url": HOST + "missing-2015"}
        gate = ('<h1>Missing (2015)</h1>'
                '<div>PERINGATAN MATERI KHUSUS DEWASA: silahkan konfirmasi umur</div>'
                '<meta property="og:image" content="https://img.example/site.jpg">')
        self.assertEqual(extract_detail_poster(gate, row["url"], row)[1], "age_gate")
        real = ('<h1>Missing (2015)</h1><div class="poster">'
                '<img src="https://img.example/poster.jpg"></div>')
        self.assertEqual(extract_detail_poster(real, row["url"], row)[0],
                         "https://img.example/poster.jpg")

    def test_no_wrong_title_or_year(self):
        row = {"title": "Correct Film", "year": 2015, "url": HOST + "correct-film-2015"}
        html = ('<h1>Different Film (2015)</h1>'
                '<img src="https://img.example/poster.jpg">')
        self.assertEqual(extract_detail_poster(html, row["url"], row)[1], "title_mismatch")
        html = '<h1>Correct Film (2016)</h1>'
        self.assertEqual(extract_detail_poster(html, row["url"], row)[1], "year_mismatch")


if __name__ == "__main__":
    unittest.main()
