import ARKit
import SceneKit

// MARK: - SIMD4 Extension

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        return SIMD3(x, y, z)
    }
}

// MARK: - Measurement Result

public struct MeasurementResult {
    public let width: Float         // cm — longest horizontal extent
    public let height: Float        // cm — vertical extent (along surface normal)
    public let depth: Float         // cm — shorter horizontal extent
    public let volume: Float        // cm³ — from OBB (W × H × D)
    public let pointCount: Int
    public let obbCenter: SIMD3<Float>
    public let obbAxes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    public let obbExtents: SIMD3<Float>  // half-extents in meters
    public let confidence: Float    // 0-1
    public let objectVertices: [SIMD3<Float>]  // isolated object points for visualization
    public let surfaceAngle: Float  // degrees from vertical (0 = perfect top-down, >10 = suspect)
}

// MARK: - Unified Mesh

/// A single mesh representation built from all ARMeshAnchors, with merged vertices
/// and face adjacency computed across anchor boundaries.
public struct UnifiedMesh {
    public var worldVertices: [SIMD3<Float>]
    public var faces: [(Int, Int, Int)]           // triangle indices into worldVertices
    public var faceAdjacency: [[Int]]             // faceAdjacency[i] = neighbour face indices
    public var vertexToFaces: [[Int]]             // vertexToFaces[i] = face indices using vertex i
}

// MARK: - MeshProcessor

public class MeshProcessor {

    // MARK: - Low-level Vertex/Face Access

