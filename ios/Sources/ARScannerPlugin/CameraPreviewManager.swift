import ARKit
import AVFoundation
import SceneKit
import UIKit
import WebKit

/// Manages a native AR camera preview behind a transparent WebView (LiDAR mode).
class CameraPreviewManager: NSObject, ARSessionDelegate, ARSCNViewDelegate {

    /// Called for each scan event (tracking, meshProgress, meshReady, warning, processing, error)
    var onEvent: (([String: Any]) -> Void)?
    var forceLidarOff: Bool = false

    private(set) var isRunning = false
    private weak var webView: WKWebView?

    // Self-healing: ARKit gives no callback when frames silently stop (e.g. after a
    // long-idle cold start the camera stack can come up dead → white/black preview).
    // A watchdog detects stale frames and restarts the session/view.
    private var arConfig: ARWorldTrackingConfiguration?
    private var lastFrameTime: CFTimeInterval = 0
    private var watchdogTimer: Timer?
    private var consecutiveRestarts = 0
    private var hadStallRestart = false
    private var foregroundObserver: NSObjectProtocol?
    // Capacitor restores webView.isOpaque to its saved value (true) in didFinish
    // (WebViewDelegationHandler), which on a slow cold start lands AFTER our one-shot
    // applyTransparency() and leaves a white webview over a live AR session. KVO
    // re-asserts transparency the instant anything flips it opaque again.
    private var opacityObservation: NSKeyValueObservation?
    private let frameStaleThreshold: CFTimeInterval = 3.0
    private let maxRestartAttempts = 4

    // LiDAR / AR
    private var sceneView: ARSCNView?
    private var currentHitPoint: SIMD3<Float>?
    private var lastRaycastTime: TimeInterval = 0
    private var meshStableStartTime: TimeInterval?
    private(set) var isMeshReady = false
    private var lastMeshAnchorCount = 0
    private var lastTotalVertexCount = 0
    private var isProcessing = false
    private let minimumMeshAnchors = 1
    private let minimumVertexCount = 50
    private let highlightRadius: Float = 0.10
    private var lastMeshEventTime: TimeInterval = 0
    private var lastTrackingEventTime: TimeInterval = 0
    private var lastTrackingState: String = ""

