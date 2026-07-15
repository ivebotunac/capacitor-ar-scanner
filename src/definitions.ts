import type { PluginListenerHandle } from '@capacitor/core';

export interface ARScannerPlugin {
  /**
   * Check whether AR scanning is available on the current device and what
   * depth quality to expect (LiDAR vs world-tracking only).
   *
   * @since 8.0.0
   */
  checkSupport(): Promise<SupportResult>;

  /**
   * Start the native AR camera preview rendered behind a transparent WebView.
   *
   * On iOS the preview is an `ARSCNView` inserted below the WebView; the WebView
   * is kept transparent so your UI composites on top of the live camera.
   *
   * On Android the returned promise resolves only once the CameraX use cases are
   * actually bound (since 8.0.1), so a resolved promise means `capture()` is safe
   * to call. It rejects if the camera fails to bind or permission is denied.
   *
   * On iOS the camera permission is requested (first call) and checked before the
   * AR session starts (since 8.0.2); like Android, the promise rejects with
   * "Camera permission denied" when access is denied or restricted, instead of
   * resolving into a silently black preview.
   *
   * @since 8.0.0
   */
  startPreview(options?: PreviewOptions): Promise<{ started: boolean }>;

  /**
   * Stop the AR camera preview and tear down the AR session, restoring the
   * WebView to its opaque state. Safe to call when no preview is running.
   *
   * @since 8.0.0
   */
  stopPreview(): Promise<{ stopped: boolean }>;

  /**
   * Capture the current frame and measure the object at the center of the
   * viewfinder, returning real-world dimensions plus base64 images for any
   * downstream AI/ML analysis.
   *
   * @since 8.0.0
   */
  capture(): Promise<ScanResult>;

  /**
   * Toggle the device torch (flashlight) while the preview is running.
   *
   * @since 8.0.0
   */
  setTorch(options: TorchOptions): Promise<{ enabled: boolean }>;

