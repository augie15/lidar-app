import simd

/// Pinhole projection for an ARKit keyframe.
///
/// ARKit camera space: camera looks down -Z, +Y up, +X right. Image space is the landscape sensor image the
/// intrinsics belong to: origin top-left, +u right, +v down. So for a camera-space point (x, y, z) with z < 0:
///     u = fx * x / -z + cx
///     v = fy * (-y) / -z + cy
struct CameraProjection: Sendable {
    let worldToCamera: simd_float4x4
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Float
    let height: Float

    /// `cameraToWorld` is the ARKit camera transform (as stored in transforms.json).
    init(cameraToWorld: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float, width: Float, height: Float) {
        self.worldToCamera = cameraToWorld.inverse
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.width = width; self.height = height
    }

    var cameraPosition: SIMD3<Float> {
        let c = worldToCamera.inverse.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    /// Pixel coordinates (in this projection's image size) plus distance in front of the camera, or nil when the point
    /// is behind the camera.
    @inline(__always)
    func project(_ world: SIMD3<Float>) -> (u: Float, v: Float, depth: Float)? {
        let c = worldToCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
        let depth = -c.z
        guard depth > 0.05 else { return nil }
        let u = fx * c.x / depth + cx
        let v = fy * (-c.y) / depth + cy
        return (u, v, depth)
    }
}
