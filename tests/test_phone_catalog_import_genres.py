"""End-to-end offline test for reviewed Android scanner catalog imports."""
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import import_phone_catalog as importer


class PhoneCatalogGenreImportTests(unittest.TestCase):
    def test_reviewed_scan_genres_are_added_and_import_is_idempotent(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            catalog = root / "assets/catalog/filmstream_catalog.json"
            catalog.parent.mkdir(parents=True)
            before = {
                "items": [{
                    "type": "movie", "title": "Existing", "year": 2026,
                    "url": "https://tv12.lk21official.cc/existing-2026",
                    "genres": ["Drama"],
                }],
            }
            catalog.write_text(json.dumps(before), encoding="utf-8")
            imports = root / "crawler/imports"
            imports.mkdir(parents=True)
            (imports / "phone_test.json").write_text(json.dumps({
                "version": 1, "source": "FilmStream Android WebView",
                "items": [
                    {
                        "type": "movie", "title": "Existing", "year": 2026,
                        "url": "https://tv12.lk21official.cc/existing-2026",
                        "genres": ["Horror"],
                    },
                    {
                        "type": "movie", "title": "New Film", "year": 2026,
                        "url": "https://tv12.lk21official.cc/new-film-2026",
                        "poster_url": "https://cdn.example.org/new.jpg",
                        "genres": ["Comedy", "Drama", "Short",
                                   "Invalid", "Comedy"],
                    },
                    {
                        "type": "series", "title": "New Series", "year": 2026,
                        "url": "https://tv.lk21online.de/new-series-2026",
                        "genres": ["Action", "Adventure"],
                    },
                    {
                        "type": "movie", "title": "Fake", "year": 2026,
                        "url": "https://bad.example/fake-2026",
                        "genres": ["Horror"],
                    },
                ],
            }), encoding="utf-8")
            with (patch.object(importer, "INPUT", imports / "phone_catalog.json"),
                  patch.object(importer, "CATALOG", catalog)):
                with redirect_stdout(io.StringIO()):
                    importer.main()
                    importer.main()  # Repeated merged PRs must not duplicate.
            results = json.loads(catalog.read_text(encoding="utf-8"))["items"]
            self.assertEqual(len(results), 3)
            self.assertEqual(results[0]["genres"], ["Drama"])
            self.assertEqual(results[1]["genres"], ["Comedy", "Drama", "Short"])
            self.assertEqual(results[1]["genre_data_source"], "lk21_source")
            self.assertEqual(results[1]["poster_url"],
                             "https://cdn.example.org/new.jpg")
            self.assertEqual(results[2]["genres"], ["Action", "Adventure"])
            self.assertEqual(results[2]["genre_data_source"], "lk21_source")

    def test_genre_validation_does_not_import_arbitrary_labels(self):
        self.assertEqual(importer.reviewed_genres({
            "genres": ["Sci-fi", "Short", "Nope", "Sci-Fi", "Horror"],
        }), ["Sci-Fi", "Short", "Horror"])
        self.assertEqual(importer.reviewed_genres({"genres": "Horror"}), [])
        self.assertEqual(importer.reviewed_genres({
            "genres": ["Horror"] * 21,
        }), [])


if __name__ == "__main__":
    unittest.main()
