"""Translate remaining English TMDB synopses offline, conservatively.

MyMemory public endpoint has quotas: process only a small batch per workflow run.
Never overwrite original English or native Indonesian metadata.
"""
import argparse
import json
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def chunks(text, max_bytes=420):
    parts = re.split(r"(?<=[.!?])\s+", text)
    output, current = [], ""
    for sentence in parts:
        if len(sentence.encode("utf-8")) > max_bytes:
            return None
        test = (current + " " + sentence).strip()
        if len(test.encode("utf-8")) > max_bytes and current:
            output.append(current)
            current = sentence
        else:
            current = test
    if current:
        output.append(current)
    return output


def translate(text):
    pieces = chunks(text)
    if not pieces or len(pieces) > 5:
        return None
    translated = []
    for piece in pieces:
        url = "https://api.mymemory.translated.net/get?" + urlencode({
            "q": piece, "langpair": "en|id"
        })
        request = Request(url, headers={"User-Agent": "FilmStreamMetadata/1.0"})
        with urlopen(request, timeout=20) as response:
            data = json.load(response)
        answer = (data.get("responseData") or {}).get("translatedText", "").strip()
        if data.get("responseStatus") != 200 or not answer or "MYMEMORY WARNING" in answer.upper():
            return None
        translated.append(answer)
        time.sleep(0.6)
    result = " ".join(translated).strip()
    return result if result and result.casefold() != text.casefold() else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--delay", type=float, default=2.5)
    args = parser.parse_args()
    if args.limit < 1 or args.limit > 50 or args.delay < 2:
        parser.error("limit 1-50 and delay >= 2 required")
    path = Path("assets/catalog/tmdb_cache.jsonl")
    records = [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines() if x.strip()]
    translated = 0
    attempted = 0
    for row in records:
        if attempted >= args.limit:
            break
        if (row.get("tmdb_type") != "tv" or row.get("match_status") != "matched"
                or row.get("overview_id") or row.get("overview_translated_id")
                or not row.get("overview_id_checked")):
            continue
        original = (row.get("overview") or "").strip()
        if not original or len(original) < 30:
            continue
        try:
            result = translate(original)
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            print("Translation service unavailable; stopping:", exc)
            break
        attempted += 1
        if result:
            row["overview_translated_id"] = result
            translated += 1
        time.sleep(args.delay)
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in records), encoding="utf-8")
    tmp.replace(path)
    print(f"Translation attempted: {attempted}; Indonesian drafts stored: {translated}")


if __name__ == "__main__":
    main()
