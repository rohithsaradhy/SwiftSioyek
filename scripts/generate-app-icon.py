#!/usr/bin/env python3
"""Package the original icon artwork into the standard macOS app icon sizes."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
master = root / "Resources/Icon/SwiftSioyek.png"
catalog = root / "Resources/Assets.xcassets"
output = catalog / "AppIcon.appiconset"
output.mkdir(parents=True, exist_ok=True)
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = size * scale
        filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        subprocess.run(
            ["sips", "--resampleHeightWidth", str(pixels), str(pixels),
             str(master), "--out", str(output / filename)],
            check=True, stdout=subprocess.DEVNULL,
        )
        images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
info = {"author": "xcode", "version": 1}
(catalog / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
(output / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
print(output)
