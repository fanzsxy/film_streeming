import unittest

from tools.triage_missing_catalog_posters import analyze, group_status, status_for


class RemainingPosterTriageTests(unittest.TestCase):
    def test_categorize_actual_checkpoint_reasons(self):
        self.assertEqual(group_status("age_gate"), "age_gate")
        self.assertEqual(group_status("redirect"), "redirect")
        self.assertEqual(group_status("year_mismatch"), "metadata_mismatch")
        self.assertEqual(group_status("search_no_verified_match"), "search_no_match")
        self.assertEqual(group_status("missing_detail_heading_or_year"), "detail_metadata_missing")

    def test_no_series_guessing_from_movie_redirect(self):
        catalog = {"items": [
            {"title": "Deadly Weekend", "year": 2013, "type": "movie",
             "url": "https://tv12.lk21official.cc/deadly-weekend-2013",
             "poster_url": "", "synopsis": "intact"}
        ]}
        progress = {"checked": {
            "https://tv12.lk21official.cc/deadly-weekend-2013": "redirect"}}
        rules = {"movie": {"tv12.lk21official.cc"},
                 "series": {"tv.nontondrama.vip"}}
        report = analyze(catalog, progress, {}, {}, {}, rules)
        self.assertEqual(report["by_category"]["redirect"], 1)
        self.assertEqual(report["recoverable_offline"], 0)
        self.assertEqual(catalog["items"][0]["type"], "movie")

    def test_sitemap_state_is_reused_without_network(self):
        catalog = {"items": [
            {"title": "Example", "year": 2020, "type": "movie",
             "url": "https://tv12.lk21official.cc/example-2020", "poster_url": ""}
        ]}
        sitemap_state = {"results": {
            "https://tv12.lk21official.cc/example-2020": {
                "title": "Example", "year": 2020, "type": "movie",
                "url": "https://tv12.lk21official.cc/example-2020",
                "poster_url": "https://img.example.org/p.jpg"}}}
        rules = {"movie": {"tv12.lk21official.cc"}, "series": set()}
        report = analyze(catalog, {}, sitemap_state, {}, {}, rules)
        self.assertEqual(report["recoverable_offline"], 1)
        self.assertEqual(report["proposed_fixes"][0]["source"], "saved_url")
        self.assertEqual(catalog["items"][0]["poster_url"], "")

    def test_later_search_status_does_not_rewrite_detail_evidence(self):
        url = "https://tv12.lk21official.cc/deadly-weekend-2013"
        item = status_for(url, {"checked": {url: "redirect"},
                                "search_checked": {url: "search_no_verified_match"}}, {})
        self.assertEqual(item["poster_detail_status"], "redirect")
        self.assertEqual(item["search_status"], "search_no_verified_match")


if __name__ == "__main__":
    unittest.main()
