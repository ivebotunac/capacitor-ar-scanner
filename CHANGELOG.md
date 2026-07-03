# Changelog

## 8.0.1 (2026-07-03)

### Reliability

- **Android: `startPreview()` resolves only after CameraX is bound.** Previously it
  resolved immediately while the camera was still binding (1-3s on low-end devices),
  so `capture()` calls in that window failed with "Preview is not running". A
  resolved promise now means capture is safe; bind failures reject the call instead
  of being silently swallowed.
- **Android: scanEvent errors.** Capture and camera-start failures now emit a
  `scanEvent` of type `error` (mirroring the iOS contract), so the web layer can
  surface a structured reason instead of a generic failure.
- **Android: failed bind cleans up.** The orphaned `PreviewView` is removed and the
  WebView background restored when CameraX fails to bind.

### Changed

- **Capture high-res image capped at 1280px (was 1536px), JPEG quality 0.8 (was
  0.85), both platforms.** Analysis backends downscale to ~1280px anyway; the
  smaller payload uploads faster and fails less on poor networks.

First public release. Aligned to Capacitor 8.

### Features

- **iOS (ARKit + LiDAR):** native AR camera preview rendered behind a transparent
  WebView, real-world dimension/volume measurement (oriented bounding box),
  LiDAR depth extraction with confidence filtering and flying-pixel removal,
  live wireframe mesh overlay, and dual base64 image capture (high-res for AI/ML
  + thumbnail for display).
- **Live scan events:** tracking state, mesh progress/ready, capture
  warnings/errors and camera-health diagnostics via the `scanEvent` listener.
- **Torch control** while the preview is running.
- **Android:** ARCore-based capture (image-only measurement parity in progress).
- **Web:** graceful `unavailable` stubs.

### Reliability

- **Long-idle cold-start white-screen fix (iOS):** self-healing AR preview.
  - Dead session renders black (not white) as a diagnostic marker.
  - Frame watchdog re-asserts transparency and restarts/rebuilds a stalled session.
  - `ARSessionObserver` handles `didFailWithError` / interruptions.
  - KVO on `webView.isOpaque` re-asserts transparency the instant Capacitor (or
    anything else) makes the WebView opaque again after `didFinish`, which is the
    root cause of the live-session-behind-a-white-WebView failure.
  - New `camera_preview_health` style diagnostics via `ScanEvent` `health`
    statuses (`stalled`, `recovered`, `sessionFailed`, `noSuperview`,
    `opaqueReasserted`).
