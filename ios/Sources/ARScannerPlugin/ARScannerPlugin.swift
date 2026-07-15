import AVFoundation
import Capacitor
import UIKit

@objc(ARScannerPlugin)
public class ARScannerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ARScannerPlugin"
    public let jsName = "ARScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkSupport", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "capture", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTorch", returnType: CAPPluginReturnPromise),
    ]

    private let implementation = ARScanner()
    private var previewManager: CameraPreviewManager?

    // MARK: - checkSupport

    @objc public func checkSupport(_ call: CAPPluginCall) {
        let hasLidar = implementation.isLidarAvailable()
        let isSupported = implementation.isARSupported()

        let depthQuality: String
        if hasLidar {
            depthQuality = "high"
        } else if isSupported {
            depthQuality = "low"
        } else {
            depthQuality = "none"
        }

        call.resolve([
            "isSupported": isSupported,
            "hasLidar": hasLidar,
            "hasDepthApi": false,
            "depthQuality": depthQuality
        ])
    }

    // MARK: - startPreview (camera behind WebView)

    @objc public func startPreview(_ call: CAPPluginCall) {
        // Gate on camera permission BEFORE running the AR session
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            doStartPreview(call)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.doStartPreview(call)
                } else {
                    call.reject("Camera permission denied")
                }
            }
        default: // .denied, .restricted
            call.reject("Camera permission denied")
        }
    }

    private func doStartPreview(_ call: CAPPluginCall) {
        let forceLidarOff = call.getBool("forceLidarOff") ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let webView = self.webView else {
                call.reject("WebView not available")
                return
            }

            // Stop existing preview if any
            self.previewManager?.stop()

            let manager = CameraPreviewManager()
            manager.forceLidarOff = forceLidarOff
            manager.onEvent = { [weak self] event in
                self?.notifyListeners("scanEvent", data: event)
            }

            manager.start(webView: webView)
            self.previewManager = manager

            call.resolve(["started": true])
        }
    }

    // MARK: - stopPreview

    @objc public func stopPreview(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.previewManager?.stop()
            self?.previewManager = nil
            call.resolve(["stopped": true])
        }
    }

    // MARK: - capture (measure from live preview)

    @objc public func capture(_ call: CAPPluginCall) {
        guard let manager = previewManager, manager.isRunning else {
            call.reject("Preview is not running. Call startPreview() first.")
            return
        }

        manager.capture { result in
            if let result = result {
                call.resolve(result)
            } else {
                call.reject("Capture failed — try again")
            }
        }
    }

    // MARK: - setTorch

    @objc public func setTorch(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? false

        DispatchQueue.main.async { [weak self] in
            guard let manager = self?.previewManager, manager.isRunning else {
                call.reject("Preview is not running")
                return
            }
            let result = manager.setTorch(enabled: enabled)
            call.resolve(["enabled": result])
        }
    }
}
