import ARKit
import Foundation

public class ARScanner {

    public func isLidarAvailable() -> Bool {
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    public func isARSupported() -> Bool {
        return ARWorldTrackingConfiguration.isSupported
    }
}
