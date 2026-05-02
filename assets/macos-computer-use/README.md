# macOS Computer Use Visual Assets

Copied from:

```text
~/.codex/plugins/cache/openai-bundled/computer-use/1.0.770/Codex Computer Use.app/Contents/Resources/Package_ComputerUse.bundle/Contents/Resources
```

## Files

- `AppAssets.car`: original top-level `Codex Computer Use.app/Contents/Resources/Assets.car`.
- `ComputerUseAssets.car`: original `Package_ComputerUse.bundle` CoreUI asset catalog.
- `SlimCoreAssets.car`: original `Package_SlimCore.bundle` CoreUI asset catalog.
- `app-assets-info.json`: `assetutil --info` dump for `AppAssets.car`.
- `assets-info.json`: `assetutil --info` dump for `ComputerUseAssets.car`.
- `slimcore-assets-info.json`: `assetutil --info` dump for `SlimCoreAssets.car`.
- `app-icon.png`: plugin marketplace icon.
- `CUAAppIcon.icns`: app icon.
- `SoftwareCursor.png`: extracted software pointer image. This is not the full fake cursor UI.
- `FAKE_CURSOR_UI_DUMP.md`: notes from the binary/asset dump for the Swift-rendered fog/lens cursor UI.
- `extracted/`: extracted PNGs and manifests from the Computer Use `.car` files.
- `LensSequence/Lens_frame_00.png` through `Lens_frame_44.png`: plain PNG frames, 48x48, 16-bit RGBA.

Extracted PNGs currently include:

- `SoftwareCursor.png` (200x230)
- `extracted/App/Accessibility.png` (58x59)
- `extracted/Package_ComputerUse/SoftwareCursor.png` (200x230)
- `extracted/Package_SlimCore/SoftwareCursor.png` (200x230)
- `extracted/Package_SlimCore/HintArrow.png` (29x33)

## Packed Software Cursor Asset

The software pointer asset is packed inside `ComputerUseAssets.car`.

`xcrun assetutil --info ComputerUseAssets.car` reports:

```json
{
  "AssetType": "Image",
  "Name": "SoftwareCursor",
  "RenditionName": "Software Cursor.png",
  "PixelWidth": 200,
  "PixelHeight": 230,
  "Scale": 1,
  "Opaque": false,
  "SHA1Digest": "16D47273031B7D8E898B283601F3A35CB03F5015C425DBCBE038BBA89BA94329"
}
```

Stock `assetutil` can inspect and thin `.car` files but does not expose a PNG extraction command. `scripts/extract-macos-coreui-assets.m` uses the private CoreUI runtime to extract the PNGs.

The actual fake cursor surface appears to be rendered by SwiftUI/AppKit code, not stored as one static PNG. See `FAKE_CURSOR_UI_DUMP.md`.
