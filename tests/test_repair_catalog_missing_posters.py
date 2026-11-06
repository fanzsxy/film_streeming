"""Offline tests for catalog-wide missing poster repair."""
import json
import tempfile
import unittest
from pathlib import Path

from tools.repair_catalog_missing_posters import (
    apply_poster, cache_posters, catalog_missing, good_poster,
    match_offline, poster_candidates, extract_catalog_poster,
)

HOST = "https://tv12.lk21official.cc/"


class CatalogPosterRepairTests(unittest.TestCase):
    def test_offline_catalog_match_and_preserve_existing(self):
        doc = {"items": [
            {"title": "Sample Film", "year": 2015, "type": "movie",
             "url": HOST + "sample-film-2015", "poster_url": ""},
            {"title": "Sample Film", "year": 2015, "type": "movie",
             "url": HOST + "alternate-sample-film-2015",
             "poster_url": "https://img.example/sample.jpg"},
            {"title": "Full", "year": 2024, "type": "movie",
             "url": HOST + "full-2024", "poster_url": "https://img.example/full.jpg"},
        ]}
        by_url, by_name = poster_candidates(doc, {})
        self.assertEqual(len(catalog_missing(doc)), 1)
        poster, source = match_offline(doc["items"][0], by_url, by_name)
        self.assertEqual(source, "saved_title_year")
        self.assertTrue(apply_poster(doc, 0, poster))
        self.assertEqual(doc["items"][2]["poster_url"], "https://img.example/full.jpg")
        self.assertFalse(apply_poster(doc, 0, "https://img.example/new.jpg"))

    def test_reuse_existing_result_by_exact_url(self):
        doc = {"items": [{"title": "Movie", "year": 2021, "type": "movie",
                          "url": HOST + "movie-2021", "poster_url": ""}]}
        results = {"verified": [{"title": "Movie", "year": 2021, "type": "movie",
                                "url": HOST + "movie-2021",
                                "poster_url": "https://images.example/movie.jpg"}]}
        by_url, by_name = poster_candidates(doc, results)
        self.assertEqual(match_offline(doc["items"][0], by_url, by_name)[0],
                         "https://images.example/movie.jpg")

    def test_skip_ambiguous_posters(self):
        doc = {"items": [{"title": "Film", "year": 2015, "type": "movie",
                          "url": HOST + "a-2015", "poster_url": ""},
                         {"title": "Film", "year": 2015, "type": "movie",
                          "url": HOST + "b-2015", "poster_url": "https://img.example/a.jpg"},
                         {"title": "Film", "year": 2015, "type": "movie",
                          "url": HOST + "c-2015", "poster_url": "https://img.example/b.jpg"}]}
        self.assertIsNone(match_offline(doc["items"][0],
                                       *poster_candidates(doc, {}))[0])

    def test_matched_cache_and_no_network(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "cache.jsonl"
            path.write_text(json.dumps({
                "match_status": "matched", "tmdb_type": "movie",
                "source_url": HOST + "example-2015", "poster_path": "/abc.jpg",
            }) + "\n", encoding="utf-8")
            cache = cache_posters(path)
            row = {"title": "Example", "year": 2015, "type": "movie",
                   "url": HOST + "example-2015"}
            poster, source = match_offline(row, {}, {}, cache)
            self.assertEqual(source, "matched_tmdb_cache")
            self.assertEqual(poster, "https://image.tmdb.org/t/p/w500/abc.jpg")

    def test_adult_words_do_not_hide_valid_detail_poster(self):
        html = """<html><head><meta property="og:image"
          content="https://images.example/actual-poster.jpg"></head><body>
          <h1>Adult Film (2015)</h1><p>materi khusus dewasa</p></body></html>"""
        film = {"title": "Adult Film", "year": 2015, "type": "movie"}
        poster, status = extract_catalog_poster(html, HOST + "adult-film-2015", film)
        self.assertEqual(status, "found")
        self.assertEqual(poster, "https://images.example/actual-poster.jpg")

    def test_gate_without_real_detail_heading_is_not_a_poster(self):
        html = """<html><head><meta property="og:image"
        content="https://images.example/site-logo.jpg"></head>
        <body><h1>Login Gmail Anda</h1></body></html>"""
        poster, status = extract_catalog_poster(
            html, HOST + "adult-film-2015", {"title": "Adult Film", "year": 2015})
        self.assertIsNone(poster)
        self.assertEqual(status, "missing_detail_heading_or_year")

    def test_never_fill_placeholder(self):
        self.assertFalse(good_poster("https://img.example/no-poster.png"))
        self.assertTrue(good_poster("https://img.example/film.jpg"))


if __name__ == "__main__":
    unittest.main()