    static func vertex(at index: UInt32, in geo: ARMeshGeometry) -> SIMD3<Float> {
        let ptr = geo.vertices.buffer.contents()
            .advanced(by: geo.vertices.offset + Int(index) * geo.vertices.stride)
        return ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    static func faceIndices(at faceIndex: Int, in geo: ARMeshGeometry) -> (UInt32, UInt32, UInt32) {
        let ptr = geo.faces.buffer.contents()
            .advanced(by: geo.faces.indexCountPerPrimitive * faceIndex * MemoryLayout<UInt32>.size)
        let ip = ptr.assumingMemoryBound(to: UInt32.self)
        return (ip[0], ip[1], ip[2])
    }

    // MARK: - Build Unified Mesh

    /// Pre-filter ARMeshAnchors to only those whose actual mesh data is near the hit point.
    /// Checks if ANY vertex of the anchor is within radius of hitPoint (XZ distance).
    /// Samples every 10th vertex for speed.
    static func filterNearbyAnchors(
        _ meshAnchors: [ARMeshAnchor],
        near hitPoint: SIMD3<Float>,
        radius: Float = 0.6
    ) -> [ARMeshAnchor] {
        let rSq = radius * radius
        return meshAnchors.filter { anchor in
            let geo = anchor.geometry
            let count = geo.vertices.count
            let step = max(1, count / 50)  // Sample ~50 vertices per anchor for speed
            for i in stride(from: 0, to: count, by: step) {
                let local = vertex(at: UInt32(i), in: geo)
                let world = (anchor.transform * SIMD4<Float>(local, 1.0)).xyz
                let dx = world.x - hitPoint.x
                let dz = world.z - hitPoint.z
                if dx * dx + dz * dz <= rSq {
                    return true
                }
            }
            return false
        }
    }

    /// Merges nearby ARMeshAnchors into one mesh with shared vertices across anchor boundaries.
    /// Uses spatial hashing (3mm grid) to merge nearby vertices from different anchors.
    /// LiDAR mesh vertex spacing is ~1cm, so 3mm provides good dedup without over-merging.
    static func buildUnifiedMesh(from meshAnchors: [ARMeshAnchor]) -> UnifiedMesh {
        var worldVertices: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []

        // Spatial hash for vertex merging — quantise to 3mm grid
        // (LiDAR mesh is ~1cm between vertices; 3mm gives good dedup without over-merging)
        let quantScale: Float = 333.0  // 1/0.003
        var spatialMap: [SIMD3<Int32>: Int] = [:]

        func mergedIndex(for worldPos: SIMD3<Float>) -> Int {
            let key = SIMD3<Int32>(
                Int32(round(worldPos.x * quantScale)),
                Int32(round(worldPos.y * quantScale)),
                Int32(round(worldPos.z * quantScale))
            )
            if let existing = spatialMap[key] {
                return existing
            }
            let idx = worldVertices.count
            worldVertices.append(worldPos)
            spatialMap[key] = idx
            return idx
        }

        for anchor in meshAnchors {
            let geo = anchor.geometry
            let vertexCount = geo.vertices.count
            let faceCount = geo.faces.count

            // Map local vertex indices to unified indices
            var localToUnified = [Int](repeating: 0, count: vertexCount)
            for i in 0..<vertexCount {
                let local = vertex(at: UInt32(i), in: geo)
                let world = (anchor.transform * SIMD4<Float>(local, 1.0)).xyz
                localToUnified[i] = mergedIndex(for: world)
            }

            for f in 0..<faceCount {
                let (i0, i1, i2) = faceIndices(at: f, in: geo)
                let a = localToUnified[Int(i0)]
                let b = localToUnified[Int(i1)]
                let c = localToUnified[Int(i2)]
                // Skip degenerate faces (all 3 vertices merged to same point)
                guard a != b && b != c && a != c else { continue }
                faces.append((a, b, c))
            }
        }

        // Build vertex-to-face mapping
        var vertexToFaces = [[Int]](repeating: [], count: worldVertices.count)
        for (fi, face) in faces.enumerated() {
            vertexToFaces[face.0].append(fi)
            vertexToFaces[face.1].append(fi)
            vertexToFaces[face.2].append(fi)
        }

        // Build face adjacency via shared edges
        // Two faces sharing an edge (two vertices) are neighbours.
        // Use edge → face dictionary for efficiency.
        struct EdgeKey: Hashable {
            let a: Int, b: Int
            init(_ v0: Int, _ v1: Int) {
                a = min(v0, v1)
                b = max(v0, v1)
            }
        }

        var edgeToFaces: [EdgeKey: [Int]] = [:]
        edgeToFaces.reserveCapacity(faces.count * 3)

        for (fi, face) in faces.enumerated() {
            let edges = [
                EdgeKey(face.0, face.1),
                EdgeKey(face.1, face.2),
                EdgeKey(face.0, face.2)
            ]
            for e in edges {
                edgeToFaces[e, default: []].append(fi)
            }
        }

        var faceAdjacency = [[Int]](repeating: [], count: faces.count)
        for (_, faceList) in edgeToFaces {
            if faceList.count == 2 {
                faceAdjacency[faceList[0]].append(faceList[1])
                faceAdjacency[faceList[1]].append(faceList[0])
            } else if faceList.count > 2 {
                // Non-manifold edge — connect all pairs
                for i in 0..<faceList.count {
                    for j in (i+1)..<faceList.count {
                        faceAdjacency[faceList[i]].append(faceList[j])
                        faceAdjacency[faceList[j]].append(faceList[i])
                    }
                }
            }
        }

        return UnifiedMesh(
            worldVertices: worldVertices,
            faces: faces,
            faceAdjacency: faceAdjacency,
            vertexToFaces: vertexToFaces
        )
    }

    // MARK: - RANSAC Plane Detection

    /// Fits a plane to the dominant surface near the hit point using RANSAC.
    /// Returns (normal, d) where the plane equation is dot(normal, point) + d = 0.
    /// The normal always points upward (positive dot with world Y).
    static func detectSurfacePlane(
        vertices: [SIMD3<Float>],
        near hitPoint: SIMD3<Float>,
        searchRadius: Float = 0.35,
        maxIterations: Int = 400,
        inlierThreshold: Float = 0.012
    ) -> (normal: SIMD3<Float>, d: Float)? {
        // Pre-filter: only vertices within searchRadius (XZ) of hitPoint
        let rSq = searchRadius * searchRadius
        let candidates = vertices.filter { v in
            let dx = v.x - hitPoint.x
            let dz = v.z - hitPoint.z
            return dx * dx + dz * dz <= rSq
        }
        guard candidates.count >= 20 else { return nil }

        var bestNormal = SIMD3<Float>(0, 1, 0)
        var bestD: Float = 0
        var bestInlierCount = 0

        // Adaptive RANSAC: 400 max iterations, early exit if >85% inliers
        let earlyExitRatio: Float = 0.85
        let earlyExitCount = Int(Float(candidates.count) * earlyExitRatio)

        for _ in 0..<maxIterations {
            // Sample 3 random vertices
            let i0 = Int.random(in: 0..<candidates.count)
            var i1 = Int.random(in: 0..<candidates.count)
            while i1 == i0 { i1 = Int.random(in: 0..<candidates.count) }
            var i2 = Int.random(in: 0..<candidates.count)
            while i2 == i0 || i2 == i1 { i2 = Int.random(in: 0..<candidates.count) }

            let p0 = candidates[i0]
            let p1 = candidates[i1]
            let p2 = candidates[i2]

            let edge1 = p1 - p0
            let edge2 = p2 - p0
            var normal = simd_cross(edge1, edge2)
            let len = simd_length(normal)
            guard len > 1e-6 else { continue }
            normal /= len

            // Ensure normal points upward
            if normal.y < 0 { normal = -normal }

            // Skip if plane is too vertical (we want the table surface, not a wall)
            guard normal.y > 0.7 else { continue }

            let d = -simd_dot(normal, p0)

            // Count inliers
            var inlierCount = 0
            for v in candidates {
                let dist = abs(simd_dot(normal, v) + d)
                if dist < inlierThreshold {
                    inlierCount += 1
                }
            }

            if inlierCount > bestInlierCount {
                bestInlierCount = inlierCount
                bestNormal = normal
                bestD = d

                // Early exit if plane is very strong
                if inlierCount >= earlyExitCount { break }
            }
        }

        // Need at least 20% of candidates as inliers for a valid plane
        guard bestInlierCount >= max(20, candidates.count / 5) else { return nil }

        // Refit plane from all inliers (least-squares)
        var inliers: [SIMD3<Float>] = []
        for v in candidates {
            let dist = abs(simd_dot(bestNormal, v) + bestD)
            if dist < inlierThreshold {
                inliers.append(v)
            }
        }

        if inliers.count >= 3 {
            let mean = inliers.reduce(SIMD3<Float>.zero, +) / Float(inliers.count)
            // Covariance matrix for plane refit
            var cov = simd_float3x3()
            for v in inliers {
                let c = v - mean
                cov.columns.0 += SIMD3<Float>(c.x * c.x, c.x * c.y, c.x * c.z)
                cov.columns.1 += SIMD3<Float>(c.y * c.x, c.y * c.y, c.y * c.z)
                cov.columns.2 += SIMD3<Float>(c.z * c.x, c.z * c.y, c.z * c.z)
            }
            // The plane normal is the eigenvector with smallest eigenvalue
            let (_, eigvecs) = symmetricEigen3x3(cov)
            var refinedNormal = eigvecs.2  // smallest eigenvalue
            if refinedNormal.y < 0 { refinedNormal = -refinedNormal }
            let refinedD = -simd_dot(refinedNormal, mean)
            return (normal: refinedNormal, d: refinedD)
        }

        return (normal: bestNormal, d: bestD)
    }

    /// Use ARPlaneAnchors as seed/fallback for surface detection.
    static func detectSurfaceFromPlaneAnchors(
        planeAnchors: [ARPlaneAnchor],
        near hitPoint: SIMD3<Float>,
        searchRadius: Float = 0.5
    ) -> (normal: SIMD3<Float>, d: Float)? {
        var bestAnchor: ARPlaneAnchor?
        var bestDist: Float = Float.greatestFiniteMagnitude

        for anchor in planeAnchors {
            guard anchor.alignment == .horizontal else { continue }
            let center = (anchor.transform * SIMD4<Float>(anchor.center, 1.0)).xyz
            let dx = center.x - hitPoint.x
            let dz = center.z - hitPoint.z
            let dist = sqrt(dx * dx + dz * dz)
            if dist < searchRadius && dist < bestDist {
                bestDist = dist
                bestAnchor = anchor
            }
        }

        guard let anchor = bestAnchor else { return nil }

        // The plane normal is the Y-axis of the anchor's transform
        let normal = SIMD3<Float>(
            anchor.transform.columns.1.x,
            anchor.transform.columns.1.y,
            anchor.transform.columns.1.z
        )
        let point = (anchor.transform * SIMD4<Float>(anchor.center, 1.0)).xyz
        let d = -simd_dot(normal, point)
        return (normal: normal.y >= 0 ? normal : -normal,
                d: normal.y >= 0 ? d : -d)
    }

    // MARK: - Flood-Fill Segmentation

    /// Starting from the face nearest to hitPoint that is above the surface,
    /// flood-fill through mesh connectivity. Stop at faces touching the surface plane.
    /// Uses centroid-based boundary check as a middle ground between strict (all vertices)
    /// and lenient (any vertex), preventing leakage while preserving curved surfaces.
    static func floodFillObject(
        in mesh: UnifiedMesh,
        hitPoint: SIMD3<Float>,
        surfacePlane: (normal: SIMD3<Float>, d: Float),
        surfaceThreshold: Float = 0.005,
        maxFaces: Int = 80000
    ) -> Set<Int> {

        // Helper: signed distance from vertex to surface plane
        func planeDistance(_ v: SIMD3<Float>) -> Float {
            return simd_dot(surfacePlane.normal, v) + surfacePlane.d
        }

        // Helper: is this face "above" the surface?
        // With coarse LiDAR mesh (~1cm vertex spacing), triangles often straddle
        // the object-surface boundary. Using centroid-only check to handle this.
        // A face is "above" if its centroid is above the surface threshold.
        func isFaceAboveSurface(_ fi: Int) -> Bool {
            let f = mesh.faces[fi]
            let d0 = planeDistance(mesh.worldVertices[f.0])
            let d1 = planeDistance(mesh.worldVertices[f.1])
            let d2 = planeDistance(mesh.worldVertices[f.2])
            let centroidDist = (d0 + d1 + d2) / 3.0
            return centroidDist > surfaceThreshold
        }

        // Find seed face: closest face centroid to hitPoint (XZ only) that is above surface.
        let seedSearchRadius: Float = 0.25
        let seedSearchRadiusSq = seedSearchRadius * seedSearchRadius
        var seedFace = -1
        var seedDist: Float = Float.greatestFiniteMagnitude

        for (fi, face) in mesh.faces.enumerated() {
            let centroid = (mesh.worldVertices[face.0]
                         + mesh.worldVertices[face.1]
                         + mesh.worldVertices[face.2]) / 3.0
            let dx = centroid.x - hitPoint.x
            let dz = centroid.z - hitPoint.z
            let distSq = dx * dx + dz * dz
            guard distSq <= seedSearchRadiusSq else { continue }

            guard isFaceAboveSurface(fi) else { continue }

            if distSq < seedDist {
                seedDist = distSq
                seedFace = fi
            }
        }

        guard seedFace >= 0 else {
            return []
        }

        // BFS flood-fill
        var visited = Set<Int>()
        visited.reserveCapacity(min(mesh.faces.count, maxFaces))
        var queue = [seedFace]
        visited.insert(seedFace)

        var head = 0
        while head < queue.count && visited.count < maxFaces {
            let current = queue[head]
            head += 1

            for neighbour in mesh.faceAdjacency[current] {
                guard !visited.contains(neighbour) else { continue }
                guard isFaceAboveSurface(neighbour) else { continue }
                visited.insert(neighbour)
                queue.append(neighbour)
            }
        }

        return visited
    }

    // MARK: - Collect Object Vertices

    /// Collect unique world-space vertices from the set of object faces.
    static func collectObjectVertices(mesh: UnifiedMesh, objectFaces: Set<Int>) -> [SIMD3<Float>] {
        var vertexSet = Set<Int>()
        for fi in objectFaces {
            let f = mesh.faces[fi]
            vertexSet.insert(f.0)
            vertexSet.insert(f.1)
            vertexSet.insert(f.2)
        }
        return vertexSet.map { mesh.worldVertices[$0] }
    }

    // MARK: - Statistical Outlier Removal (SOR)

    /// Remove vertices whose mean distance to k-nearest neighbours exceeds
    /// (globalMean + stdMultiplier * globalStdDev). Prevents outliers from inflating OBB.
    static func removeStatisticalOutliers(
        from vertices: [SIMD3<Float>],
        k: Int = 12,
        stdMultiplier: Float = 2.0
    ) -> [SIMD3<Float>] {
        guard vertices.count > k + 1 else { return vertices }

        // Compute mean distance to k-nearest neighbours for each vertex
        // Using brute-force for simplicity; with ~500 object vertices this is fast enough
        var meanDistances = [Float](repeating: 0, count: vertices.count)

        for i in 0..<vertices.count {
            // Compute distances to all other vertices
            var distances = [Float]()
            distances.reserveCapacity(vertices.count - 1)
            for j in 0..<vertices.count {
                guard i != j else { continue }
                distances.append(simd_distance(vertices[i], vertices[j]))
            }
            // Sort and take k nearest
            distances.sort()
            let kNearest = distances.prefix(k)
            meanDistances[i] = kNearest.reduce(0, +) / Float(k)
        }

        // Global statistics
        let globalMean = meanDistances.reduce(0, +) / Float(meanDistances.count)
        let variance = meanDistances.reduce(Float(0)) { acc, d in
            let diff = d - globalMean
            return acc + diff * diff
        } / Float(meanDistances.count)
        let globalStd = sqrt(variance)

        let threshold = globalMean + stdMultiplier * globalStd

        // Filter
        var result = [SIMD3<Float>]()
        result.reserveCapacity(vertices.count)
        for (i, v) in vertices.enumerated() {
            if meanDistances[i] <= threshold {
                result.append(v)
            }
        }

        // Don't remove too many — if >30% would be removed, skip SOR
        if result.count < vertices.count * 7 / 10 {
            return vertices
        }

        return result
    }

    // MARK: - PCA Oriented Bounding Box

    /// Compute an oriented bounding box from a set of vertices using PCA.
    /// The surface normal is used to align one axis with "height".
    /// Returns (center, axes, extents) where extents are half-sizes in meters,
    /// and axes are sorted so axis[0] aligns with surfaceNormal (height).
    static func computeOBB(
        from vertices: [SIMD3<Float>],
        surfaceNormal: SIMD3<Float>
    ) -> (center: SIMD3<Float>, axes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), extents: SIMD3<Float>)? {
        guard vertices.count >= 4 else { return nil }

        let n = Float(vertices.count)
        let mean = vertices.reduce(SIMD3<Float>.zero, +) / n

        // Covariance matrix
        var cov = simd_float3x3()
        for v in vertices {
            let c = v - mean
            cov.columns.0 += SIMD3<Float>(c.x * c.x, c.x * c.y, c.x * c.z)
            cov.columns.1 += SIMD3<Float>(c.y * c.x, c.y * c.y, c.y * c.z)
            cov.columns.2 += SIMD3<Float>(c.z * c.x, c.z * c.y, c.z * c.z)
        }
        cov.columns.0 /= n
        cov.columns.1 /= n
        cov.columns.2 /= n

        // Add small epsilon to diagonal for numerical stability with flat objects
        let epsilon: Float = 1e-8
        cov.columns.0.x += epsilon
        cov.columns.1.y += epsilon
        cov.columns.2.z += epsilon

        // Eigendecomposition
        let (_, eigvecs) = symmetricEigen3x3(cov)

        // eigvecs are sorted by eigenvalue descending: (largest, middle, smallest)
        // Assign axes: height = axis most aligned with surfaceNormal
        var axes = [eigvecs.0, eigvecs.1, eigvecs.2]

        // Find which eigenvector aligns most with the surface normal
        var bestHeightIdx = 0
        var bestAlignment: Float = 0
        for i in 0..<3 {
            let alignment = abs(simd_dot(axes[i], surfaceNormal))
            if alignment > bestAlignment {
                bestAlignment = alignment
                bestHeightIdx = i
            }
        }

        // Make sure the height axis points in the same direction as surfaceNormal
        if simd_dot(axes[bestHeightIdx], surfaceNormal) < 0 {
            axes[bestHeightIdx] = -axes[bestHeightIdx]
        }

        // Reorder: [height, wider, narrower]
        let heightAxis = axes[bestHeightIdx]
        var others = [SIMD3<Float>]()
        for i in 0..<3 {
            if i != bestHeightIdx { others.append(axes[i]) }
        }

        // Project vertices onto all 3 axes to get extents
        var minProj = SIMD3<Float>(Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude)
        var maxProj = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                                    -Float.greatestFiniteMagnitude,
                                    -Float.greatestFiniteMagnitude)

