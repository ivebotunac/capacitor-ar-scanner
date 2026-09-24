# Changelog

## 8.1.0 (2026-09-24)

### Added

- **`capture({ detectBarcodes: true })` reads retail barcodes on the device.** EAN-13,
  EAN-8 and UPC-E come back in `barcodes`, each with its digits, format and box as
  fractions of the upright photo. iOS reads them with Apple Vision from
  the photo's own frame, since the phone may move after the tap, then from a
  high-resolution still (iOS 16+); Android reads them with ML Kit
  from the full-resolution photo before it shrinks to 1280px. UPC-A comes back as a
  13-digit EAN-13 on both. The option is off by default, and without it `capture()`
  behaves exactly as in 8.0.4. Android now bundles ML Kit barcode scanning, about 2.4 MB.

## 8.0.4 (2026-09-16)

### Fixed

- **iOS: a failed LiDAR measurement no longer fails the capture.** On LiDAR devices
  `capture()` rejected whenever the measurement step could not run (NO_SURFACE,
  NOT_ENOUGH_DEPTH, CANNOT_ISOLATE, HOLD_LEVEL) and discarded the photo it had already
  taken, which failed about half of all captures on Pro iPhones in the field. It now
  resolves with that photo alone, `hasLidar: false` and zero dimensions, the same shape
  as a non-LiDAR device or Android, and sets `lidarFallbackCode` to the reason. It still
  rejects when no photo could be taken.

## 8.0.3 (2026-07-15)

### Fixed

- **iOS: white screen behind the first-run camera permission alert.** The 8.0.2
  permission gate defers the AR session until the user answers, but by then the
  web layer is typically already transparent — exposing the WKWebView's default
  opaque white. `startPreview()` now paints a black backdrop before showing the
  system prompt (restored on deny).

## 8.0.2 (2026-07-15)

### Reliability

- **iOS: `startPreview()` now requests and checks camera permission before running
  the AR session, mirroring the Android contract.** Previously a denied or restricted
  camera permission still resolved the call: the AR session failed silently and the
  preview stayed black with no way for the web layer to know why. The promise now
  rejects with "Camera permission denied" (same message as Android), and the
  permission prompt still appears on the first preview for undetermined status.

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
