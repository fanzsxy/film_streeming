"""Regression tests for the metadata-only crawler, with no external network."""
import unittest
from unittest.mock import Mock, patch

from tools.auto_discover_lk21 import (
    candidates, read_listing, detail_metadata, enrich_new_entries,
)

class CatalogDiscoveryTests(unittest.TestCase):
    def test_valid_card(self):
        html = '<article><a href="/ali-g-who-iz-i-2026"><img alt="Ali G: Who Iz I?"></a></article>'
        rows = candidates(html, "https://tv12.lk21official.cc", "movie")
        self.assertEqual(len(rows), 1)
        self.assertEqual(next(iter(rows.values()))["year"], 2026)

    def test_cross_host_and_missing_year_are_rejected(self):
        html = ('<article><a href="https://evil.example/misc-2026"><img alt="Misc"></a></article>'
                '<article><a href="/missing-year"><img alt="Missing"></a></article>')
        self.assertEqual(candidates(html, "https://tv12.lk21official.cc", "movie"), {})

    def test_listing_preserves_verified_poster(self):
        html = ('<article><a href="/arrival-2026">'
                '<img data-src="https://cdn.example/poster.jpg" alt="Arrival">'
                '</a></article>')
        rows = candidates(html, "https://tv12.lk21official.cc", "movie")
        item = next(iter(rows.values()))
        self.assertEqual(item["poster_url"], "https://cdn.example/poster.jpg")
        self.assertNotIn("genres", item)  # Genre is never guessed from a card.

    def test_source_detail_genres_only_after_matching_h1(self):
        html = ("""<nav><a>Horror</a></nav>
            <h1>Arrival (2026)</h1>
            <p><a>Drama</a><a>Romance</a></p>
            <div>Play Awal</div>
            <h2>Related movies</h2><a>Action</a>
            <meta property="og:image"
                content="https://cdn.example/detail.jpg">""")
        entry = {"title": "Arrival", "year": 2026,
                 "url": "https://tv12.lk21official.cc/arrival-2026"}
        detail = detail_metadata(html, entry)
        self.assertEqual(detail["genres"], ["Drama", "Romance"])
        self.assertEqual(detail["poster_url"], "https://cdn.example/detail.jpg")
        wrong = {**entry, "title": "Different Movie"}
        self.assertEqual(detail_metadata(html, wrong), {})
        wrong_year = {**entry, "year": 2025}
        self.assertEqual(detail_metadata(html, wrong_year), {})

    def test_no_genres_from_navigation_or_recommendations(self):
        html = ('<nav><a>Action</a></nav><h1>Arrival (2026)</h1>'
                '<p>Play Terbaru</p><h2>More like this</h2><a>Horror</a>')
        entry = {"title": "Arrival", "year": 2026,
                 "url": "https://tv12.lk21official.cc/arrival-2026"}
        self.assertEqual(detail_metadata(html, entry), {})

    @patch("tools.auto_discover_lk21.time.sleep")
    def test_only_new_detail_pages_scanned_and_count_capped(self, sleep):
        base = "https://tv12.lk21official.cc"
        items = [
            {"title": "Arrival", "type": "movie", "year": 2026,
             "url": base + "/arrival-2026"},
            {"title": "Later", "type": "movie", "year": 2026,
             "url": base + "/later-2026"},
        ]
        document = "<h1>Arrival (2026)</h1><a>Drama</a>"
        with patch("tools.auto_discover_lk21.read_listing",
                   return_value=document) as fetch:
            stats = enrich_new_entries(Mock(), items, {"movie": base},
                                       {}, detail_limit=1, detail_delay=2)
        self.assertEqual(stats["detail_checked"], 1)
        self.assertEqual(stats["genres_filled"], 1)
        self.assertEqual(items[0]["genres"], ["Drama"])
        self.assertEqual(items[0]["genre_data_source"], "lk21_source")
        self.assertNotIn("genres", items[1])
        fetch.assert_called_once()
        sleep.assert_not_called()

    @patch("tools.auto_discover_lk21.time.sleep")
    def test_detail_access_problem_stops_only_affected_host(self, _):
        base = "https://tv12.lk21official.cc"
        items = [
            {"title": title, "type": "movie", "year": 2026,
             "url": base + "/" + title.lower() + "-2026"}
            for title in ("First", "Second")
        ]
        with patch("tools.auto_discover_lk21.read_listing",
                   return_value=None) as fetch:
            stats = enrich_new_entries(Mock(), items, {"movie": base},
                                       {}, detail_limit=10)
        self.assertEqual(stats["detail_checked"], 1)
        self.assertEqual(stats["genres_filled"], 0)
        self.assertEqual(len(stats["detail_hosts_unavailable"]), 1)
        fetch.assert_called_once()

    def test_robots_policy_cached_between_listing_and_detail(self):
        base = "https://tv12.lk21official.cc"
        session = Mock()
        robots = Mock(status_code=200)
        robots.text = "User-agent: *\\nAllow: /"
        robots.raise_for_status.return_value = None
        listing = Mock(status_code=200)
        listing.url = base + "/latest"
        listing.text = "<h1>Listing</h1>"
        listing.content = listing.text.encode()
        detail = Mock(status_code=200)
        detail.url = base + "/arrival-2026"
        detail.text = "<h1>Arrival (2026)</h1><a>Drama</a>"
        detail.content = detail.text.encode()
        session.get.side_effect = [robots, listing, detail]
        cached = {}
        self.assertIsNotNone(read_listing(session, base, "/latest", cached))
        self.assertIsNotNone(read_listing(session, base, "/arrival-2026", cached))
        self.assertEqual(session.get.call_count, 3)

    def test_http_403_is_not_bypassed(self):
        session = Mock()
        robots = Mock()
        robots.status_code = 200
        robots.text = "User-agent: *\\nAllow: /"
        robots.raise_for_status.return_value = None
        denied = Mock(status_code=403)
        session.get.side_effect = [robots, denied]
        self.assertIsNone(read_listing(session, "https://tv12.lk21official.cc", "/latest"))
        self.assertEqual(session.get.call_count, 2)

if __name__ == "__main__":
    unittest.main()