        let axisArray = [heightAxis, others[0], others[1]]
        for v in vertices {
            let c = v - mean
            let p = SIMD3<Float>(
                simd_dot(c, axisArray[0]),
                simd_dot(c, axisArray[1]),
                simd_dot(c, axisArray[2])
            )
            minProj = min(minProj, p)
            maxProj = max(maxProj, p)
        }

        let extents = (maxProj - minProj) / 2.0
        let centerOffset = (maxProj + minProj) / 2.0
        let center = mean + centerOffset.x * axisArray[0]
                          + centerOffset.y * axisArray[1]
                          + centerOffset.z * axisArray[2]

        // Sort so extents.x = height, extents.y = wider, extents.z = narrower
        let heightExtent = extents.x
        var widthExtent = extents.y
        var depthExtent = extents.z
        var widthAxis = others[0]
        var depthAxis = others[1]

        if depthExtent > widthExtent {
            swap(&widthExtent, &depthExtent)
            swap(&widthAxis, &depthAxis)
        }

        return (
            center: center,
            axes: (heightAxis, widthAxis, depthAxis),
            extents: SIMD3<Float>(heightExtent, widthExtent, depthExtent)
        )
    }

    // MARK: - Volume (signed tetrahedra on isolated faces)

    static func computeIsolatedMeshVolume(mesh: UnifiedMesh, objectFaces: Set<Int>) -> Float {
        var totalVolume: Float = 0.0
        for fi in objectFaces {
            let f = mesh.faces[fi]
            let v0 = mesh.worldVertices[f.0]
            let v1 = mesh.worldVertices[f.1]
            let v2 = mesh.worldVertices[f.2]
            totalVolume += simd_dot(v0, simd_cross(v1, v2)) / 6.0
        }
        return abs(totalVolume) * 1_000_000.0  // m³ → cm³
    }

    // MARK: - Object Mesh Isolation & Visualization

    /// Identify faces from an ARKit unified mesh that belong to the detected object.
    /// Uses OBB extents (inflated) + surface plane to select faces above the surface
    /// and within the object's bounding region.
    static func isolateObjectFaces(
        mesh: UnifiedMesh,
        measurement: MeasurementResult,
        surfacePlane: (normal: SIMD3<Float>, d: Float),
        margin: Float = 0.02  // 2cm inflation
    ) -> Set<Int> {
        guard !mesh.faces.isEmpty else { return [] }

        let center = measurement.obbCenter
        let axes = [measurement.obbAxes.0, measurement.obbAxes.1, measurement.obbAxes.2]
        let halfExtents = [
            measurement.obbExtents.x + margin,
            measurement.obbExtents.y + margin,
            measurement.obbExtents.z + margin
        ]
        let surfaceThreshold: Float = 0.003  // 3mm above surface

        var objectFaces = Set<Int>()

        for (fi, face) in mesh.faces.enumerated() {
            let v0 = mesh.worldVertices[face.0]
            let v1 = mesh.worldVertices[face.1]
            let v2 = mesh.worldVertices[face.2]
            let centroid = (v0 + v1 + v2) / 3.0

            // Check if centroid is above surface plane
            let planeDist = simd_dot(surfacePlane.normal, centroid) + surfacePlane.d
            guard planeDist > surfaceThreshold else { continue }

            // Check if centroid is within inflated OBB
            let offset = centroid - center
            var inside = true
            for i in 0..<3 {
                let proj = abs(simd_dot(offset, axes[i]))
                if proj > halfExtents[i] {
                    inside = false
                    break
                }
            }
            guard inside else { continue }

            objectFaces.insert(fi)
        }

        // If we have adjacency data, refine with flood fill from the largest connected component
        if !mesh.faceAdjacency.isEmpty && !objectFaces.isEmpty {
            // Find the face closest to OBB center as seed
            var seedFace = objectFaces.first!
            var seedDist = Float.greatestFiniteMagnitude
            for fi in objectFaces {
                let f = mesh.faces[fi]
                let centroid = (mesh.worldVertices[f.0] + mesh.worldVertices[f.1] + mesh.worldVertices[f.2]) / 3.0
                let d = simd_distance_squared(centroid, center)
                if d < seedDist {
                    seedDist = d
                    seedFace = fi
                }
            }

            // BFS flood fill within the already-filtered face set
            var visited = Set<Int>()
            var queue = [seedFace]
            visited.insert(seedFace)
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for neighbour in mesh.faceAdjacency[current] {
                    guard objectFaces.contains(neighbour) && !visited.contains(neighbour) else { continue }
                    visited.insert(neighbour)
                    queue.append(neighbour)
                }
            }
            // Use connected component only if it's a significant portion
            if visited.count > objectFaces.count / 3 {
                objectFaces = visited
            }
        }

        return objectFaces
    }

    /// Create an SCNGeometry from selected faces of a unified mesh.
    /// Material: semi-transparent teal fill for object highlight overlay.
    static func createObjectGeometry(
        mesh: UnifiedMesh,
        faceIndices: Set<Int>
    ) -> SCNGeometry? {
        guard !faceIndices.isEmpty else { return nil }

        // Collect unique vertices and remap indices
        var vertexMap = [Int: Int]()  // old index -> new index
        var newVertices = [SIMD3<Float>]()
        var newIndices = [UInt32]()

        for fi in faceIndices {
            let face = mesh.faces[fi]
            for oldIdx in [face.0, face.1, face.2] {
                if vertexMap[oldIdx] == nil {
                    vertexMap[oldIdx] = newVertices.count
                    newVertices.append(mesh.worldVertices[oldIdx])
                }
                newIndices.append(UInt32(vertexMap[oldIdx]!))
            }
        }

        // Create vertex data
        let vertexData = Data(bytes: newVertices, count: newVertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: newVertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        // Create index data
        let indexData = Data(bytes: newIndices, count: newIndices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faceIndices.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        // Semi-transparent teal fill material
        let material = SCNMaterial()
        material.fillMode = .fill
        material.diffuse.contents = UIColor(red: 0.0, green: 0.85, blue: 0.85, alpha: 0.4)
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.blendMode = .alpha
        geometry.materials = [material]

        return geometry
    }

    // MARK: - Point Cloud Visualization

    /// Create an SCNGeometry point cloud from object vertices.
    /// Used when ARKit mesh is too coarse to isolate object faces (common for small objects).
    static func createPointCloudGeometry(
        from vertices: [SIMD3<Float>]
    ) -> SCNGeometry? {
        guard !vertices.isEmpty else { return nil }

        // Subsample if too many points (keep it under 2000 for rendering perf)
        var points = vertices
        if points.count > 2000 {
            points = Array(points.shuffled().prefix(2000))
        }

        let vertexData = Data(bytes: points, count: points.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        // Point indices
        var indices = [UInt32]()
        for i in 0..<UInt32(points.count) { indices.append(i) }
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: points.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = 10.0
        element.minimumPointScreenSpaceRadius = 4.0
        element.maximumPointScreenSpaceRadius = 14.0

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.3, green: 1.0, blue: 1.0, alpha: 1.0)
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        return geometry
    }

    // MARK: - Point Cloud Merging

    /// Merge two point clouds (from different camera angles) with spatial deduplication.
    /// Both clouds must be in world coordinates (ARKit handles this automatically).
    static func mergePointClouds(
        _ cloud1: [SIMD3<Float>],
        _ cloud2: [SIMD3<Float>],
        deduplicationRadius: Float = 0.003  // 3mm
    ) -> [SIMD3<Float>] {
        let quantScale = 1.0 / deduplicationRadius
        var spatialSet = Set<SIMD3<Int32>>()
        var merged = [SIMD3<Float>]()
        merged.reserveCapacity(cloud1.count + cloud2.count)

        for v in cloud1 {
            let key = SIMD3<Int32>(
                Int32(round(v.x * quantScale)),
                Int32(round(v.y * quantScale)),
                Int32(round(v.z * quantScale))
            )
            if spatialSet.insert(key).inserted {
                merged.append(v)
            }
        }

        for v in cloud2 {
            let key = SIMD3<Int32>(
                Int32(round(v.x * quantScale)),
                Int32(round(v.y * quantScale)),
                Int32(round(v.z * quantScale))
            )
            if spatialSet.insert(key).inserted {
                merged.append(v)
            }
        }

        return merged
    }

    // MARK: - Top-Level Measurement API

    /// Vertex-based object isolation: collect vertices near hitPoint, separate surface from
    /// object using RANSAC plane, compute OBB on object vertices.
    /// This works with any mesh resolution — doesn't require fine enough mesh for topology.
    public static func measureObjectFromMesh(
        mesh: UnifiedMesh,
        hitPoint: SIMD3<Float>,
        planeAnchors: [ARPlaneAnchor]
    ) -> MeasurementResult? {
        // 1. Detect surface plane — try ARPlaneAnchors first, then RANSAC
        var surfacePlane: (normal: SIMD3<Float>, d: Float)?

        surfacePlane = detectSurfaceFromPlaneAnchors(
            planeAnchors: planeAnchors,
            near: hitPoint
        )

        if let ransacPlane = detectSurfacePlane(
            vertices: mesh.worldVertices,
            near: hitPoint
        ) {
            if surfacePlane == nil {
                surfacePlane = ransacPlane
            } else {
                let alignment = abs(simd_dot(surfacePlane!.normal, ransacPlane.normal))
                if alignment > 0.9 {
                    surfacePlane = ransacPlane
                }
            }
        }

        guard let plane = surfacePlane else {
            return nil
        }

        // 1b. Compute surface angle from vertical
        let surfaceAngle = acos(min(abs(plane.normal.y), 1.0)) * 180.0 / .pi

        // 2. Collect vertices near hitPoint (XZ radius) and classify by plane distance.
        // Use fixed 18cm radius — covers objects up to 36cm wide.
        // Height cap + SOR handle isolation of the actual object.
        // Previous progressive radius (8→12→18cm, break at 8 pts) clipped
        // elongated objects like bananas (20cm → only 15cm captured at 8cm radius).
        let searchRadius: Float = 0.18
        var objectVertices: [SIMD3<Float>] = []
        let minObjectHeight: Float = 0.005  // 5mm above surface

        let rSq = searchRadius * searchRadius
        for v in mesh.worldVertices {
            let dx = v.x - hitPoint.x
            let dz = v.z - hitPoint.z
            guard dx * dx + dz * dz <= rSq else { continue }

            let planeDist = simd_dot(plane.normal, v) + plane.d
            if planeDist > minObjectHeight {
                objectVertices.append(v)
            }
        }

        guard objectVertices.count >= 8 else {
            return nil
        }

        // 3. Cap object height — remove vertices too far above surface (likely background)
        // Use interquartile approach: find typical height, cap at 3x median height
        let heights = objectVertices.map { simd_dot(plane.normal, $0) + plane.d }
        let sortedHeights = heights.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let maxAllowedHeight = max(medianHeight * 3.0, 0.05)  // At least 5cm, or 3x median

        let cappedVertices = objectVertices.filter { v in
            let h = simd_dot(plane.normal, v) + plane.d
            return h <= maxAllowedHeight
        }
        objectVertices = cappedVertices

        guard objectVertices.count >= 8 else {
            return nil
        }

        // 4. Statistical outlier removal
        objectVertices = removeStatisticalOutliers(from: objectVertices)
        guard objectVertices.count >= 4 else { return nil }

        // 5. Compute OBB
        guard let obb = computeOBB(from: objectVertices, surfaceNormal: plane.normal) else {
            return nil
        }

        // 6. Compute true height from surface plane to highest point
        // OBB height underestimates because depth camera only sees the top surface,
        // not the bottom where the object sits on the table.
        let maxPlaneDist = objectVertices.map { simd_dot(plane.normal, $0) + plane.d }.max() ?? 0
        let trueHeightCm = maxPlaneDist * 100.0
        let obbHeightCm = obb.extents.x * 2.0 * 100.0
        let widthCm = obb.extents.y * 2.0 * 100.0
        let depthCm = obb.extents.z * 2.0 * 100.0
        let heightCm = max(trueHeightCm, obbHeightCm)
        let boxVolume = heightCm * widthCm * depthCm

        // 7. Confidence score
        let vertexDensity = min(Float(objectVertices.count) / 300.0, 1.0)
        let confidence = min(1.0, vertexDensity)

        return MeasurementResult(
            width: widthCm,
            height: heightCm,
            depth: depthCm,
            volume: boxVolume,
            pointCount: objectVertices.count,
            obbCenter: obb.center,
            obbAxes: obb.axes,
            obbExtents: obb.extents,
            confidence: confidence,
            objectVertices: objectVertices,
            surfaceAngle: surfaceAngle
        )
    }

    // MARK: - 3×3 Symmetric Eigendecomposition (Jacobi iteration)

    /// Returns (eigenvalues sorted descending, eigenvectors sorted by eigenvalue descending).
    static func symmetricEigen3x3(_ m: simd_float3x3)
        -> (SIMD3<Float>, (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>))
    {
        // Work with a mutable copy as a flat array [row][col]
        var a: [[Float]] = [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z]
        ]
        // Eigenvector accumulator (starts as identity)
        var v: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0],
            [0, 0, 1]
        ]

        // Jacobi rotation: zero out the largest off-diagonal element
        for _ in 0..<50 {
            // Find largest off-diagonal element
            var p = 0, q = 1
            var maxVal: Float = abs(a[0][1])
            for i in 0..<3 {
                for j in (i+1)..<3 {
                    if abs(a[i][j]) > maxVal {
                        maxVal = abs(a[i][j])
                        p = i; q = j
                    }
                }
            }
            if maxVal < 1e-10 { break }

            let theta: Float
            if abs(a[p][p] - a[q][q]) < 1e-10 {
                theta = Float.pi / 4.0
            } else {
                theta = 0.5 * atan2(2.0 * a[p][q], a[p][p] - a[q][q])
            }

            let c = cos(theta)
            let s = sin(theta)

            // Rotate matrix: A' = G^T A G
            var newA = a
            for i in 0..<3 {
                newA[i][p] = c * a[i][p] + s * a[i][q]
                newA[i][q] = -s * a[i][p] + c * a[i][q]
            }
            // Must copy rows then fix columns
            let tempA = newA
            for j in 0..<3 {
                newA[p][j] = c * tempA[p][j] + s * tempA[q][j]
                newA[q][j] = -s * tempA[p][j] + c * tempA[q][j]
            }
            // Ensure symmetry
            newA[p][q] = 0; newA[q][p] = 0
            a = newA

            // Accumulate rotation into eigenvectors
            var newV = v
            for i in 0..<3 {
                newV[i][p] = c * v[i][p] + s * v[i][q]
                newV[i][q] = -s * v[i][p] + c * v[i][q]
            }
            v = newV
        }

        // Eigenvalues are on the diagonal
        var eigenvalues = [a[0][0], a[1][1], a[2][2]]
        var eigenvectors = [
            SIMD3<Float>(v[0][0], v[1][0], v[2][0]),
            SIMD3<Float>(v[0][1], v[1][1], v[2][1]),
            SIMD3<Float>(v[0][2], v[1][2], v[2][2])
        ]

        // Normalize eigenvectors
        for i in 0..<3 {
            let len = simd_length(eigenvectors[i])
            if len > 1e-10 { eigenvectors[i] /= len }
        }

        // Sort by eigenvalue descending
        let sorted = zip(eigenvalues, eigenvectors)
            .sorted { $0.0 > $1.0 }
        eigenvalues = sorted.map { $0.0 }
        eigenvectors = sorted.map { $0.1 }

        return (
            SIMD3<Float>(eigenvalues[0], eigenvalues[1], eigenvalues[2]),
            (eigenvectors[0], eigenvectors[1], eigenvectors[2])
        )
    }
}
