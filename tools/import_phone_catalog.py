"""Import a user-reviewed FilmStream Android export into the main catalog."""
import json
from pathlib import Path
from urllib.parse import urlsplit

from unify_crawler_catalog import CATALOG, canonical, norm_title

INPUT = Path("crawler/imports/phone_catalog.json")

def main():
    if not INPUT.exists():
        print("No phone import present.")
        return
    incoming = json.loads(INPUT.read_text(encoding="utf-8-sig"))
    if not isinstance(incoming, dict) or not isinstance(incoming.get("items"), list):
        raise ValueError("Expected JSON object with items array")
    if len(incoming["items"]) > 5000:
        raise ValueError("Phone export too large")
    doc = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    original = doc["items"]
    urls = {(r.get("type"), str(r.get("url","")).rstrip("/")) for r in original}
    identities = {(r.get("type"), str(r.get("year")), norm_title(str(r.get("title","")))) for r in original}
    added = 0
    skipped = 0
    for row in incoming["items"]:
        if not isinstance(row, dict):
            skipped += 1
            continue
        kind = row.get("type")
        if kind == "tv":
            kind = "series"
        if kind not in ("movie", "series"):
            skipped += 1
            continue
        item = canonical(row, kind)
        if item is None or urlsplit(item["url"]).hostname not in ("tv12.lk21official.cc", "tv.lk21online.de"):
            skipped += 1
            continue
        urlkey = (kind, item["url"].rstrip("/"))
        identity = (kind, str(item["year"]), norm_title(item["title"]))
        if urlkey in urls or identity in identities:
            skipped += 1
            continue
        poster = str(row.get("poster_url") or "")
        if urlsplit(poster).scheme == "https":
            item["poster_url"] = poster
        rating = row.get("rating")
        if isinstance(rating, (float, int)) and not isinstance(rating, bool) and 0 < rating <= 10:
            item["rating"] = rating
        urls.add(urlkey)
        identities.add(identity)
        original.append(item)
        added += 1
    if added:
        CATALOG.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(json.dumps({"phone_added": added, "phone_skipped": skipped, "catalog_total": len(original)}))

if __name__ == "__main__":
    main()
