import unittest
from tools.review_catalog_duplicates import scan


class CatalogDuplicateReviewTests(unittest.TestCase):
    def setUp(self):
        self.rules = {"movie": {"tv12.lk21official.cc"},
                      "series": {"tv.nontondrama.vip", "tv9.nontondrama.my",
                                 "tv.lk21online.de"}}

    def test_game_of_thrones_pair_not_mutated(self):
        rows = [
            {"title": "Game of Thrones", "year": 2011,
             "url": "https://tv12.lk21official.cc/game-of-thrones-2011",
             "type": "movie"},
            {"title": "Game of Thrones", "year": 2011,
             "url": "https://tv.nontondrama.vip/game-of-thrones-2011",
             "type": "series"}]
        result = scan({"items": rows}, self.rules)
        self.assertEqual(result["duplicate_group_count"], 1)
        self.assertEqual(len(result["domain_type_conflicts"]), 0)
        self.assertEqual(len(rows), 2)

    def test_aliases_are_reported_but_not_removed(self):
        rows = [{"title": "100 Days Lies", "year": 2026,
                 "url": "https://tv9.nontondrama.my/a", "type": "series"},
                {"title": "100 Days of Lies", "year": 2026,
                 "url": "https://tv.nontondrama.vip/b", "type": "series"}]
        result = scan({"items": rows}, self.rules)
        self.assertEqual(result["duplicate_group_count"], 0)
        self.assertEqual(len(result["alias_100_days_lies_review"]), 2)

    def test_wrong_type_is_reported_without_change(self):
        row = {"title": "Chosen", "year": 2022,
               "url": "https://tv12.lk21official.cc/chosen-2022",
               "type": "series"}
        result = scan({"items": [row]}, self.rules)
        self.assertEqual(result["domain_type_conflicts"][0]["expected_type"],
                         "movie")
        self.assertEqual(row["type"], "series")


if __name__ == "__main__":
    unittest.main()
