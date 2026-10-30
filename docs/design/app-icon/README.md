# Luna Sync layered app icon

Production source: `App/AppIcon.icon/`, an Icon Composer package containing `icon.json` and three editable SVG assets. Both Debug and Release compile this package as the primary AppIcon.

The warm terracotta background and the sage/cream photo prints retain the current app palette. The separate heart and photo-print groups let the system render glass highlights, translucency and shadows. Group order is front to back in the document: heart, front print, back print. Effects are not baked into SVG artwork.

The new artwork is drawn directly as SVG, rather than tracing or wrapping the earlier generated bitmap. The previous imagegen PNG and its original prompt below are preserved only for design history, outside the production asset catalog.

## Preview and validation

`default.png` and the five appearance previews are exports from the bundled Apple `ictool`, using the iOS platform and Default, Dark, ClearLight, ClearDark, TintedLight and TintedDark renditions. They are design previews; these PNG files are not the installed icon source. Tint previews use the tool's default tint.

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" App/AppIcon.icon --export-image --output-file /tmp/luna-icon.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
```

Xcode compiles the source package together with the asset catalog, including compatibility renditions for supported earlier iOS versions. Do not restore the old AppIcon.appiconset alongside it.

Apple references:
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- https://developer.apple.com/videos/play/wwdc2025/361/

## Previous PNG generation prompt

Use case: logo-brand. Asset type: production iOS app icon, one single square 1024x1024 image, full bleed opaque background, no device mockup. Design an elegant, warm, memorable icon for Luna Sync, a personal photo backup app. The existing app uses creamy paper #FCF8F2, warm terracotta #96533F, pale sage #D9E2CF and blush #F4DACA, rounded paper photo cards and a heart motif. Composition: a large beautifully proportioned ivory photographic print with softly rounded corners, very subtly tilted clockwise, with one pale sage photo card offset behind to the upper left. On the front print's inset warm blush picture area is a single bold terracotta heart, centered, beautifully shaped. Thick ivory bottom photo margin. Warm terracotta background across the ENTIRE square canvas, with very subtle rich tonal variation. The central stack occupies approximately 70 percent of canvas width and height, generous margins for iOS corner clipping. Refined tactile matte paper, delicate depth and restrained soft shadows, modern premium minimal editorial illustration, crisp silhouette legible at tiny app icon size. Flat frontal view, no perspective distortion. No text, no letters, no numbers, no arrows, no drive, no extra symbols, no outlines around the heart, no border around the canvas. Do not draw rounded external icon corners; iOS applies its own mask. This is the actual icon asset, not a presentation.

## Device build acceptance (2026-10-27)

- Xcode 26.3 Debug iOS build succeeded with `App/AppIcon.icon` passed to actool; the previous PNG set is absent from the production catalog.
- Compiled Assets.car includes the three SVG vector assets, icon groups and AppIcon.iconstack, plus generated compatibility images. The host macOS 15 assetutil cannot fully decode the newer icon-group records; direct ictool exports and the Xcode build succeeded.
- Installed successfully on the paired iPhone 15 Pro (`dev.lunasync.app`). Physical home-screen appearance has not been captured.
