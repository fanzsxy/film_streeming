"""Navigation pacing tests: elapsed loading time counts toward the interval."""
import unittest
from unittest.mock import Mock, patch
from tools.local_lk21_browser_search import NavigationPacer


class PacingTests(unittest.TestCase):
    @patch("tools.local_lk21_browser_search.time.monotonic",
           side_effect=[10.0, 10.0, 10.7, 10.7, 12.4, 12.4])
    def test_only_waits_remaining_time(self, clock):
        page = Mock()
        pacer = NavigationPacer(2.0)
        pacer.before_navigation(page)
        pacer.before_navigation(page)
        pacer.before_navigation(page)
        self.assertEqual(page.wait_for_timeout.call_count, 1)
        self.assertTrue(1299 <= page.wait_for_timeout.call_args.args[0] <= 1302)

    @patch("tools.local_lk21_browser_search.time.monotonic",
           side_effect=[10.0, 10.0, 12.5, 12.5])
    def test_no_wait_if_page_already_took_long_enough(self, clock):
        page = Mock()
        pacer = NavigationPacer(2.0)
        pacer.before_navigation(page)
        pacer.before_navigation(page)
        page.wait_for_timeout.assert_not_called()


if __name__ == "__main__":
    unittest.main()
