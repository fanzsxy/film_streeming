import unittest

from tools.remove_confirmed_series_alias_duplicates import plan


class ConfirmedSeriesAliasCleanupTests(unittest.TestCase):
    def rows(self):
        poster_a = "https://poster.assetsy.de/wp-content/uploads/2026/07/film-25-years-you-2026-lk21.jpg"
        poster_b = "https://poster.assetsy.de/wp-content/uploads/2026/10/film-100-days-lies-2026-lk21.jpg"
        return [
            {"title": "25 Years of You", "year": 2026, "type": "series",
             "url": "https://tv9.nontondrama.my/25-years-you-2026",
             "poster_url": poster_a},
            {"title": "25 Years You", "year": 2026, "type": "series",
             "url": "https://tv.nontondrama.vip/25-years-you-2026",
             "poster_url": poster_a},
            {"title": "100 Days of Lies", "year": 2026, "type": "series",
             "url": "https://tv9.nontondrama.my/100-days-lies-2026",
             "poster_url": poster_b},
            {"title": "100 Days Lies", "year": 2026, "type": "series",
             "url": "https://tv.nontondrama.vip/100-days-lies-2026",
             "poster_url": poster_b},
            {"title": "Game Of Thrones", "year": 2011, "type": "series",
             "url": "https://tv.nontondrama.vip/game-of-thrones-2011",
             "poster_url": "https://example.org/game.jpg"},
        ]

    def test_exact_two_pairs_and_no_other_records(self):
        doc = {"items": self.rows()}
        result = plan(doc)
        self.assertEqual(result["remove_count"], 2)
        self.assertFalse(result["errors"])
        self.assertEqual([x["remove_index"] for x in result["removals"]], [1, 3])
        self.assertEqual(len(doc["items"]), 5)

    def test_mismatched_poster_blocks_deletion(self):
        rows = self.rows()
        rows[1]["poster_url"] = "https://example.org/other.jpg"
        result = plan({"items": rows})
        self.assertEqual(result["remove_count"], 1)
        self.assertEqual(result["errors"][0]["reason"], "poster_not_identical_and_valid")

    def test_wrong_type_blocks_deletion(self):
        rows = self.rows()
        rows[1]["type"] = "movie"
        result = plan({"items": rows})
        self.assertEqual(result["remove_count"], 1)
        self.assertEqual(result["errors"][0]["reason"], "title_year_or_type_mismatch")

    def test_extra_metadata_conflict_blocks_deletion(self):
        rows = self.rows()
        rows[1]["tmdb_id"] = 42
        result = plan({"items": rows})
        self.assertEqual(result["remove_count"], 1)
        self.assertEqual(result["errors"][0]["reason"],
                         "non_identity_metadata_conflict")

    def test_unrelated_game_of_thrones_and_film_not_removed(self):
        rows = self.rows()
        rows.append({"title": "25 Years You", "year": 2026, "type": "movie",
                     "url": "https://tv12.lk21official.cc/25-years-you-2026",
                     "poster_url": ""})
        result = plan({"items": rows})
        self.assertEqual(result["remove_count"], 2)
        self.assertEqual(len(rows), 6)


if __name__ == "__main__":
    unittest.main()
