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

    def test_same_poster_different_slug_is_not_a_url_duplicate(self):
        items = [
            self.entry("Alkhallat Series", "tv9.nontondrama.my", "alkhallat-series-2026"),
            self.entry("Alkhallat+: The Series", "tv.nontondrama.vip", "alkhallat-plus-2026"),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)
        self.assertEqual(result["review_count"], 0)

    def test_same_slug_but_conflicting_metadata_needs_review(self):
        items = [
            self.entry("All or Nothing", "tv9.nontondrama.my", "all-or-nothing-2026",
                       tmdb_id=123),
            self.entry("All Nothing", "tv.nontondrama.vip", "all-or-nothing-2026",
                       tmdb_id=456),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)
        self.assertEqual(result["needs_review"][0]["reason"], "metadata_conflict_same_url_path")

    def test_same_slug_same_year_with_empty_poster_can_merge(self):
        items = [
            self.entry("Title A", "tv9.nontondrama.my", "same-2026"),
            self.entry("Title B", "tv.nontondrama.vip", "same-2026", poster=""),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 1)

    def test_same_slug_different_year_is_not_merged(self):
        items = [
            self.entry("Title A", "tv9.nontondrama.my", "same-2026"),
            self.entry("Title B", "tv.nontondrama.vip", "same-2026"),
        ]
        items[1]["year"] = 2025
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)

    def test_complementary_metadata_is_preserved(self):
        items = [
            self.entry("A", "tv9.nontondrama.my", "same-2026",
                       synopsis="Detail sumber lama"),
            self.entry("B", "tv.nontondrama.vip", "same-2026",
                       tmdb_id=123, rating=8.2),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 1)
        self.assertEqual(result["safe_removals"][0]["updates"],
                         {"rating": 8.2, "tmdb_id": 123})
        self.assertEqual(items[0].get("tmdb_id"), None)

    def test_poster_only_on_alias_can_be_preserved(self):
        items = [
            self.entry("A", "tv9.nontondrama.my", "same-2026", poster=""),
            self.entry("B", "tv.nontondrama.vip", "same-2026",
                       poster="https://images.example.org/valid.jpg"),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 1)
        self.assertEqual(result["safe_removals"][0]["updates"]["poster_url"],
                         "https://images.example.org/valid.jpg")

    def test_movie_entries_never_auto_merged(self):
        x = self.entry("Some Movie", "tv.nontondrama.vip", "same-2026")
        x["type"] = "movie"
        result = plan({"items": [x, x.copy()]})
        self.assertEqual(result["safe_remove_count"], 0)

    def test_different_poster_is_reviewed_not_deleted(self):
        items = [
            self.entry("A", "tv9.nontondrama.my", "same-2026"),
            self.entry("B", "tv.nontondrama.vip", "same-2026",
                       poster="https://images.example.org/b.jpg"),
        ]
        result = plan({"items": items})
        self.assertEqual(result["safe_remove_count"], 0)
        self.assertEqual(result["review_count"], 1)
        self.assertEqual(result["needs_review"][0]["reason"],
                         "poster_conflict_same_url_path")


if __name__ == "__main__":
    unittest.main()
