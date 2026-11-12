"""Guard against shipping the catalog submission key in public binaries."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class NoEmbeddedCatalogSyncKeyTests(unittest.TestCase):
    def test_flutter_does_not_read_a_shared_catalog_key(self):
        source = (ROOT / "lib/startup_catalog_check.dart").read_text(encoding="utf-8")
        self.assertNotIn("String.fromEnvironment('FILMSTREAM_SYNC_KEY')", source)
        self.assertNotIn("X-Filmstream-Sync-Key", source)
        self.assertNotIn("http.post(", source)
        self.assertIn("filmstream_auto_sync_pending_v1", source)
        self.assertIn("FilmStreamCatalog.syncReviewedCatalog()", source)

    def test_release_workflows_do_not_embed_catalog_key(self):
        for path in (".github/workflows/build-apk.yml",
                     ".github/workflows/build-windows.yml"):
            with self.subTest(workflow=path):
                workflow = (ROOT / path).read_text(encoding="utf-8")
                self.assertNotIn("FILMSTREAM_SYNC_KEY", workflow)
                self.assertIn("flutter build ", workflow)

    def test_backend_requires_explicit_opt_in(self):
        source = (ROOT / "backend/phone_catalog_sync.py").read_text(encoding="utf-8")
        self.assertIn('os.environ.get("FILMSTREAM_SYNC_ENABLED") != "1"', source)
        self.assertIn('hmac.compare_digest(x_filmstream_sync_key, configured)', source)


if __name__ == "__main__":
    unittest.main()
