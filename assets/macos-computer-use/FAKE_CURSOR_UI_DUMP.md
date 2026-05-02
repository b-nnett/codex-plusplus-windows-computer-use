# Computer Use Fake Cursor UI Dump

Source bundle:

```text
~/.codex/plugins/cache/openai-bundled/computer-use/1.0.770/Codex Computer Use.app
```

## Correction

`SoftwareCursor.png` is only the plain software pointer style. It is not the full fake cursor UI.

The fake cursor UI is rendered by the macOS service code. The useful extracted assets are the 45 `LensSequence/Lens_frame_*.png` frames; the fog, blur, halo, shadow, activity, and attachment behavior are implemented in Swift/AppKit/SwiftUI.

## Binary Symbols And Strings

`SkyComputerUseService` contains these cursor UI names:

- `ComputerUse.ComputerUseCursor`
- `ComputerUse.ComputerUseCursor.Window`
- `ComputerUse.ComputerUseCursor.Style`
- `ComputerUse.SoftwareCursorStyle`
- `ComputerUse.FogCursorViewModel`
- `ComputerUse.FogCursorStyle`
- `ComputerUse.AgentCursor`
- `ComputerUse.CursorView`
- `ComputerUse.SkyLensView`
- `ComputerUse.SkyLensViewRepresentable`

Observed cursor state fields:

- `velocityX`
- `velocityY`
- `isPressed`
- `activityState`
- `isAttached`
- `angle`
- `cursorWindow`
- `virtualCursor`

Observed fog/lens rendering fields:

- `cursorRadius`
- `fogRadius`
- `cursorScaleAnchorPoint`
- `fogScaleAnchorPoint`
- `maxBlurRadius`
- `blurRadius`
- `saturationAmount`
- `wallpaperCaptureOpacity`
- `dynamicShadowOpacity`
- `dynamicShadowBackdropOpacity`
- `dynamicShadowWallpaperCaptureOpacity`
- `backdropGroupIdentifier`
- `luminanceCurveInputMinimum`
- `luminanceCurveOutputMinimum`
- `luminanceCurveInputMaximum`
- `cursorBlurTransition`
- `filters.gaussianBlur.inputRadius`
- `luminosityBlendMode`

Observed lens animation fields:

- `isAnimating`
- `isTinted`
- `imageLoadingTasks`
- `animationDriver`
- `currentFrameIndex`
- `resetStartFrameIndex`

Relevant feature flags:

- `feature/computerUseCursor`: enables the virtual cursor in Computer Use.
- `feature/detachComputerUseCursor`: detaches the cursor from the command palette.
- `feature/overrideFogSamplingTexture`: samples `~/Pictures/SkyWallpaper.jpg` for fog texture when present.

## Asset Inventory

`Package_ComputerUse.bundle/Contents/Resources/LensSequence`:

- 45 PNG frames named `Lens_frame_00.png` through `Lens_frame_44.png`.
- Each frame is 48x48.

`Package_ComputerUse.bundle/Contents/Resources/Assets.car`:

- `SoftwareCursor`
- `RenditionName`: `Software Cursor.png`
- 200x230 transparent image.

Top-level `Assets.car` includes UI icons such as:

- `Screenshot` / `Viewfinder.png`
- `menubar-cursor`
- `CUAAppIcon_Assets/cursor`
- `CUAAppIcon_Assets/cursor dark`

## Windows Overlay Mapping

The Windows draft maps the macOS UI like this:

- `style: "fog"`: default. Draws a click-through fog halo plus the extracted animated lens sequence centered on the cursor.
- `style: "lens"`: draws only the extracted lens sequence.
- `style: "software"`: draws `SoftwareCursor.png`, falling back to a generated pointer if the asset is missing.
- The overlay itself is a tiny topmost/no-activate/click-through layered window. Each frame is rendered into a 32-bit ARGB bitmap and applied with `UpdateLayeredWindow`, which is the Windows equivalent of a mini UI surface following cursor coordinates.

This is still an approximation because WinForms cannot sample and blur the desktop wallpaper the way the macOS fog cursor does.
