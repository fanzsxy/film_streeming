"""Build the Windows .ico from the same artwork as the Android launcher."""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = root / "assets/branding/film_streaming_icon.png"
output = root / "windows/runner/resources/app_icon.ico"
output.parent.mkdir(parents=True, exist_ok=True)
with Image.open(source) as img:
    img.convert("RGBA").save(
        output, format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
print("Windows Film Streaming icon:", output)
