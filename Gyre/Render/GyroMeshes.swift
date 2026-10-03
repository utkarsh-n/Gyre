import Metal
import simd

/// Mirrors `MeshVertex` in Holo.metal.
struct MeshVertex {
  var position: F4
  var normal: F4
}

/// Mirrors `MeshUniforms` in Holo.metal.
struct MeshUniforms {
  var model: simd_float4x4
  /// Filled in at draw time from `model`.
  var normalModel = matrix_identity_float4x4
  var material: F4  // roughness, anisotropy, iridescence, glow
  var base: F4  // base reflectance, emissive boost
  var spinCenter = F4.zero  // object centre, w = 1 for circular brushing
  var spinAxis = F4.zero  // w = pattern: 0 metal, 1 machined (lathe marks), 2 planet, 3 planet ring
  var spinU = F4.zero  // a direction ⟂ the axis that turns with the object, w = sweep
  var extra = F4.zero  // object size, then glass refraction, frost, dispersion
}

struct GPUMesh {
  let vertices: MTLBuffer
  let indices: MTLBuffer
  let count: Int
}

/// Solid geometry for the holo-metal gyroscope, built once in unit sizes and placed per
/// frame. The rotor is a turned wheel (rim, web, hub) about +Z with outer radius 1; its
/// bolts are separate so they can vanish into the blur at speed.
enum GyroMeshes {
  final class Builder {
    var vertices: [MeshVertex] = []
    var indices: [UInt32] = []

    /// A (rows+1)×(cols+1) grid of vertices, wound so triangles face along the normals.
    func grid(rows: Int, cols: Int, _ at: (Int, Int) -> (F3, F3)) {
      let base = UInt32(vertices.count)
      for i in 0...rows {
        for j in 0...cols {
          let (p, n) = at(i, j)
          vertices.append(MeshVertex(position: F4(p, 1), normal: F4(n, 0)))
        }
      }
      var tris: [UInt32] = []
      let w = UInt32(cols + 1)
      for i in 0..<UInt32(rows) {
        for j in 0..<UInt32(cols) {
          let a = base + i * w + j
          let b = a + w
          tris += [a, b, a + 1, a + 1, b, b + 1]
        }
      }
      orient(&tris)
      indices += tris
    }

    /// A fan closing a circle at height `z`, facing `up` (+1) or down (−1).
    func cap(radius: Float, z: Float, up: Float, segments: Int) {
      let center = UInt32(vertices.count)
      let n = F3(0, 0, up)
      vertices.append(MeshVertex(position: F4(0, 0, z, 1), normal: F4(n, 0)))
      for k in 0...segments {
        let a = Float(k) / Float(segments) * 2 * .pi
        vertices.append(MeshVertex(position: F4(radius * cos(a), radius * sin(a), z, 1), normal: F4(n, 0)))
      }
      var tris: [UInt32] = []
      for k in 0..<UInt32(segments) { tris += [center, center + 1 + k, center + 2 + k] }
      orient(&tris)
      indices += tris
    }

    /// Flips the batch if its first proper triangle faces against its vertex normal.
    private func orient(_ tris: inout [UInt32]) {
      for t in stride(from: 0, to: tris.count, by: 3) {
        let a = vertices[Int(tris[t])], b = vertices[Int(tris[t + 1])], c = vertices[Int(tris[t + 2])]
        let pa = F3(a.position.x, a.position.y, a.position.z)
        let face = simd_cross(F3(b.position.x, b.position.y, b.position.z) - pa, F3(c.position.x, c.position.y, c.position.z) - pa)
        guard simd_length(face) > 1e-9 else { continue }
        if simd_dot(face, F3(a.normal.x, a.normal.y, a.normal.z)) < 0 {
          for k in stride(from: 0, to: tris.count, by: 3) { tris.swapAt(k + 1, k + 2) }
        }
        return
      }
    }

