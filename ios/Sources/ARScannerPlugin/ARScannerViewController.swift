import ARKit
import SceneKit
import UIKit

public class ARScannerViewController: UIViewController, ARSessionDelegate, ARSCNViewDelegate {

    public var forceLidarOff: Bool = false

    // Callbacks
    public var onScanComplete: (([String: Any]) -> Void)?
    public var onScanCancelled: (() -> Void)?

    private var sceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var measureButton: UIButton!
    private var cancelButton: UIButton!

    private var hasLidar: Bool {
        !forceLidarOff && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // AR overlay elements
    private var crosshairView: CrosshairView!
    private var scanProgressView: ScanProgressView!
    private var lastRaycastTime: TimeInterval = 0
    private var currentHitPoint: SIMD3<Float>?
    private let highlightRadius: Float = 0.10

    // Mesh readiness tracking
    private var lastMeshAnchorCount: Int = 0
    private var lastTotalVertexCount: Int = 0
    private var meshStableStartTime: TimeInterval?
    private var isMeshReady: Bool = false
    private let minimumMeshAnchors: Int = 2
    private let minimumVertexCount: Int = 300
    private var isProcessing: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .medium)

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

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupSceneView()
        setupUI()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startARSession()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func setupSceneView() {
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.delegate = self

        view.addSubview(sceneView)
    }

    private func setupUI() {
        // Cancel button
        cancelButton = UIButton(type: .system)
        let xmarkConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        cancelButton.setImage(UIImage(systemName: "xmark", withConfiguration: xmarkConfig), for: .normal)
        cancelButton.tintColor = .white
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cancelButton.layer.cornerRadius = 18
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Measure button
        measureButton = UIButton(type: .system)
        measureButton.setTitle("Measure", for: .normal)
        measureButton.setTitleColor(.white, for: .normal)
        measureButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        measureButton.backgroundColor = UIColor.systemBlue
        measureButton.layer.cornerRadius = 30
        measureButton.translatesAutoresizingMaskIntoConstraints = false
        measureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        if hasLidar {
            measureButton.isEnabled = false
            measureButton.backgroundColor = UIColor.systemGray
        }
        view.addSubview(measureButton)

        // Status label
        statusLabel = UILabel()
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        statusLabel.text = "  Hold above object  "

        // Crosshair
        crosshairView = CrosshairView()
        crosshairView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(crosshairView)

        // Scan progress bars
        scanProgressView = ScanProgressView()
        scanProgressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanProgressView)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cancelButton.widthAnchor.constraint(equalToConstant: 36),
            cancelButton.heightAnchor.constraint(equalToConstant: 36),

            measureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            measureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            measureButton.widthAnchor.constraint(equalToConstant: 200),
            measureButton.heightAnchor.constraint(equalToConstant: 60),

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),

            crosshairView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            crosshairView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            crosshairView.widthAnchor.constraint(equalToConstant: 60),
            crosshairView.heightAnchor.constraint(equalToConstant: 60),

            scanProgressView.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            scanProgressView.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            scanProgressView.widthAnchor.constraint(equalToConstant: 40),
            scanProgressView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]

        if hasLidar {
            configuration.sceneReconstruction = .mesh
            configuration.environmentTexturing = .automatic

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }

        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onScanCancelled?()
        }
    }

    @objc private func captureTapped() {
        guard !isProcessing else { return }
        guard let frame = sceneView.session.currentFrame else {
            statusLabel.text = "  No AR frame available  "
            return
        }

        if !hasLidar {
            processWithPlanes(frame: frame)
            return
        }

        captureAndMeasure(frame: frame)
    }

    // MARK: - Single-Angle Capture + Measurement

    private func captureAndMeasure(frame: ARFrame) {
        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        guard let query = sceneView.raycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any),
              let raycastResult = sceneView.session.raycast(query).first else {
            statusLabel.text = "  Could not detect surface  "
            return
        }

        let hitPoint = SIMD3<Float>(
            raycastResult.worldTransform.columns.3.x,
            raycastResult.worldTransform.columns.3.y,
            raycastResult.worldTransform.columns.3.z
        )

        isProcessing = true
        measureButton.isEnabled = false

        let worldVertices = extractDepthPoints(frame: frame, screenCenter: screenCenter)

        guard worldVertices.count > 50 else {
            statusLabel.text = "  Not enough depth data  "
            isProcessing = false
            measureButton.isEnabled = true
            measureButton.backgroundColor = UIColor.systemBlue
            return
        }

        haptic.impactOccurred()
        showCaptureFlash()
        statusLabel.text = "  Processing...  "

        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

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
                self.isProcessing = false

                guard let measurement = result else {
                    self.statusLabel.text = "  Could not isolate object  "
                    self.measureButton.isEnabled = true
                    self.measureButton.backgroundColor = UIColor.systemBlue
                    return
                }

                // v9: Viewing angle validation
                let maxAngle: Float = 10.0
                if measurement.surfaceAngle > maxAngle {
                    self.statusLabel.text = "  Hold phone more level (\(String(format: "%.0f", measurement.surfaceAngle))°)  "
                    self.measureButton.isEnabled = true
                    self.measureButton.backgroundColor = UIColor.systemBlue
                    return
                }

                let w = measurement.width
                let h = measurement.height
                let d = measurement.depth
                let vol = measurement.volume

                let scanResult: [String: Any] = [
                    "hasLidar": true,
                    "width": w,
                    "height": h,
                    "depth": d,
                    "volume": vol,
                    "depthQuality": "high",
                    "pointCount": measurement.pointCount,
                    "scanMode": "single",
                    "cameraAngle": measurement.surfaceAngle,
                    "measureMethod": "lidar"
                ]

                self.statusLabel.text = String(
                    format: "  W: %.1f × H: %.1f × D: %.1f cm  ", w, h, d
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.dismiss(animated: true) {
                        self?.onScanComplete?(scanResult)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func showCaptureFlash() {
        let flash = UIView(frame: view.bounds)
        flash.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.3)
        flash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(flash)

        UIView.animate(withDuration: 0.3, animations: {
            flash.alpha = 0
        }) { _ in
            flash.removeFromSuperview()
        }
    }

    // MARK: - Plane-based Processing (non-LiDAR)

    private func processWithPlanes(frame: ARFrame) {
        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }

        guard !planeAnchors.isEmpty else {
            statusLabel.text = "  Scanning... move around the object  "
            return
        }

        var minPoint = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var totalPoints = 0

        for anchor in planeAnchors {
            let center = (anchor.transform * SIMD4<Float>(anchor.center, 1.0)).xyz
            let extent = anchor.extent

            let halfWidth = extent.x / 2.0
            let halfDepth = extent.z / 2.0

            let corners = [
                center + SIMD3<Float>(-halfWidth, 0, -halfDepth),
                center + SIMD3<Float>(halfWidth, 0, -halfDepth),
                center + SIMD3<Float>(-halfWidth, 0, halfDepth),
                center + SIMD3<Float>(halfWidth, 0, halfDepth)
            ]

            for corner in corners {
                minPoint = min(minPoint, corner)
                maxPoint = max(maxPoint, corner)
            }
            totalPoints += 4
        }

        let size = maxPoint - minPoint
        let width = size.x * 100.0
        let height = size.y * 100.0
        let depth = size.z * 100.0

        let result: [String: Any] = [
            "hasLidar": false,
            "width": width,
            "height": max(height, 0.1),
            "depth": depth,
            "volume": width * max(height, 0.1) * depth,
            "depthQuality": "low",
            "pointCount": totalPoints
        ]

        dismiss(animated: true) { [weak self] in
            self?.onScanComplete?(result)
        }
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingState = frame.camera.trackingState
        guard !isProcessing else { return }

        switch trackingState {
        case .normal:
            if hasLidar {
                let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                let meshCount = meshAnchors.count
                let totalVertices = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }

                // Track mesh readiness: 1s warmup + enough data
                let now = frame.timestamp
                if meshStableStartTime == nil {
                    meshStableStartTime = now
                }

                lastMeshAnchorCount = meshCount
                lastTotalVertexCount = totalVertices

                let warmupElapsed = now - (meshStableStartTime ?? now)
                if warmupElapsed >= 1.0
                    && meshCount >= minimumMeshAnchors
                    && totalVertices >= minimumVertexCount {
                    isMeshReady = true
                }

                scanProgressView.updateProgress(
                    meshCount: meshCount,
                    vertexCount: totalVertices,
                    isStable: meshStableStartTime != nil
                        && (now - (meshStableStartTime ?? now)) > 0.5,
                    isReady: isMeshReady
                )

                if isMeshReady && !measureButton.isEnabled && !isProcessing {
                    measureButton.isEnabled = true
                    measureButton.backgroundColor = UIColor.systemBlue
                }

                if meshCount == 0 {
                    statusLabel.text = "  Move slowly around the object...  "
                } else if !isMeshReady {
                    statusLabel.text = "  Scanning... hold steady  "
                } else if currentHitPoint == nil {
                    statusLabel.text = "  Hold above object  "
                } else {
                    statusLabel.text = "  Tap Measure  "
                }
            } else {
                let planeCount = frame.anchors.compactMap({ $0 as? ARPlaneAnchor }).count
                statusLabel.text = "  Tracking OK — \(planeCount) plane(s) detected  "
            }
        case .limited(let reason):
            switch reason {
            case .initializing:
                statusLabel.text = "  Initializing scanner...  "
            case .excessiveMotion:
                statusLabel.text = "  Slow down  "
            case .insufficientFeatures:
                statusLabel.text = "  Not enough detail — try better lighting  "
            case .relocalizing:
                statusLabel.text = "  Relocalizing...  "
            @unknown default:
                statusLabel.text = "  Limited tracking  "
            }
        case .notAvailable:
            statusLabel.text = "  AR not available  "
        }
    }

    // MARK: - ARSCNViewDelegate

    public func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }

        let geometry = meshAnchor.geometry.toSCNGeometry()
        geometry.materials = [materialForAnchor(meshAnchor)]

        return SCNNode(geometry: geometry)
    }

    public func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }

        let geometry = meshAnchor.geometry.toSCNGeometry()
        geometry.materials = [materialForAnchor(meshAnchor)]
        node.geometry = geometry
    }

    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard time - lastRaycastTime > 0.1 else { return }
        lastRaycastTime = time

        var screenCenter = CGPoint.zero
        if Thread.isMainThread {
            screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        } else {
            DispatchQueue.main.sync {
                screenCenter = CGPoint(x: self.sceneView.bounds.midX, y: self.sceneView.bounds.midY)
            }
        }

        guard let query = sceneView.raycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any),
              let result = sceneView.session.raycast(query).first else {
            currentHitPoint = nil
            return
        }

        let newHitPoint = SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )

        if let old = currentHitPoint {
            currentHitPoint = 0.7 * old + 0.3 * newHitPoint
        } else {
            currentHitPoint = newHitPoint
        }
    }

    // MARK: - Mesh Highlighting

    private func materialForAnchor(_ meshAnchor: ARMeshAnchor) -> SCNMaterial {
        guard let hitPoint = currentHitPoint else { return wireframeMaterial }

        let anchorPos = SIMD3<Float>(
            meshAnchor.transform.columns.3.x,
            meshAnchor.transform.columns.3.y,
            meshAnchor.transform.columns.3.z
        )

        let dx = anchorPos.x - hitPoint.x
        let dz = anchorPos.z - hitPoint.z
        let distSq = dx * dx + dz * dz

        return distSq <= highlightRadius * highlightRadius ? highlightMaterial : wireframeMaterial
    }

    // MARK: - Depth-based Point Extraction

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

        let discontinuityThreshold: Float = 0.015  // 1.5cm
        let minConfidence: UInt8 = 1  // medium+high (v10: high-only was worse)

        let step = 2
        for y in stride(from: 0, to: depthHeight, by: step) {
            for x in stride(from: 0, to: depthWidth, by: step) {
                let idx = y * depthWidth + x
                let depth = depthPointer[idx]

                guard depth > 0.0 && depth < 3.0 else { continue }

                let conf = confPointer[idx]
                guard conf >= minConfidence else { continue }

                var isDiscontinuity = false
                let neighborOffsets = [
                    (-step, 0), (step, 0), (0, -step), (0, step),
                    (-step, -step), (step, -step), (-step, step), (step, step)
                ]
                for (dx, dy) in neighborOffsets {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0 && nx < depthWidth && ny >= 0 && ny < depthHeight else { continue }
                    let neighborDepth = depthPointer[ny * depthWidth + nx]
                    guard neighborDepth > 0.0 else { continue }
                    if abs(depth - neighborDepth) > discontinuityThreshold {
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

    // MARK: - Extension helper

    public override var prefersStatusBarHidden: Bool { true }
}
