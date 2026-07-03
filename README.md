# capacitor-ar-scanner

AR/LiDAR camera preview, 3D scanning and real-world volume/dimension measurement for Capacitor, powered by ARKit (iOS) and ARCore (Android). Built for AI/ML capture pipelines: it renders a native camera preview behind a transparent WebView and returns precise measurements plus base64 frames you can feed straight into a model.

## Features

- Native AR camera preview behind a transparent WebView (your UI composites on top).
- Real-world width / height / depth / volume from LiDAR depth (oriented bounding box).
- Live wireframe mesh overlay and scan-state events while you aim.
- Dual image capture: high-res (for AI/ML analysis) + thumbnail (for display/storage).
- Torch control.
- Self-healing preview: recovers from the long-idle cold-start white/blank screen and reports camera-health diagnostics.

## Compatibility

| Plugin | Capacitor |
| ------ | --------- |
| `8.x`  | `8.x`     |

The plugin's major version tracks Capacitor's major version.

## Installation

```bash
npm install capacitor-ar-scanner
npx cap sync
```

## iOS

- Minimum deployment target: **iOS 15.0**.
- Best results require a **LiDAR**-capable device; non-LiDAR devices fall back to image-only capture.
- Add a camera usage description to `ios/App/App/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan and measure objects with the camera.</string>
```

The plugin uses `ARKit` and `SceneKit`. The preview is an `ARSCNView` inserted below the (transparent) WebView, so make sure your web UI uses a transparent background while the preview is active.

## Android

