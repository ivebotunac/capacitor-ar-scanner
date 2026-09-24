import ARKit
import Vision

/// Reads retail barcodes (EAN-13, EAN-8, UPC-E) on the device, for `capture({ detectBarcodes: true })`.
enum BarcodeReader {
    private static let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce]

    /// Barcodes in the photo's own frame first, since the phone may move after the tap; then a high-resolution still on iOS 16+.
    static func read(photoFrame: CVPixelBuffer?, session: ARSession, completion: @escaping ([[String: Any]]) -> Void) {
        func detectFirst(_ buffers: [CVPixelBuffer]) {
            DispatchQueue.global(qos: .userInitiated).async {
                var found: [[String: Any]] = []
                for buffer in buffers {
                    found = detect(in: buffer)
                    if !found.isEmpty { break }
                }
                DispatchQueue.main.async { completion(found) }
            }
        }

        if #available(iOS 16.0, *) {
            session.captureHighResolutionFrame { frame, _ in
                detectFirst([photoFrame, frame?.capturedImage].compactMap { $0 })
            }
        } else {
            detectFirst([photoFrame].compactMap { $0 })
        }
    }

    private static func detect(in buffer: CVPixelBuffer) -> [[String: Any]] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        // ARKit buffers are in landscape-right sensor orientation; .right puts the boxes in the upright photo.
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let value = observation.payloadStringValue, let format = name(of: observation.symbology) else { return nil }
            let box = observation.boundingBox
            // Vision's origin is bottom-left; the result's is top-left, as in the photo.
            return [
                "value": value,
                "format": format,
                "box": ["left": box.minX, "top": 1 - box.maxY, "right": box.maxX, "bottom": 1 - box.minY]
            ]
        }
    }

    private static func name(of symbology: VNBarcodeSymbology) -> String? {
        switch symbology {
        case .ean13: return "EAN13"
        case .ean8: return "EAN8"
        case .upce: return "UPCE"
        default: return nil
        }
    }
}
