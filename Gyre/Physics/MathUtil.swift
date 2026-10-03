import simd

typealias V3 = SIMD3<Double>
typealias F3 = SIMD3<Float>
typealias F4 = SIMD4<Float>

extension SIMD3 where Scalar == Double {
  var length: Double { simd_length(self) }
  /// Unit vector, or +Z when the vector is too small to have a direction.
  var unit: V3 {
    let l = simd_length(self)
    return l > 1e-12 ? self / l : V3(0, 0, 1)
  }
  var f: F3 { F3(Float(x), Float(y), Float(z)) }
}

extension SIMD3 where Scalar == Float {
  var unit: F3 {
    let l = simd_length(self)
    return l > 1e-7 ? self / l : F3(0, 0, 1)
  }
}

extension simd_quatd {
  static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
  var float: simd_quatf {
    simd_quatf(ix: Float(imag.x), iy: Float(imag.y), iz: Float(imag.z), r: Float(real))
  }
}

extension simd_quatf {
  var double: simd_quatd {
    simd_quatd(ix: Double(imag.x), iy: Double(imag.y), iz: Double(imag.z), r: Double(real))
  }
}

func clamped<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
  let t = clamped((x - e0) / (e1 - e0), 0, 1)
  return t * t * (3 - 2 * t)
}

/// Any unit vector perpendicular to `v`.
func perpendicular(to v: V3) -> V3 {
  let helper = abs(v.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)
  return simd_normalize(simd_cross(v, helper))
}

/// Wraps an angle into (-π, π].
func wrapAngle(_ a: Double) -> Double {
  var x = a.truncatingRemainder(dividingBy: 2 * .pi)
  if x > .pi { x -= 2 * .pi }
  if x <= -.pi { x += 2 * .pi }
  return x
}