- Requires an [ARCore-supported](https://developers.google.com/ar/devices) device.
- Add the camera permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

> Note: the Android implementation currently provides image-only capture; full measurement parity with iOS LiDAR is in progress.

## Usage

```ts
import { ARScanner } from 'capacitor-ar-scanner';

// 1. Check support
const support = await ARScanner.checkSupport();
if (!support.isSupported) return;

// 2. Listen for live scan events (tracking, mesh, warnings, health)
const handle = await ARScanner.addListener('scanEvent', (event) => {
  if (event.type === 'health' && event.status) {
    // e.g. report 'stalled' | 'recovered' | 'opaqueReasserted' to analytics
    console.log('camera health:', event.status, event.attempt, event.staleSeconds);
  }
  if (event.type === 'meshReady') {
    console.log('ready to capture');
  }
});

// 3. Start the preview (transparent WebView required)
await ARScanner.startPreview({ mode: 'lidar' });

// 4. Capture + measure
const result = await ARScanner.capture();
console.log(`${result.width} × ${result.height} × ${result.depth} cm, ${result.volume} cm³`);
// result.capturedImageBase64 -> send to your AI/ML model

// 5. Stop + clean up
await ARScanner.stopPreview();
await handle.remove();
```

## API

<docgen-index>

* [`checkSupport()`](#checksupport)
* [`startPreview(...)`](#startpreview)
* [`stopPreview()`](#stoppreview)
* [`capture()`](#capture)
* [`setTorch(...)`](#settorch)
* [`addListener('scanEvent', ...)`](#addlistenerscanevent-)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### checkSupport()

```typescript
checkSupport() => Promise<SupportResult>
```

Check whether AR scanning is available on the current device and what
depth quality to expect (LiDAR vs world-tracking only).

**Returns:** <code>Promise&lt;<a href="#supportresult">SupportResult</a>&gt;</code>

**Since:** 8.0.0

--------------------


### startPreview(...)

```typescript
startPreview(options?: PreviewOptions | undefined) => Promise<{ started: boolean; }>
```

Start the native AR camera preview rendered behind a transparent WebView.

On iOS the preview is an `ARSCNView` inserted below the WebView; the WebView
is kept transparent so your UI composites on top of the live camera.

On Android the returned promise resolves only once the CameraX use cases are
actually bound (since 8.0.1), so a resolved promise means `capture()` is safe
to call. It rejects if the camera fails to bind or permission is denied.

| Param         | Type                                                      |
| ------------- | --------------------------------------------------------- |
| **`options`** | <code><a href="#previewoptions">PreviewOptions</a></code> |

**Returns:** <code>Promise&lt;{ started: boolean; }&gt;</code>

**Since:** 8.0.0

--------------------


### stopPreview()

```typescript
stopPreview() => Promise<{ stopped: boolean; }>
```

Stop the AR camera preview and tear down the AR session, restoring the
WebView to its opaque state. Safe to call when no preview is running.

**Returns:** <code>Promise&lt;{ stopped: boolean; }&gt;</code>

**Since:** 8.0.0

--------------------


### capture()

```typescript
capture() => Promise<ScanResult>
```

Capture the current frame and measure the object at the center of the
viewfinder, returning real-world dimensions plus base64 images for any
downstream AI/ML analysis.

**Returns:** <code>Promise&lt;<a href="#scanresult">ScanResult</a>&gt;</code>

**Since:** 8.0.0

--------------------


### setTorch(...)

```typescript
setTorch(options: TorchOptions) => Promise<{ enabled: boolean; }>
```

Toggle the device torch (flashlight) while the preview is running.

| Param         | Type                                                  |
| ------------- | ----------------------------------------------------- |
| **`options`** | <code><a href="#torchoptions">TorchOptions</a></code> |

**Returns:** <code>Promise&lt;{ enabled: boolean; }&gt;</code>

**Since:** 8.0.0

--------------------


### addListener('scanEvent', ...)

```typescript
addListener(eventName: 'scanEvent', listener: (event: ScanEvent) => void) => Promise<PluginListenerHandle>
```

Listen for live scan events emitted during the preview: tracking state,
mesh progress, capture warnings/errors and camera-health diagnostics.

| Param           | Type                                                                |
| --------------- | ------------------------------------------------------------------- |
| **`eventName`** | <code>'scanEvent'</code>                                            |
| **`listener`**  | <code>(event: <a href="#scanevent">ScanEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 8.0.0

--------------------


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Remove all listeners registered by this plugin.

**Since:** 8.0.0

--------------------


### Interfaces


#### SupportResult

| Prop               | Type                                               | Description                                                               | Since |
| ------------------ | -------------------------------------------------- | ------------------------------------------------------------------------- | ----- |
| **`isSupported`**  | <code>boolean</code>                               | Whether AR (world tracking) is supported at all on this device.           | 8.0.0 |
| **`hasLidar`**     | <code>boolean</code>                               | Whether the device has a LiDAR sensor (high-accuracy depth).              | 8.0.0 |
| **`hasDepthApi`**  | <code>boolean</code>                               | Whether a depth API is available without LiDAR (reserved for future use). | 8.0.0 |
| **`depthQuality`** | <code>'high' \| 'medium' \| 'low' \| 'none'</code> | Expected depth/measurement quality on this device.                        | 8.0.0 |


#### PreviewOptions

| Prop                | Type                 | Description                                                                                                                                                         | Default            | Since |
| ------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ----- |
| **`mode`**          | <code>'lidar'</code> | Preview mode. Currently only `'lidar'` (depth-aware world tracking) is supported; the plugin gracefully falls back to image-only on devices without a LiDAR sensor. |                    | 8.0.0 |
| **`forceLidarOff`** | <code>boolean</code> | Force LiDAR/scene-reconstruction off even on capable devices (image-only capture). Useful for debugging or to match Android behavior.                               | <code>false</code> | 8.0.0 |


#### ScanResult

| Prop                      | Type                                                    | Description                                                                                              | Since |
| ------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----- |
| **`hasLidar`**            | <code>boolean</code>                                    | Whether the measurement used LiDAR depth (`true`) or was image-only (`false`).                           | 8.0.0 |
| **`width`**               | <code>number</code>                                     | Object width in centimeters.                                                                             | 8.0.0 |
| **`height`**              | <code>number</code>                                     | Object height in centimeters.                                                                            | 8.0.0 |
| **`depth`**               | <code>number</code>                                     | Object depth in centimeters.                                                                             | 8.0.0 |
| **`volume`**              | <code>number</code>                                     | Object volume in cubic centimeters (oriented bounding box, W × H × D).                                   | 8.0.0 |
| **`depthQuality`**        | <code>'high' \| 'medium' \| 'low' \| 'estimated'</code> | Quality of the depth data used for this measurement.                                                     | 8.0.0 |
| **`pointCount`**          | <code>number</code>                                     | Number of depth points used in the measurement.                                                          | 8.0.0 |
| **`scanMode`**            | <code>'single' \| 'multi-angle'</code>                  | Whether this was a single capture or a multi-angle scan.                                                 | 8.0.0 |
| **`cameraAngle`**         | <code>number</code>                                     | Angle of the camera relative to the measured surface, in degrees.                                        | 8.0.0 |
| **`measureMethod`**       | <code>'lidar'</code>                                    | The measurement method used.                                                                             | 8.0.0 |
| **`capturedImageBase64`** | <code>string</code>                                     | High-resolution (1280px) JPEG, base64-encoded, intended for AI/ML analysis. Not persisted by the plugin. | 8.0.0 |
| **`thumbnailBase64`**     | <code>string</code>                                     | Thumbnail (1024px) JPEG, base64-encoded, intended for display/storage.                                   | 8.0.0 |


#### TorchOptions

| Prop          | Type                 | Description                                               | Since |
| ------------- | -------------------- | --------------------------------------------------------- | ----- |
| **`enabled`** | <code>boolean</code> | Whether the torch should be on (`true`) or off (`false`). | 8.0.0 |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### ScanEvent

| Prop                | Type                                                                                                         | Description                                                                                                                                                                                             | Since |
| ------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **`type`**          | <code>'error' \| 'tracking' \| 'meshProgress' \| 'meshReady' \| 'warning' \| 'processing' \| 'health'</code> | The kind of event being emitted.                                                                                                                                                                        | 8.0.0 |
| **`trackingState`** | <code>'normal' \| 'limited' \| 'notAvailable'</code>                                                         | For `type: 'tracking'`: the current AR tracking state.                                                                                                                                                  | 8.0.0 |
| **`limitedReason`** | <code>'initializing' \| 'excessiveMotion' \| 'insufficientFeatures' \| 'relocalizing'</code>                 | For `type: 'tracking'` with a limited state: why tracking is limited.                                                                                                                                   | 8.0.0 |
| **`meshCount`**     | <code>number</code>                                                                                          | For `type: 'meshProgress' \| 'meshReady'`: number of mesh anchors so far.                                                                                                                               | 8.0.0 |
| **`vertexCount`**   | <code>number</code>                                                                                          | For `type: 'meshProgress' \| 'meshReady'`: total reconstructed vertices.                                                                                                                                | 8.0.0 |
| **`isStable`**      | <code>boolean</code>                                                                                         | For `type: 'meshProgress'`: whether the mesh has stabilized.                                                                                                                                            | 8.0.0 |
| **`isReady`**       | <code>boolean</code>                                                                                         | For `type: 'meshProgress'`: whether enough mesh exists to capture.                                                                                                                                      | 8.0.0 |
| **`message`**       | <code>string</code>                                                                                          | For `type: 'warning' \| 'error'`: a human-readable message.                                                                                                                                             | 8.0.0 |
| **`code`**          | <code><a href="#captureissuecode">CaptureIssueCode</a></code>                                                | For `type: 'warning' \| 'error'`: a machine-readable issue code.                                                                                                                                        | 8.0.0 |
| **`angle`**         | <code>number</code>                                                                                          | For `type: 'warning'` (HOLD_LEVEL): the offending surface angle in degrees.                                                                                                                             | 8.0.0 |
| **`status`**        | <code>string</code>                                                                                          | For `type: 'processing'`: the capture phase. For `type: 'health'`: one of `'stalled' \| 'recovered' \| 'sessionFailed' \| 'interrupted' \| 'interruptionEnded' \| 'noSuperview' \| 'opaqueReasserted'`. | 8.0.0 |
| **`staleSeconds`**  | <code>number</code>                                                                                          | Health diagnostics: seconds since the last camera frame when a stall was detected.                                                                                                                      | 8.0.0 |
| **`attempt`**       | <code>number</code>                                                                                          | Health diagnostics: which self-heal attempt this is.                                                                                                                                                    | 8.0.0 |


### Type Aliases


#### CaptureIssueCode

Codes describing why a capture could not produce a measurement.

<code>'NO_SURFACE' | 'NOT_ENOUGH_DEPTH' | 'CANNOT_ISOLATE' | 'HOLD_LEVEL'</code>

</docgen-api>

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

[MIT](./LICENSE)
