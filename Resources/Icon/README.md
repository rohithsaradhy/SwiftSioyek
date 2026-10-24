# Swift Sioyek app icon

An ivory open book with an S-shaped fold and brass bookmark on an ink-blue tile. The master PNG preserves the transparent margin around the rounded tile. Created with the built-in image generation tool.

`SwiftSioyek.png` is the original master. `../Assets.xcassets/AppIcon.appiconset` contains the standard macOS icon sizes consumed by Xcode.

The complete generation prompt is saved in `prompt.txt`. To regenerate the icon sizes after updating the master:

```sh
python3 scripts/generate-app-icon.py
```