    // Materials for wireframe mesh
    private lazy var wireframeMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.5)
        m.emission.contents = UIColor.white.withAlphaComponent(0.3)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    private lazy var highlightMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.8)
        m.emission.contents = UIColor.white.withAlphaComponent(0.5)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    // MARK: - Public API

    func start(webView: WKWebView) {
        guard !isRunning else { return }
        self.webView = webView

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.applyTransparency()
            self.startARPreview(webView: webView)
            self.isRunning = true
            self.startWatchdog()
            self.observeForeground()
            self.observeOpacity()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.watchdogTimer?.invalidate()
            self.watchdogTimer = nil
            if let observer = self.foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                self.foregroundObserver = nil
            }
            // Invalidate before the opaque write below so the KVO callback (also
            // gated on isRunning, already false) never fights the teardown.
            self.opacityObservation?.invalidate()
            self.opacityObservation = nil

            // AR cleanup
            self.sceneView?.session.pause()
            self.sceneView?.removeFromSuperview()
            self.sceneView = nil

            // Restore WebView — use black to avoid white flash on restart
            if let wv = self.webView {
                wv.isOpaque = true
                wv.backgroundColor = .black
                wv.scrollView.backgroundColor = .black
                wv.superview?.backgroundColor = .black
                wv.superview?.superview?.backgroundColor = .black
            }

            // Reset state
            self.isMeshReady = false
            self.meshStableStartTime = nil
            self.currentHitPoint = nil
            self.isProcessing = false
        }
    }

    func setTorch(enabled: Bool) -> Bool {
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           device.hasTorch {
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                return enabled
            } catch {
                return false
            }
        }
        return false
    }

    func capture(completion: @escaping ([String: Any]?) -> Void) {
        guard isRunning, !isProcessing else {
            completion(nil)
            return
        }

        isProcessing = true
        emitEvent(type: "processing", data: ["status": "capturing"])

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            self.captureLiDAR(completion: completion)
        }
    }

    // MARK: - AR Preview

    private func startARPreview(webView: WKWebView) {
        guard let superview = webView.superview else {
            emitEvent(type: "health", data: ["status": "noSuperview"])
            return
        }

        let arView = ARSCNView(frame: webView.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Black, not the default white: if the session ever stops delivering frames
        // the user sees a dark camera view instead of an unexplained white screen.
        arView.backgroundColor = .black
        arView.session.delegate = self
        arView.delegate = self
        arView.automaticallyUpdatesLighting = true

        superview.insertSubview(arView, belowSubview: webView)
        sceneView = arView

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]

        if !forceLidarOff && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            config.environmentTexturing = .automatic

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
        }

        arConfig = config
        lastFrameTime = CACurrentMediaTime()
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Self-healing (transparency + frame watchdog)

    private func applyTransparency() {
        guard let webView = webView else { return }
        // Make WebView and all parent views transparent so camera shows through
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.superview?.backgroundColor = .clear
        webView.superview?.superview?.backgroundColor = .clear
    }

    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            // The WebView/superview backgrounds can be reset while backgrounded
            self.applyTransparency()
            // Grace period so the watchdog doesn't restart a session that is
            // still resuming from the interruption
            self.lastFrameTime = CACurrentMediaTime()
        }
    }

    private func observeOpacity() {
        guard let webView = webView, opacityObservation == nil else { return }
        // Mode B fix: Capacitor's WebViewDelegationHandler.didFinish restores
        // isOpaque to its pre-load value (true). On a slow cold start that runs
        // after our one-shot applyTransparency() and hides the live camera behind
        // a white webview, with no frame stall for the watchdog to catch. Re-assert
        // the moment isOpaque flips back to true.
        opacityObservation = webView.observe(\.isOpaque, options: [.new]) { [weak self] _, change in
            guard let self = self, self.isRunning, change.newValue == true else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.applyTransparency()
                self.emitEvent(type: "health", data: ["status": "opaqueReasserted"])
            }
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        guard isRunning else { return }
        // Mode B backstop: re-assert transparency every tick regardless of frame
        // health. Idempotent and cheap; covers any opaque flip the KVO might miss.
        applyTransparency()
        let stale = CACurrentMediaTime() - lastFrameTime
        guard stale > frameStaleThreshold else { return }
        guard consecutiveRestarts < maxRestartAttempts else { return }

        consecutiveRestarts += 1
        hadStallRestart = true
        emitEvent(type: "health", data: [
            "status": "stalled",
            "staleSeconds": stale,
            "attempt": consecutiveRestarts
        ])

        applyTransparency()
        if consecutiveRestarts >= 3 {
            // Re-running the session twice didn't help — rebuild the whole view
            recreatePreview()
        } else {
            restartSession()
        }
        lastFrameTime = CACurrentMediaTime()
    }

    private func restartSession() {
        guard let config = arConfig, let arView = sceneView else { return }
        resetMeshState()
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func recreatePreview() {
        guard let webView = webView else { return }
        sceneView?.session.pause()
        sceneView?.removeFromSuperview()
        sceneView = nil
        resetMeshState()
        startARPreview(webView: webView)
    }

    private func resetMeshState() {
        isMeshReady = false
        meshStableStartTime = nil
        currentHitPoint = nil
        lastMeshAnchorCount = 0
        lastTotalVertexCount = 0
        lastMeshEventTime = 0
        lastTrackingState = ""
    }

    // MARK: - LiDAR Capture

    private func resizeImage(_ uiImage: UIImage, maxDimension: CGFloat, quality: CGFloat) -> String? {
        let scale = min(maxDimension / uiImage.size.width, maxDimension / uiImage.size.height, 1.0)
        let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        uiImage.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resized?.jpegData(compressionQuality: quality)?.base64EncodedString()
    }

    /// Returns (highRes 1536px for AI, thumbnail 512px for storage)
    private func captureFrameDualBase64(frame: ARFrame) -> (highRes: String?, thumbnail: String?) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return (nil, nil) }
        // ARKit camera buffer is always in landscape-right (native sensor orientation).
        // Apply .right so the image displays correctly in portrait mode.
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        let highRes = resizeImage(uiImage, maxDimension: 1536, quality: 0.85)
        let thumbnail = resizeImage(uiImage, maxDimension: 1024, quality: 0.8)
        return (highRes, thumbnail)
    }

    private func captureLiDAR(completion: @escaping ([String: Any]?) -> Void) {
        guard let sceneView = sceneView,
              let frame = sceneView.session.currentFrame else {
            isProcessing = false
            completion(nil)
            return
        }

        let dualImages = captureFrameDualBase64(frame: frame)

        let hasLidar = !forceLidarOff && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

        if !hasLidar {
            // Match Android behavior: image-only, no sensor measurements. Gemini analyzes the photo without misleading plane-derived dimensions.
            var result: [String: Any] = [
                "hasLidar": false,
                "width": 0,
                "height": 0,
                "depth": 0,
                "volume": 0,
                "depthQuality": "estimated",
                "pointCount": 0,
                "measureMethod": "lidar"
            ]
            if let b64 = dualImages.highRes { result["capturedImageBase64"] = b64 }
            if let thumb = dualImages.thumbnail { result["thumbnailBase64"] = thumb }
            isProcessing = false
            completion(result)
            return
        }

        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        guard let query = sceneView.raycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any),
              let raycastResult = sceneView.session.raycast(query).first else {
            isProcessing = false
            emitEvent(type: "error", data: [
                "code": "NO_SURFACE",
                "message": "Could not detect surface"
            ])
            completion(nil)
            return
        }

        let hitPoint = SIMD3<Float>(
            raycastResult.worldTransform.columns.3.x,
            raycastResult.worldTransform.columns.3.y,
            raycastResult.worldTransform.columns.3.z
        )

        let worldVertices = extractDepthPoints(frame: frame, screenCenter: screenCenter)

        guard worldVertices.count > 50 else {
            isProcessing = false
            emitEvent(type: "error", data: [
                "code": "NOT_ENOUGH_DEPTH",
                "message": "Not enough depth data"
            ])
            completion(nil)
            return
        }

        emitEvent(type: "processing", data: ["status": "measuring"])

        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mesh = UnifiedMesh(
                worldVertices: worldVertices,
                faces: [],
                faceAdjacency: [],
                vertexToFaces: []
            )

            let result = MeshProcessor.measureObjectFromMesh(
                mesh: mesh,
                hitPoint: hitPoint,
                planeAnchors: planeAnchors
            )

            DispatchQueue.main.async {
                self?.isProcessing = false

                guard let measurement = result else {
                    self?.emitEvent(type: "error", data: [
                        "code": "CANNOT_ISOLATE",
                        "message": "Could not isolate object"
                    ])
                    completion(nil)
                    return
                }

                let maxAngle: Float = 12.0
                if measurement.surfaceAngle > maxAngle {
                    self?.emitEvent(type: "warning", data: [
                        "code": "HOLD_LEVEL",
                        "message": "Hold phone more level",
                        "angle": measurement.surfaceAngle
                    ])
                    completion(nil)
                    return
                }

                var resultDict: [String: Any] = [
                    "hasLidar": true,
                    "width": measurement.width,
                    "height": measurement.height,
                    "depth": measurement.depth,
                    "volume": measurement.volume,
                    "depthQuality": "high",
                    "pointCount": measurement.pointCount,
                    "scanMode": "single",
                    "cameraAngle": measurement.surfaceAngle,
                    "measureMethod": "lidar"
                ]
                if let b64 = dualImages.highRes { resultDict["capturedImageBase64"] = b64 }
                if let thumb = dualImages.thumbnail { resultDict["thumbnailBase64"] = thumb }
                completion(resultDict)
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastFrameTime = CACurrentMediaTime()
        if hadStallRestart {
            hadStallRestart = false
            consecutiveRestarts = 0
            emitEvent(type: "health", data: ["status": "recovered"])
        }

        guard !isProcessing else { return }

        switch frame.camera.trackingState {
        case .normal:
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            let meshCount = meshAnchors.count
            let totalVertices = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }

            let now = frame.timestamp
            if meshStableStartTime == nil { meshStableStartTime = now }

            let warmup = now - (meshStableStartTime ?? now)
            let wasReady = isMeshReady
            if meshCount >= minimumMeshAnchors && totalVertices >= minimumVertexCount {
                isMeshReady = true
            }

            // Emit meshReady once
            if isMeshReady && !wasReady {
                emitEvent(type: "meshReady", data: [
                    "meshCount": meshCount,
                    "vertexCount": totalVertices
                ])
            }

            // Throttle meshProgress — only emit every 2s when data changes
            let meshChanged = meshCount != lastMeshAnchorCount || totalVertices != lastTotalVertexCount
            if now - lastMeshEventTime > 2.0 && meshChanged {
                lastMeshEventTime = now
                lastMeshAnchorCount = meshCount
                lastTotalVertexCount = totalVertices
                emitEvent(type: "meshProgress", data: [
                    "meshCount": meshCount,
                    "vertexCount": totalVertices,
                    "isStable": warmup > 0.5,
                    "isReady": isMeshReady
                ])
            }

        case .limited(let reason):
            let reasonStr: String
            switch reason {
            case .initializing: reasonStr = "initializing"
            case .excessiveMotion: reasonStr = "excessiveMotion"
            case .insufficientFeatures: reasonStr = "insufficientFeatures"
            case .relocalizing: reasonStr = "relocalizing"
            @unknown default: reasonStr = "unknown"
            }
            let stateKey = "limited:\(reasonStr)"
            // Only emit when state actually changes
            if stateKey != lastTrackingState {
                lastTrackingState = stateKey
                emitEvent(type: "tracking", data: [
                    "trackingState": "limited",
                    "limitedReason": reasonStr
                ])
            }

        case .notAvailable:
            if lastTrackingState != "notAvailable" {
                lastTrackingState = "notAvailable"
                emitEvent(type: "tracking", data: ["trackingState": "notAvailable"])
            }
        }
    }

    // MARK: - ARSessionObserver (interruptions & failures)

    func session(_ session: ARSession, didFailWithError error: Error) {
        emitEvent(type: "health", data: [
            "status": "sessionFailed",
            "message": error.localizedDescription
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.applyTransparency()
            self.recreatePreview()
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        emitEvent(type: "health", data: ["status": "interrupted"])
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        emitEvent(type: "health", data: ["status": "interruptionEnded"])
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            // Relocalizing against the stale world map can leave tracking stuck —
            // start clean instead
            self.applyTransparency()
            self.restartSession()
            self.lastFrameTime = CACurrentMediaTime()
        }
    }

    // MARK: - ARSCNViewDelegate (wireframe mesh)

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        let geometry = meshAnchor.geometry.toSCNGeometry()
        geometry.materials = [materialForAnchor(meshAnchor)]
        return SCNNode(geometry: geometry)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        let geometry = meshAnchor.geometry.toSCNGeometry()
        geometry.materials = [materialForAnchor(meshAnchor)]
        node.geometry = geometry
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard time - lastRaycastTime > 0.1, let sceneView = sceneView else { return }
        lastRaycastTime = time

        var screenCenter = CGPoint.zero
        if Thread.isMainThread {
            screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        } else {
            DispatchQueue.main.sync {
                screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
            }
        }

        guard let query = sceneView.raycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any),
              let result = sceneView.session.raycast(query).first else {
            currentHitPoint = nil
            return
        }

        let newHit = SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )

        if let old = currentHitPoint {
            currentHitPoint = 0.7 * old + 0.3 * newHit
        } else {
            currentHitPoint = newHit
        }
    }

    // MARK: - Helpers

    private func materialForAnchor(_ meshAnchor: ARMeshAnchor) -> SCNMaterial {
        guard let hit = currentHitPoint else { return wireframeMaterial }
        let pos = SIMD3<Float>(
            meshAnchor.transform.columns.3.x,
            meshAnchor.transform.columns.3.y,
            meshAnchor.transform.columns.3.z
        )
        let dx = pos.x - hit.x, dz = pos.z - hit.z
        return (dx * dx + dz * dz) <= highlightRadius * highlightRadius
            ? highlightMaterial : wireframeMaterial
    }

    private func emitEvent(type: String, data: [String: Any]) {
        var event = data
        event["type"] = type
        onEvent?(event)
    }

    // MARK: - Plane-based fallback (non-LiDAR)

    private func processWithPlanes(frame: ARFrame) -> [String: Any]? {
        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planeAnchors.isEmpty else { return nil }

        var minP = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var totalPoints = 0

        for anchor in planeAnchors {
            let center = (anchor.transform * SIMD4<Float>(anchor.center, 1.0)).xyz
            let ext = anchor.extent
            let hw = ext.x / 2, hd = ext.z / 2
            let corners = [
                center + SIMD3<Float>(-hw, 0, -hd),
                center + SIMD3<Float>(hw, 0, -hd),
                center + SIMD3<Float>(-hw, 0, hd),
                center + SIMD3<Float>(hw, 0, hd)
            ]
            for c in corners { minP = min(minP, c); maxP = max(maxP, c) }
            totalPoints += 4
        }

        let s = maxP - minP
        let w = s.x * 100, h = s.y * 100, d = s.z * 100
        return [
            "hasLidar": false,
            "width": w, "height": max(h, 0.1), "depth": d,
            "volume": w * max(h, 0.1) * d,
            "depthQuality": "low",
            "pointCount": totalPoints
        ]
    }

    // MARK: - Depth Point Extraction (LiDAR)

    private func extractDepthPoints(frame: ARFrame, screenCenter: CGPoint) -> [SIMD3<Float>] {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return []
        }

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imageRes = camera.imageResolution
        let cameraTransform = camera.transform

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap!, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap!, .readOnly)
        }

        let depthPointer = CVPixelBufferGetBaseAddress(depthMap)!
            .assumingMemoryBound(to: Float32.self)
        let confPointer = CVPixelBufferGetBaseAddress(confidenceMap!)!
            .assumingMemoryBound(to: UInt8.self)

        let scaleX = Float(depthWidth) / Float(imageRes.width)
        let scaleY = Float(depthHeight) / Float(imageRes.height)

        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY

        var worldPoints: [SIMD3<Float>] = []
        worldPoints.reserveCapacity(depthWidth * depthHeight / 4)

        let discontinuityThreshold: Float = 0.015
        let minConfidence: UInt8 = 1

        let step = 2
        for y in stride(from: 0, to: depthHeight, by: step) {
            for x in stride(from: 0, to: depthWidth, by: step) {
                let idx = y * depthWidth + x
                let depth = depthPointer[idx]

                guard depth > 0.0 && depth < 3.0 else { continue }
                guard confPointer[idx] >= minConfidence else { continue }

                // Flying pixel removal
                var isDiscontinuity = false
                let neighborOffsets = [
                    (-step, 0), (step, 0), (0, -step), (0, step),
                    (-step, -step), (step, -step), (-step, step), (step, step)
                ]
                for (dx, dy) in neighborOffsets {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0 && nx < depthWidth && ny >= 0 && ny < depthHeight else { continue }
                    let nd = depthPointer[ny * depthWidth + nx]
                    guard nd > 0.0 else { continue }
                    if abs(depth - nd) > discontinuityThreshold {
                        isDiscontinuity = true
                        break
                    }
                }
                if isDiscontinuity { continue }

                let localX = (Float(x) - cx) * depth / fx
                let localY = (Float(y) - cy) * depth / fy
                let localZ = -depth

                let cameraPoint = SIMD4<Float>(localX, localY, localZ, 1.0)
                let worldPoint = (cameraTransform * cameraPoint).xyz
                worldPoints.append(worldPoint)
            }
        }

        return worldPoints
    }
}
