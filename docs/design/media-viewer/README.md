# Media viewer · 2026-10-29

Photos and videos in the Files tab now use `App/MediaViewer.swift`. Other document formats keep the existing Quick Look route.

- Dark photo canvas, filename and current position; labeled information/share/save/delete actions in one bottom toolbar.
- Horizontal paging, explicit previous/next buttons, pinch zoom, double-tap zoom, tap to toggle chrome and downward swipe to close at fit scale.
- Zooming enables image panning and disables page navigation until fit scale is restored. Images load on page appearance, with serial off-main decoding. Initial decode is bounded to 4096px; detail on zoom is bounded to 6144px. Images are released when the page leaves. No app-owned disk image cache was added.
- Information includes file size, pixel dimensions, EXIF capture time/camera when present, file modification time and video duration when available. Modification time is not mislabeled as capture time.
- System sharing uses the original file URL. Save to Photos is an explicit add-only permission request and adds the original file with `shouldMoveFile = false`. It saves the selected file, not a reconstructed Live Photo resource group. No photo editing or re-encoding is performed.
- Destructive deletion requires confirmation and reuses the existing scoped directory deletion guard. It is disabled while the backup model disallows file deletion. Removing the last item closes the viewer.
- Video uses an embedded AVPlayerViewController and pauses when its page leaves. No background-media mode was introduced.

## Validation

Debug simulator/device builds and localization checks passed (422 app strings, 2 permission strings). The simulator-only decoder/controller probe passed bounded decoding, EXIF rotation, metadata dimensions, unavailable-file errors, centering, programmatic zoom/pan enablement, restoring fit-scale paging, releasing images and preserving original bytes. See `checks.json`.

Native screenshots: [viewer](../editable-ui/native/viewer.png), [next item](../editable-ui/native/viewer-next.png), [zoom](../editable-ui/native/viewer-zoom.png), [information](../editable-ui/native/viewer-info.png), [video](../editable-ui/native/viewer-video.png).

These screenshots use sandbox fixtures. The two-second MP4 was generated from a test pattern solely to check video compatibility. No camera or screen recording was used; the test movie is not included in the app bundle. Real-device save/share/delete and physical touch gestures are not claimed as manually verified by these checks.

The signed build was installed on the paired iPhone 15 Pro at 00:41. Simulator shut down after verification.

## Compact toolbar follow-up

The four bottom actions now use 18pt icons without visible labels. VoiceOver labels remain, each hit target remains 44pt high, and toolbar padding is reduced to 2pt vertically. The bottom gradient is lighter to reduce image obstruction. Tap-to-hide behavior is unchanged.

The information sheet no longer has a visible “知道了” confirmation button. It keeps the standard drag indicator and interactive sheet dismissal.
