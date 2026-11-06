import json
import tempfile
import unittest
from pathlib import Path

from tools.repair_catalog_types_by_domain import (
    expected_type, load_host_rules, scan, MOVIE_HOSTS,
)


class CatalogTypeByDomainTests(unittest.TestCase):
    def setUp(self):
        self.rules = {
            "movie": set(MOVIE_HOSTS),
            "series": {"tv.nontondrama.vip", "tv9.nontondrama.my", "tv.lk21online.de"}
        }

    def test_exact_movie_host(self):
        self.assertEqual(expected_type("https://tv12.lk21official.cc/deadly-weekend-2013",
                                       self.rules), "movie")
        self.assertIsNone(expected_type("https://tv12.lk21official.cc.evil.test/a",
                                        self.rules))

    def test_current_and_legacy_series_hosts(self):
        for host in self.rules["series"]:
            self.assertEqual(expected_type(f"https://{host}/true-blood-2008",
                                           self.rules), "series")

    def test_unrecognized_host_and_invalid_urls_untouched(self):
        self.assertIsNone(expected_type("https://unrelated.example.com/s", self.rules))
        self.assertIsNone(expected_type("not-a-url", self.rules))

    def test_scan_only_changes_type(self):
        original = {"items": [
            {"title": "Deadly Weekend", "year": 2013,
             "url": "https://tv12.lk21official.cc/deadly-weekend-2013",
             "type": "series", "poster_url": "", "synopsis": "unchanged"},
            {"title": "True Blood", "year": 2008,
             "url": "https://tv.nontondrama.vip/true-blood-2008",
             "type": "movie", "poster_url": "https://img.example/tb.jpg"},
            {"title": "Legacy", "url": "https://tv9.nontondrama.my/legacy-2020",
             "type": "tv"},
            {"title": "Unknown", "url": "https://unknown.example/unknown",
             "type": "movie"},
        ]}
        report = scan(original, self.rules)
        self.assertEqual(report["summary"]["changes"], 3)
        self.assertEqual(report["summary"]["change_to_series"], 2)
        self.assertEqual(report["summary"]["change_to_movie"], 1)
        self.assertEqual(len(report["unknown"]), 1)
        self.assertEqual(original["items"][0]["type"], "series")
        for change in report["changes"]:
            original["items"][change["index"]]["type"] = change["new_type"]
        self.assertEqual(original["items"][0]["type"], "movie")
        self.assertEqual(original["items"][1]["type"], "series")
        self.assertEqual(original["items"][1]["poster_url"], "https://img.example/tb.jpg")
        self.assertEqual(original["items"][0]["synopsis"], "unchanged")

    def test_reads_legacy_and_active_from_config(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "domains.json"
            path.write_text(json.dumps({"series": {
                "active_base_url": "https://tv.lk21online.de",
                "legacy_hosts": ["tv9.nontondrama.my"],
                "allowed_hosts": ["tv.nontondrama.vip"]
            }}), encoding="utf-8")
            rules = load_host_rules(path)
            self.assertEqual(rules["series"], self.rules["series"])


if __name__ == "__main__":
    unittest.main()
