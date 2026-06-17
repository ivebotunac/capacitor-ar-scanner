# Changelog

## 8.0.0 (2026-06-17)

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
