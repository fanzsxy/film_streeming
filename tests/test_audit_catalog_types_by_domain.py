import unittest

from tools.audit_catalog_types_by_domain import audit, expected_type


class CatalogTypesByDomainTests(unittest.TestCase):
    def test_hosts_are_only_classification_rule(self):
        self.assertEqual(expected_type(
            "https://tv12.lk21official.cc/chosen-2022"), "movie")
        self.assertEqual(expected_type(
            "https://tv12.lk21official.cc/royal-family-2025"), "movie")
        self.assertEqual(expected_type(
            "https://tv.nontondrama.vip/gen-v-2023"), "series")
        self.assertIsNone(expected_type(
            "https://evil.example/chosen-2022"))
        self.assertIsNone(expected_type(
            "http://tv.nontondrama.vip/gen-v-2023"))

    def test_audit_does_not_change_source_metadata(self):
        doc = {"items": [
            {"title": "Chosen", "year": 2022, "type": "series",
             "url": "https://tv12.lk21official.cc/chosen-2022",
             "poster_url": "https://images.example/chosen.jpg"},
            {"title": "Gen V", "year": 2023, "type": "movie",
             "url": "https://tv.nontondrama.vip/gen-v-2023",
             "poster_url": "https://images.example/gen-v.jpg"},
            {"title": "Existing", "type": "tv",
             "url": "https://tv.nontondrama.vip/existing-2020"},
        ]}
        report = audit(doc)
        self.assertEqual(report["mismatch_count"], 2)
        self.assertEqual(
            [r["expected_type"] for r in report["mismatches"]],
            ["movie", "series"])
        self.assertEqual(doc["items"][0]["type"], "series")

    def test_unknown_domains_are_not_assigned_type(self):
        report = audit({"items": [
            {"title": "Unknown", "url": "https://other.example/film",
             "type": "movie"},
        ]})
        self.assertEqual(report["mismatch_count"], 0)
        self.assertEqual(report["unknown_count"], 1)


if __name__ == "__main__":
    unittest.main()
