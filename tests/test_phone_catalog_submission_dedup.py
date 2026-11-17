import base64
import json
import os
import unittest
from unittest.mock import patch, Mock

from backend.phone_catalog_sync import (
    source_identity, known_source_identities, valid_source_genres,
    submit_catalog, PhoneImport,
)


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

    def test_genres_are_whitelisted_without_guessing(self):
        assert valid_source_genres(["Comedy", "Drama", "Short", "Sci-fi",
                                    "Drama", "Invalid Genre"]) == [
            "Comedy", "Drama", "Short", "Sci-Fi",
        ]
        self.assertEqual(valid_source_genres("Comedy, Drama"), [])
        self.assertEqual(valid_source_genres(["Unknown"]), [])
        self.assertEqual(valid_source_genres(["Action"] * 21), [])

    @patch.dict(os.environ, {
        "FILMSTREAM_SYNC_ENABLED": "1",
        "FILMSTREAM_SYNC_KEY": "test-only-app-key",
        "FILMSTREAM_GITHUB_TOKEN": "test-only-server-token",
    })
    @patch("backend.phone_catalog_sync.known_source_identities",
           return_value=set())
    @patch("backend.phone_catalog_sync.github")
    def test_android_genres_reach_github_import_pr(self, github, known):
        github.side_effect = [
            {"object": {"sha": "known-main-sha"}}, {}, {},
            {"html_url": "https://github.com/fanzsxy/film_streeming/pull/999"},
        ]
        result = submit_catalog(
            PhoneImport(items=[{
                "type": "movie",
                "title": "  The   Latest Film  ",
                "year": 2026,
                "url": "https://tv12.lk21official.cc/the-latest-film-2026",
                "poster_url": "https://cdn.example.org/poster.jpg",
                "genres": ["Comedy", "Drama", "Short", "Drama",
                           "Wrong Genre"],
                "genre_data_source": "untrusted",
            }]),
            x_filmstream_sync_key="test-only-app-key",
        )
        self.assertEqual(result["status"], "review_required")
        self.assertEqual(result["submitted"], 1)
        file_upload = github.call_args_list[2]
        payload = json.loads(base64.b64decode(
            file_upload.kwargs["json"]["content"]))
        item = payload["items"][0]
        self.assertEqual(item["genres"], ["Comedy", "Drama", "Short"])
        self.assertEqual(item["genre_data_source"], "lk21_source")
        self.assertEqual(item["title"], "The Latest Film")
        self.assertEqual(item["type"], "movie")
        known.assert_called_once()

    @patch.dict(os.environ, {
        "FILMSTREAM_SYNC_ENABLED": "1",
        "FILMSTREAM_SYNC_KEY": "test-only-app-key",
        "FILMSTREAM_GITHUB_TOKEN": "test-only-server-token",
    })
    @patch("backend.phone_catalog_sync.known_source_identities")
    @patch("backend.phone_catalog_sync.github")
    def test_already_known_submissions_do_not_create_duplicate_pr(
            self, github, known):
        item = {"type": "movie", "title": "Known",
                "year": 2026,
                "url": "https://tv12.lk21official.cc/known-2026",
                "genres": ["Horror"]}
        known.return_value = {source_identity(item)}
        result = submit_catalog(PhoneImport(items=[item]),
                                x_filmstream_sync_key="test-only-app-key")
        self.assertEqual(result["status"], "already_known")
        self.assertEqual(result["submitted"], 0)
        github.assert_not_called()

    @patch.dict(os.environ, {
        "FILMSTREAM_SYNC_ENABLED": "0",
        "FILMSTREAM_SYNC_KEY": "old-extractable-key",
        "FILMSTREAM_GITHUB_TOKEN": "test-only-server-token",
    })
    @patch("backend.phone_catalog_sync.github")
    def test_disabled_server_rejects_even_old_correct_client_key(self, github):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as raised:
            submit_catalog(PhoneImport(items=[{"type": "movie"}]),
                           x_filmstream_sync_key="old-extractable-key")
        self.assertEqual(raised.exception.status_code, 503)
        github.assert_not_called()

    @patch.dict(os.environ, {
        "FILMSTREAM_SYNC_ENABLED": "1",
        "FILMSTREAM_SYNC_KEY": "new-server-only-key",
        "FILMSTREAM_GITHUB_TOKEN": "test-only-server-token",
    })
    @patch("backend.phone_catalog_sync.github")
    def test_wrong_key_never_reaches_github(self, github):
        from fastapi import HTTPException
        with self.assertRaises(HTTPException) as raised:
            submit_catalog(PhoneImport(items=[{"type": "movie"}]),
                           x_filmstream_sync_key="old-extractable-key")
        self.assertEqual(raised.exception.status_code, 401)
        github.assert_not_called()

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
