import simd

/// Dust motes drifting in the bubble's air, simulated in the phone's frame (bubble radius 1).
/// They fall with local gravity, slosh when the phone accelerates, swirl in the rotor's
/// wake, and lag behind when the phone turns because the air inside does.
final class MoteField {
  struct Mote {
    var p: F3
    var v: F3
    var seed: Float
  }

  private(set) var motes: [Mote] = []
  private var rng: UInt32 = 0x9E37_79B9

  init(count: Int = 220) {
    motes.reserveCapacity(count)
    while motes.count < count {
      let p = F3(random() * 2 - 1, random() * 2 - 1, random() * 2 - 1)
      if simd_length(p) < 1 { motes.append(Mote(p: p * 0.9, v: .zero, seed: random())) }
    }
  }

  private func random() -> Float {
    rng ^= rng << 13
    rng ^= rng >> 17
    rng ^= rng << 5
    return Float(rng) / Float(UInt32.max)
  }

  /// - Parameters:
  ///   - gravity: effective gravity in g, phone frame.
  ///   - jolt: the phone's own acceleration in g, phone frame.
  ///   - swirl: angular velocity of the air relative to the bubble, rad/s.
  ///   - rotorSpin: rotor spin as seen in real time, rad/s.
  func step(
    dt: Float, gravity: F3, jolt: F3, air: Float, swirl: F3,
    rotorCenter: F3, rotorAxis: F3, rotorSpin: Float, rotorRadius: Float
  ) {
    guard dt > 0 else { return }
    let drag = 2.4 * air + 0.12
    let vortex = clamped(rotorSpin * 0.004, -3, 3) * min(air, 2)
    // In air the dust is nearly buoyant and settles over many seconds, like a snow globe;
    // in a vacuum nothing holds it up.
    let gScene: Float = 3.0 - 2.6 * min(air / 0.3, 1)
    let shimmer = 0.12 * air
    let wall: Float = 0.965
    for i in motes.indices {
      var m = motes[i]
      var u = simd_cross(swirl, m.p)
      let r = m.p - rotorCenter
      let along = simd_dot(r, rotorAxis)
      let radial = r - along * rotorAxis
      let dist = simd_length(radial)
      if dist > 1e-3 {
        let tangent = simd_cross(rotorAxis, radial) / dist
        let ring = (dist - rotorRadius) / 0.35
        u += tangent * vortex * exp(-ring * ring) * exp(-along * along / 0.12)
      }
      let body = gravity * gScene - jolt * 4.2
      var a = body + (u - m.v) * drag
      a += F3(random() - 0.5, random() - 0.5, random() - 0.5) * (2 * shimmer)
      m.v += a * dt
      m.p += m.v * dt
      let d = simd_length(m.p)
      if d > wall {
        let n = m.p / d
        m.p = n * wall
        let vn = simd_dot(m.v, n)
        if vn > 0 {
          m.v -= 1.35 * vn * n
          m.v *= 0.92
        }
        // Static friction against the film: dust rests on slopes gentler than ~30° and
        // settles across the floor instead of collecting at the lowest point.
        let press = simd_dot(body, n)
        let slide = body - press * n
        let tangential = m.v - simd_dot(m.v, n) * n
        if press > 0, simd_length(slide) < 0.6 * press {
          m.v -= tangential
        } else {
          m.v -= tangential * 0.15
        }
      }
      motes[i] = m
    }
  }
}

/// The bubble's jelly wobble: a damped spring driven by the phone's acceleration.
/// `d` is a quadrupole deformation (direction × amplitude) in the phone frame.
struct Jiggle {
  var d = F3.zero
  var v = F3.zero

  mutating func step(dt: Float, accel: F3, enabled: Bool) {
    guard dt > 0 else { return }
    let w: Float = 2 * .pi * 3.2
    let drive = enabled ? accel * 14 : .zero
    let a = -w * w * d - 2 * 0.14 * w * v + drive
    v += a * dt
    d += v * dt
    let m = simd_length(d)
    if m > 0.07 { d *= 0.07 / m }
    if !enabled { d *= 0.9 }
  }

  /// A sudden push to the wobble's velocity.
  mutating func kick(_ impulse: F3) { v += impulse }
}

/// World-frame history of the spin axis, drawn as the axle tip's precession/nutation trace.
struct TrailBuffer {
  private(set) var points: [F3]
  private var head = 0
  private(set) var count = 0

  init(capacity: Int) { points = Array(repeating: .zero, count: capacity) }

  mutating func append(_ p: F3) {
    points[head] = p
    head = (head + 1) % points.count
    count = min(count + 1, points.count)
  }

  mutating func clear() { count = 0 }

  /// Oldest first.
  func forEach(_ body: (Int, F3) -> Void) {
    let start = (head - count + points.count) % points.count
    for i in 0..<count { body(i, points[(start + i) % points.count]) }
  }
}
