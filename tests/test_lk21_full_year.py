"""Verify year-scoped unlimited local browser CLI settings without network."""
import unittest
from unittest.mock import patch
from tools.local_lk21_browser_search import main

class YearScopeTests(unittest.TestCase):
    @patch("tools.local_lk21_browser_search.run")
    @patch("sys.argv", ["local_lk21_browser_search", "--year", "2025", "--limit", "0", "--delay", "2"])
    def test_full_2025_cli(self, run):
        main()
        run.assert_called_once_with(0, 2.0, render_wait_ms=800, year=2025)

if __name__ == "__main__":
    unittest.main()
