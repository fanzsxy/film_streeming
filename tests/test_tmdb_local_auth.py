"""TMDB credential handling regressions, no external network."""
import unittest
from unittest.mock import patch, MagicMock
from urllib.error import HTTPError
from tools.tmdb_full_gap_scan import tmdb_get, check_tmdb_auth


class CredentialTests(unittest.TestCase):
    @patch("tools.tmdb_full_gap_scan.urlopen")
    def test_v3_key_in_query_without_bearer_header(self, request):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{"success":true}'
        request.return_value = response
        tmdb_get("configuration", {}, "a" * 32)
        args = request.call_args.args[0]
        self.assertIn("api_key=", args.full_url)
        self.assertNotIn("Authorization", args.headers)

    @patch("tools.tmdb_full_gap_scan.urlopen")
    def test_v4_read_token_as_bearer(self, request):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{"success":true}'
        request.return_value = response
        tmdb_get("configuration", {}, "a-long-v4-read-token")
        args = request.call_args.args[0]
        self.assertNotIn("api_key=", args.full_url)
        self.assertEqual(args.headers["Authorization"], "Bearer a-long-v4-read-token")

    @patch("tools.tmdb_full_gap_scan.urlopen")
    def test_401_error_does_not_include_secret(self, request):
        request.side_effect = HTTPError(
            "https://api.themoviedb.org/3/configuration?api_key=SECRET",
            401, "Unauthorized", {}, None)
        with self.assertRaises(RuntimeError) as ctx:
            check_tmdb_auth("a" * 32)
        self.assertIn("401", str(ctx.exception))
        self.assertNotIn("a" * 32, str(ctx.exception))
        self.assertNotIn("SECRET", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
