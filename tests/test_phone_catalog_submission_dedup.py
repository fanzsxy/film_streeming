import base64
import json
import unittest
from unittest.mock import patch, Mock

from backend.phone_catalog_sync import source_identity, known_source_identities


class SourceIdentityTests(unittest.TestCase):
    def test_series_same_path_different_hosts(self):
        a = {"type": "series", "url": "https://tv9.nontondrama.my/25-years-you-2026"}
        b = {"type": "series", "url": "https://tv.nontondrama.vip/25-years-you-2026"}
        self.assertEqual(source_identity(a), source_identity(b))

    def test_other_paths_not_duplicates(self):
        a = {"type": "series", "url": "https://tv9.nontondrama.my/different-2026"}
        b = {"type": "series", "url": "https://tv.nontondrama.vip/25-years-you-2026"}
        self.assertNotEqual(source_identity(a), source_identity(b))

    def test_movie_and_series_never_same_key(self):
        a = {"type": "movie", "url": "https://tv12.lk21official.cc/same-2026"}
        b = {"type": "series", "url": "https://tv.nontondrama.vip/same-2026"}
        self.assertNotEqual(source_identity(a), source_identity(b))

    def test_untrusted_hostname_not_accepted(self):
        self.assertIsNone(source_identity({"type": "series",
            "url": "https://tv.nontondrama.vip.evil.test/show-2026"}))

    @patch("backend.phone_catalog_sync.github")
    @patch("backend.phone_catalog_sync.requests.get")
    def test_pending_open_pr_url_is_known(self, get, github):
        get.return_value = Mock(ok=True)
        get.return_value.json.return_value = {"items": []}
        pending = {"items": [{"type": "series",
            "url": "https://tv.nontondrama.vip/25-years-you-2026"}]}
        file = {"content": base64.b64encode(json.dumps(pending).encode()).decode()}
        github.side_effect = [
            [{"head": {"ref": "automation/phone-catalog-123456abcdef"}}],
            file,
        ]
        seen = known_source_identities("token")
        self.assertIn(("series", "/25-years-you-2026"), seen)

    @patch("backend.phone_catalog_sync.github")
    @patch("backend.phone_catalog_sync.requests.get")
    def test_existing_main_catalog_url_is_known(self, get, github):
        get.return_value = Mock(ok=True)
        get.return_value.json.return_value = {"items": [{"type": "movie",
            "url": "https://tv12.lk21official.cc/verity-2026"}]}
        github.return_value = []
        seen = known_source_identities("token")
        self.assertIn(("movie", "/verity-2026"), seen)


if __name__ == "__main__":
    unittest.main()
