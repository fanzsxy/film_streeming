import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.repair_catalog_missing_posters import atomic_write_text, write_json


class PosterCheckpointWindowsTests(unittest.TestCase):
    def test_retry_permission_error_then_atomic_success(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checkpoint.json"
            path.write_text('{"old": true}', encoding="utf-8")
            from tools import repair_catalog_missing_posters as target
            real_replace = target.os.replace
            count = 0

            def locked_once(src, dest):
                nonlocal count
                count += 1
                if count == 1:
                    raise PermissionError(13, "file locked")
                return real_replace(src, dest)

            with patch.object(target.os, "replace", side_effect=locked_once), \
                 patch.object(target.time, "sleep") as wait:
                write_json(path, {"new": True})
            self.assertEqual(count, 2)
            wait.assert_called_once()
            self.assertEqual(json.loads(path.read_text()), {"new": True})

    def test_failed_retries_preserve_old_checkpoint_and_pending_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checkpoint.json"
            path.write_text('{"old": true}', encoding="utf-8")
            with patch("tools.repair_catalog_missing_posters.os.replace",
                       side_effect=PermissionError(5, "access denied")), \
                 patch("tools.repair_catalog_missing_posters.time.sleep"):
                with self.assertRaisesRegex(PermissionError, "Salinan terbaru"):
                    atomic_write_text(path, '{"new":true}', attempts=2, sleep_seconds=0)
            self.assertEqual(json.loads(path.read_text()), {"old": True})
            pending = list(Path(directory).glob("checkpoint.json.*.pending"))
            self.assertEqual(len(pending), 1)
            self.assertEqual(json.loads(pending[0].read_text()), {"new": True})


if __name__ == "__main__":
    unittest.main()
