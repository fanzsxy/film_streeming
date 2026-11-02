"""Generate Android mipmap launcher icons from the supplied Film Streaming artwork.
Run before Flutter/Gradle builds: python tools/generate_android_icons.py
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/branding/film_streaming_icon.png"
RES = ROOT / "android/app/src/main/res"
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

def main():
    with Image.open(SOURCE) as raw:
        icon = raw.convert("RGBA")
        if icon.width != icon.height:
            raise ValueError("Launcher artwork must be square")
        for density, size in SIZES.items():
            folder = RES / f"mipmap-{density}"
            folder.mkdir(parents=True, exist_ok=True)
            out = folder / "ic_launcher.png"
            icon.resize((size, size), Image.Resampling.LANCZOS).save(out, "PNG")
            print(f"Generated {out.relative_to(ROOT)}")

if __name__ == "__main__":
    main()