    func torus(major: Float, minor: Float, z: Float = 0, segments: Int = 72, sides: Int = 18) {
      grid(rows: segments, cols: sides) { i, j in
        let t = Float(i) / Float(segments) * 2 * .pi
        let f = Float(j) / Float(sides) * 2 * .pi
        let n = F3(cos(f) * cos(t), cos(f) * sin(t), sin(f))
        return (F3(major * cos(t), major * sin(t), z) + minor * n, n)
      }
    }

    func cylinder(radius: Float, z0: Float, z1: Float, segments: Int = 48, caps: Bool = true) {
      grid(rows: 1, cols: segments) { i, j in
        let a = Float(j) / Float(segments) * 2 * .pi
        let n = F3(cos(a), sin(a), 0)
        return (F3(radius * n.x, radius * n.y, i == 0 ? z0 : z1), n)
      }
      if caps {
        cap(radius: radius, z: z1, up: 1, segments: segments)
        cap(radius: radius, z: z0, up: -1, segments: segments)
      }
    }

    func sphere(center: F3 = .zero, radius: Float, segments: Int = 24) {
      grid(rows: segments / 2, cols: segments) { i, j in
        let th = Float(i) / Float(segments / 2) * .pi
        let ph = Float(j) / Float(segments) * 2 * .pi
        let n = F3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th))
        return (center + radius * n, n)
      }
    }

    /// A surface of revolution about +Z from (radius, z) points listed bottom to top.
    func lathe(_ profile: [SIMD2<Float>], segments: Int = 72) {
      grid(rows: profile.count - 1, cols: segments) { i, j in
        let a = Float(j) / Float(segments) * 2 * .pi
        let p = profile[i]
        let prev = profile[max(i - 1, 0)]
        let next = profile[min(i + 1, profile.count - 1)]
        let t = next - prev
        let n2 = SIMD2(t.y, -t.x)
        let n = simd_length(n2) > 1e-6 ? n2 / simd_length(n2) : SIMD2<Float>(1, 0)
        return (F3(p.x * cos(a), p.x * sin(a), p.y), F3(n.x * cos(a), n.x * sin(a), n.y))
      }
    }

    /// A flat ring between two radii, visible from both sides.
    func annulus(inner: Float, outer: Float, segments: Int = 120) {
      for side: Float in [1, -1] {
        grid(rows: 1, cols: segments) { i, j in
          let a = Float(j) / Float(segments) * 2 * .pi
          let r = i == 0 ? inner : outer
          return (F3(r * cos(a), r * sin(a), 0), F3(0, 0, side))
        }
      }
    }

    /// Catmull–Rom subdivision of a lathe profile, for smooth silhouettes.
    static func smooth(_ p: [SIMD2<Float>], steps: Int = 4) -> [SIMD2<Float>] {
      guard p.count > 2 else { return p }
      var out: [SIMD2<Float>] = []
      for i in 0..<(p.count - 1) {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        for k in 0..<steps {
          let t = Float(k) / Float(steps)
          let t2 = t * t, t3 = t2 * t
          let a = 2 * p1
          let b = (p2 - p0) * t
          let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
          let d = (3 * p1 - p0 - 3 * p2 + p3) * t3
          var q = 0.5 * (a + b + c + d)
          q.x = max(q.x, 0)
          out.append(q)
        }
      }
      out.append(p[p.count - 1])
      return out
    }

    func upload(_ device: MTLDevice) -> GPUMesh? {
      guard
        let v = device.makeBuffer(bytes: vertices, length: MemoryLayout<MeshVertex>.stride * vertices.count),
        let i = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count)
      else { return nil }
      return GPUMesh(vertices: v, indices: i, count: indices.count)
    }
  }

  static func rotor(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.torus(major: 0.86, minor: 0.14)
    b.cylinder(radius: 0.8, z0: -0.035, z1: 0.035, segments: 72)
    b.torus(major: 0.8, minor: 0.03, z: 0.035, segments: 72, sides: 10)
    b.torus(major: 0.8, minor: 0.03, z: -0.035, segments: 72, sides: 10)
    b.cylinder(radius: 0.17, z0: -0.17, z1: 0.17, segments: 32)
    b.torus(major: 0.17, minor: 0.035, z: 0.17, segments: 32, sides: 10)
    b.torus(major: 0.17, minor: 0.035, z: -0.17, segments: 32, sides: 10)
    return b.upload(device)
  }

  static func bolts(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    for k in 0..<6 {
      let a = Float(k) / 6 * 2 * .pi
      for z: Float in [0.045, -0.045] {
        b.sphere(center: F3(0.52 * cos(a), 0.52 * sin(a), z), radius: 0.06, segments: 12)
      }
    }
    return b.upload(device)
  }

  /// A thin ring of radius 1 around +Z.
  static func ring(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.torus(major: 1, minor: 0.026, segments: 96, sides: 12)
    return b.upload(device)
  }

  /// Radius 1 along +Z from 0 to 1.
  static func rod(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.cylinder(radius: 1, z0: 0, z1: 1, segments: 24)
    return b.upload(device)
  }

  static func ball(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.sphere(radius: 1, segments: 28)
    return b.upload(device)
  }

  /// A finer sphere for silhouettes that fill the bubble: the glass orb and the planet.
  static func globe(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.sphere(radius: 1, segments: 96)
    return b.upload(device)
  }

  /// The machined top above its point, traced from the Inception top's proportions: the
  /// disc's underside, a thin rim of radius 1 at z = 0, the disc's sloping face, and a
  /// stem that flares out of it in a concave trumpet curve to a domed tip. Lengths are in
  /// disc radii; the centre of mass sits at the origin.
  static let topJunction: Float = -0.235

  static func topUpper(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    let profile: [SIMD2<Float>] = [
      SIMD2(0.42, topJunction), SIMD2(0.6, -0.17), SIMD2(0.8, -0.11), SIMD2(0.93, -0.07), SIMD2(0.995, -0.035),
      SIMD2(1.0, -0.012), SIMD2(0.995, 0.012), SIMD2(0.96, 0.03), SIMD2(0.85, 0.052), SIMD2(0.7, 0.087),
      SIMD2(0.56, 0.13), SIMD2(0.45, 0.17), SIMD2(0.36, 0.22), SIMD2(0.28, 0.29), SIMD2(0.22, 0.37),
      SIMD2(0.17, 0.48), SIMD2(0.14, 0.62), SIMD2(0.125, 0.8), SIMD2(0.115, 1.05), SIMD2(0.11, 1.3),
      SIMD2(0.1, 1.42), SIMD2(0.075, 1.5), SIMD2(0.04, 1.545), SIMD2(0, 1.56),
    ]
    b.lathe(Builder.smooth(profile), segments: 96)
    return b.upload(device)
  }

  /// The point, as a concave cone from the junction (z = 0) to the tip (z = −1), so it can
  /// be stretched to reach the pivot.
  static func topPoint(_ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    let span = 0.78 + topJunction
    let raw: [SIMD2<Float>] = [
      SIMD2(0, -0.78), SIMD2(0.025, -0.765), SIMD2(0.09, -0.67), SIMD2(0.15, -0.57), SIMD2(0.2, -0.49),
      SIMD2(0.27, -0.38), SIMD2(0.33, -0.3), SIMD2(0.42, topJunction),
    ]
    let profile = raw.map { SIMD2($0.x, ($0.y - topJunction) / span) }
    b.lathe(Builder.smooth(profile), segments: 72)
    return b.upload(device)
  }

  static func planetRing(inner: Float, outer: Float, _ device: MTLDevice) -> GPUMesh? {
    let b = Builder()
    b.annulus(inner: inner, outer: outer)
    return b.upload(device)
  }
}

extension simd_float4x4 {
  init(translation t: F3) {
    self = matrix_identity_float4x4
    columns.3 = F4(t, 1)
  }

  init(scale s: F3) {
    self = simd_float4x4(diagonal: F4(s, 1))
  }

  /// Columns are the given axes, then a translation.
  init(basis x: F3, _ y: F3, _ z: F3, origin: F3) {
    self.init(F4(x, 0), F4(y, 0), F4(z, 0), F4(origin, 1))
  }
}
