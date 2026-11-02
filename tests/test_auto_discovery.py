"""Regression tests for the metadata-only crawler, with no external network."""
import unittest
from unittest.mock import Mock, patch

from tools.auto_discover_lk21 import candidates, read_listing

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