  /**
   * Listen for live scan events emitted during the preview: tracking state,
   * mesh progress, capture warnings/errors and camera-health diagnostics.
   *
   * @since 8.0.0
   */
  addListener(eventName: 'scanEvent', listener: (event: ScanEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Remove all listeners registered by this plugin.
   *
   * @since 8.0.0
   */
  removeAllListeners(): Promise<void>;
}

export interface PreviewOptions {
  /**
   * Preview mode. Currently only `'lidar'` (depth-aware world tracking) is
   * supported; the plugin gracefully falls back to image-only on devices
   * without a LiDAR sensor.
   *
   * @since 8.0.0
   */
  mode?: 'lidar';

  /**
   * Force LiDAR/scene-reconstruction off even on capable devices (image-only
   * capture). Useful for debugging or to match Android behavior.
   *
   * @default false
   * @since 8.0.0
   */
  forceLidarOff?: boolean;
}

export interface TorchOptions {
  /**
   * Whether the torch should be on (`true`) or off (`false`).
   *
   * @since 8.0.0
   */
  enabled: boolean;
}

export interface SupportResult {
  /**
   * Whether AR (world tracking) is supported at all on this device.
   *
   * @since 8.0.0
   */
  isSupported: boolean;

  /**
   * Whether the device has a LiDAR sensor (high-accuracy depth).
   *
   * @since 8.0.0
   */
  hasLidar: boolean;

  /**
   * Whether a depth API is available without LiDAR (reserved for future use).
   *
   * @since 8.0.0
   */
  hasDepthApi: boolean;

  /**
   * Expected depth/measurement quality on this device.
   *
   * @since 8.0.0
   */
  depthQuality: 'high' | 'medium' | 'low' | 'none';
}

export interface ScanResult {
  /**
   * Whether the measurement used LiDAR depth (`true`) or was image-only (`false`).
   *
   * @since 8.0.0
   */
  hasLidar: boolean;

  /**
   * Object width in centimeters.
   *
   * @since 8.0.0
   */
  width: number;

  /**
   * Object height in centimeters.
   *
   * @since 8.0.0
   */
  height: number;

  /**
   * Object depth in centimeters.
   *
   * @since 8.0.0
   */
  depth: number;

  /**
   * Object volume in cubic centimeters (oriented bounding box, W × H × D).
   *
   * @since 8.0.0
   */
  volume: number;

  /**
   * Quality of the depth data used for this measurement.
   *
   * @since 8.0.0
   */
  depthQuality: 'high' | 'medium' | 'low' | 'estimated';

  /**
   * Number of depth points used in the measurement.
   *
   * @since 8.0.0
   */
  pointCount: number;

  /**
   * Whether this was a single capture or a multi-angle scan.
   *
   * @since 8.0.0
   */
  scanMode?: 'single' | 'multi-angle';

  /**
   * Angle of the camera relative to the measured surface, in degrees.
   *
   * @since 8.0.0
   */
  cameraAngle?: number;

  /**
   * The measurement method used.
   *
   * @since 8.0.0
   */
  measureMethod?: 'lidar';

  /**
   * High-resolution (1280px) JPEG, base64-encoded, intended for AI/ML analysis.
   * Not persisted by the plugin.
   *
   * @since 8.0.0
   */
  capturedImageBase64?: string;

  /**
   * Thumbnail (1024px) JPEG, base64-encoded, intended for display/storage.
   *
   * @since 8.0.0
   */
  thumbnailBase64?: string;
}

/**
 * Codes describing why a capture could not produce a measurement.
 *
 * @since 8.0.0
 */
export type CaptureIssueCode = 'NO_SURFACE' | 'NOT_ENOUGH_DEPTH' | 'CANNOT_ISOLATE' | 'HOLD_LEVEL';

export interface ScanEvent {
  /**
   * The kind of event being emitted.
   *
   * @since 8.0.0
   */
  type: 'tracking' | 'meshProgress' | 'meshReady' | 'warning' | 'processing' | 'error' | 'health';

  /**
   * For `type: 'tracking'`: the current AR tracking state.
   *
   * @since 8.0.0
   */
  trackingState?: 'normal' | 'limited' | 'notAvailable';

  /**
   * For `type: 'tracking'` with a limited state: why tracking is limited.
   *
   * @since 8.0.0
   */
  limitedReason?: 'initializing' | 'excessiveMotion' | 'insufficientFeatures' | 'relocalizing';

  /**
   * For `type: 'meshProgress' | 'meshReady'`: number of mesh anchors so far.
   *
   * @since 8.0.0
   */
  meshCount?: number;

  /**
   * For `type: 'meshProgress' | 'meshReady'`: total reconstructed vertices.
   *
   * @since 8.0.0
   */
  vertexCount?: number;

  /**
   * For `type: 'meshProgress'`: whether the mesh has stabilized.
   *
   * @since 8.0.0
   */
  isStable?: boolean;

  /**
   * For `type: 'meshProgress'`: whether enough mesh exists to capture.
   *
   * @since 8.0.0
   */
  isReady?: boolean;

  /**
   * For `type: 'warning' | 'error'`: a human-readable message.
   *
   * @since 8.0.0
   */
  message?: string;

  /**
   * For `type: 'warning' | 'error'`: a machine-readable issue code.
   *
   * @since 8.0.0
   */
  code?: CaptureIssueCode;

  /**
   * For `type: 'warning'` (HOLD_LEVEL): the offending surface angle in degrees.
   *
   * @since 8.0.0
   */
  angle?: number;

  /**
   * For `type: 'processing'`: the capture phase.
   * For `type: 'health'`: one of `'stalled' | 'recovered' | 'sessionFailed' |
   * 'interrupted' | 'interruptionEnded' | 'noSuperview' | 'opaqueReasserted'`.
   *
   * @since 8.0.0
   */
  status?: string;

  /**
   * Health diagnostics: seconds since the last camera frame when a stall was
   * detected.
   *
   * @since 8.0.0
   */
  staleSeconds?: number;

  /**
   * Health diagnostics: which self-heal attempt this is.
   *
   * @since 8.0.0
   */
  attempt?: number;
}
