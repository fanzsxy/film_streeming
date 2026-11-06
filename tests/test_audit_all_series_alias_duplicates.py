import unittest

from tools.audit_all_series_alias_duplicates import plan


class AllSeriesAliasDuplicateTests(unittest.TestCase):
    def entry(self, title, host, slug, poster="https://images.example.org/a.jpg",
              **extra):
        return {"title": title, "year": 2026, "type": "series",
                "url": "https://" + host + "/" + slug,
                "poster_url": poster, **extra}

    def test_same_page_identical_poster_is_safe(self):
        items = [
            self.entry("25 Years of You", "tv9.nontondrama.my", "25-years-you-2026"),
            self.entry("25 Years You", "tv.nontondrama.vip", "25-years-you-2026"),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 1)
        self.assertEqual(result["review_count"], 0)
        self.assertEqual(result["safe_removals"][0]["keep_index"], 0)
        self.assertEqual(len(items), 2)

    def test_same_poster_different_slug_needs_review_not_delete(self):
        items = [
            self.entry("Alkhallat Series", "tv9.nontondrama.my", "alkhallat-series-2026"),
            self.entry("Alkhallat+: The Series", "tv.nontondrama.vip", "alkhallat-plus-2026"),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)
        self.assertEqual(result["review_count"], 1)

    def test_same_slug_but_conflicting_metadata_needs_review(self):
        items = [
            self.entry("All or Nothing", "tv9.nontondrama.my", "all-or-nothing-2026",
                       tmdb_id=123),
            self.entry("All Nothing", "tv.nontondrama.vip", "all-or-nothing-2026",
                       tmdb_id=456),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)
        self.assertEqual(result["needs_review"][0]["reason"], "metadata_conflict")

    def test_movie_entries_never_auto_merged(self):
        x = self.entry("Some Movie", "tv.nontondrama.vip", "same-2026")
        x["type"] = "movie"
        result = plan({"items": [x, x.copy()]})
        self.assertEqual(result["safe_remove_count"], 0)

    def test_different_poster_does_not_merge(self):
        items = [
            self.entry("A", "tv9.nontondrama.my", "same-2026"),
            self.entry("B", "tv.nontondrama.vip", "same-2026",
                       poster="https://images.example.org/b.jpg"),
        ]
        self.assertEqual(plan({"items": items})["safe_remove_count"], 0)


if __name__ == "__main__":
    unittest.main()
