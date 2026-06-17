import ARKit
import SceneKit

extension ARMeshGeometry {
    /// Convert ARMeshGeometry to SCNGeometry using zero-copy from Metal buffers.
    func toSCNGeometry() -> SCNGeometry {
        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        // Read face indices into Data for SCNGeometryElement
        let faceBytes = faces.buffer.contents()
        let faceCount = faces.count
        let indexCountPerFace = faces.indexCountPerPrimitive
        let bytesPerIndex = MemoryLayout<UInt32>.size
        let totalBytes = faceCount * indexCountPerFace * bytesPerIndex
        let indexData = Data(bytes: faceBytes, count: totalBytes)

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faceCount,
            bytesPerIndex: bytesPerIndex
        )

        return SCNGeometry(sources: [vertexSource], elements: [element])
    }
}
