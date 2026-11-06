import unittest

from tools.audit_catalog_completeness import audit, issues


class CatalogCompletenessTests(unittest.TestCase):
    def test_checks_only_requested_fields(self):
        row = {"title": "A Film", "url": "https://example.com/a",
               "poster_url": "https://example.com/a.jpg", "type": "movie"}
        self.assertEqual(issues(row), [])  # synopsis intentionally missing

    def test_identifies_movie_series_and_errors(self):
        doc = {"items": [
            {"title": "A Film", "url": "https://example.com/a",
             "poster_url": "https://example.com/p.jpg", "type": "movie"},
            {"title": "A Series", "url": "https://example.com/b",
             "poster_url": "", "type": "series"},
            {"title": "Legacy TV", "url": "https://example.com/c",
             "poster_url": "https://example.com/c.jpg", "type": "tv"},
            {"title": "", "url": "http://example.com/d",
             "poster_url": None, "type": "not_movie"},
        ]}
        report = audit(doc)
        self.assertEqual(report["summary"]["total"], 4)
        self.assertEqual(report["summary"]["incomplete"], 2)
        self.assertEqual(report["summary"]["missing_poster"], 2)
        self.assertEqual(report["summary"]["missing_type"], 1)
        self.assertEqual(report["summary"]["series_incomplete"], 1)

    def test_duplicate_url_is_reported_without_marking_missing(self):
        row = {"title": "A", "url": "https://example.com/a/",
               "poster_url": "https://example.com/p.jpg", "type": "movie"}
        doc = {"items": [row, {**row, "url": "https://example.com/a"}]}
        report = audit(doc)
        self.assertEqual(report["summary"]["duplicate_url"], 1)
        self.assertEqual(report["summary"]["incomplete"], 0)


if __name__ == "__main__":
    unittest.main()
