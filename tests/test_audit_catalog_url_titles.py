import unittest

from tools.audit_catalog_url_titles import audit, url_title


class CatalogUrlTitlesTests(unittest.TestCase):
    def test_year_suffix_and_punctuation(self):
        self.assertEqual(url_title(
            "https://tv12.lk21official.cc/avatar-fire-ash-2025")[0],
            "avatarfireash")

    def test_matches_and_mismatches_without_mutation(self):
        document = {"items": [
            {"title": "Avatar: Fire Ash", "year": 2025,
             "url": "https://tv12.lk21official.cc/avatar-fire-ash-2025"},
            {"title": "Chosen", "year": 2022,
             "url": "https://tv.nontondrama.vip/fellow-travelers-2023"},
            {"title": "Gangnam Blues (Gangnam 1970)", "year": 2015,
             "url": "https://tv12.lk21official.cc/gangnam-blues-2015"},
        ]}
        result = audit(document)
        self.assertEqual(result["total"], 3)
        self.assertEqual(result["exact_match_count"], 1)
        self.assertEqual(result["possible_mismatch_count"], 2)
        self.assertEqual(document["items"][1]["title"], "Chosen")

    def test_uncheckable_url(self):
        result = audit({"items": [{"title": "Film", "url": "https://example.org/"}]})
        self.assertEqual(result["uncheckable_count"], 1)


if __name__ == "__main__":
    unittest.main()
