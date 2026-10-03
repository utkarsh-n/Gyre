import Foundation
import simd

/// Everything the knobs control. Values are in the units the knobs show.
struct GyroParams: Equatable {
  var motorRPM = 3000.0  // target spin; 0 = motor off, rotor coasts
  var inertia = 1.0  // × moment of inertia of a 6 cm brass disc
  var gravity = 1.0  // local gravity in g (negative = inverted)
  var balance = 0.5  // rotor position on the axle, −1…1 of 3.5 cm
  var friction = 0.25  // pivot and bearing friction, 0…1
  var air = 1.0  // air density × sea level
  var magnet = 0.0  // rotor magnetisation, 0…1
  var timeScale = 1.0  // simulation speed
}

/// Sensor-derived surroundings for one step, in the world frame (Z up, from Core Motion).
struct GyroEnvironment {
  var deviceRate = V3.zero  // phone's angular velocity, rad/s (real time)
  var linearAccel = V3.zero  // phone's acceleration minus gravity, m/s²
  var magneticField = V3.zero  // tesla
  var airDensity = 1.0  // × sea level
  var extraTorque = V3.zero  // N·m, e.g. sound pushing the rotor
}

/// A symmetric heavy top on a frictional ball pivot fixed to the phone.
///
/// The rotor's spin axis `axis` and angular momentum `momentum` live in the world frame,
/// so the rotor keeps its orientation in space while the phone (and the bubble) turns
/// around it. Torques: gravity and the phone's own acceleration acting on the offset
/// centre of mass, a magnetic dipole in the measured field, the spin motor, pivot friction
/// relative to the phone, and air drag relative to the air in the bubble.
final class GyroSim {
  static let mass = 0.06  // kg
  static let rotorRadius = 0.03  // m
  static let maxOffset = 0.035  // m, balance = ±1
  static let cageInertia = 2.5e-6  // kg·m², cage and axle about a transverse axis
  static let g0 = 9.80665
  static let maxDipole = 60.0  // A·m² at magnet = 1 (a fantasy magnet; Earth's field then matters)
  static let motorGain = 2e-4  // N·m·s
  static let motorTorque = 2.5e-3  // N·m
  static let swivelFriction = 6e-5  // N·m·s at friction = 1
  static let spinFriction = 1.2e-6  // N·m·s at friction = 1
  static let airLinear = 1.5e-7  // N·m·s, spin drag
  static let airQuadratic = 6e-9  // N·m·s², spin drag
  static let airTransverse = 2e-6  // N·m·s, drag on swinging and precession

  private(set) var axis = V3(0, 0, 1)
  private(set) var momentum = V3.zero
  /// A cage direction perpendicular to the axis, parallel-transported (it never twists
  /// about the axis), so the cage doesn't spin and the rotor spins inside it.
  private(set) var cageX = V3(1, 0, 0)
  private(set) var spinAngle = 0.0
  /// Rotor angle swept during the last step; drives the motion blur.
  private(set) var spinSweep = 0.0
  private(set) var offset = 0.5 * maxOffset
  private(set) var inertiaScale = 1.0
  /// Angular velocity of the air inside the bubble (it lags the phone).
  private(set) var airRate = V3.zero
  private(set) var externalTorque = V3.zero
  private(set) var effectiveGravity = V3(0, 0, -g0)
  /// Azimuthal rate of the axis about world vertical, rad/s of simulated time, smoothed.
  private(set) var precessionRate = 0.0
  /// How fast the axis direction itself is moving, rad/s of simulated time.
  private(set) var axisSpeed = 0.0
  private var lastAzimuth: Double?
  var paused = false

  var I3: Double { inertiaScale * 0.5 * Self.mass * Self.rotorRadius * Self.rotorRadius }
  var I1: Double { Self.transverseInertia(scale: inertiaScale, offset: offset) }
  /// Spin about the axis, rad/s.
  var spinRate: Double { simd_dot(momentum, axis) / I3 }
  var rpm: Double { spinRate * 60 / (2 * .pi) }
  /// Angle between the spin axis and world up.
  var tilt: Double { acos(clamped(axis.z, -1, 1)) }
  var angularVelocity: V3 {
    let l3 = simd_dot(momentum, axis)
    return (momentum - l3 * axis) / I1 + (l3 / I3) * axis
  }

  static func transverseInertia(scale: Double, offset: Double) -> Double {
    scale * 0.25 * mass * rotorRadius * rotorRadius + cageInertia + mass * offset * offset
  }

  // MARK: Stepping

  private struct Context {
    var I1: Double
    var I3: Double
    var offset: Double
    var gravity: V3
    var dipole: Double
    var field: V3
    var motorOn: Bool
    var motorTarget: Double
    var swivel: Double
    var spin: Double
    var deviceRate: V3
    var airRate: V3
    var rho: Double
    var extra: V3
  }

  func step(dtReal rawDt: Double, env: GyroEnvironment, params p: GyroParams) {
    let dtReal = clamped(rawDt, 0, 0.05)
    // Knob changes ease in so the rotor never teleports. Changing inertia keeps
    // angular momentum: spin slows as inertia grows, like a skater's arms.
    offset += (p.balance * Self.maxOffset - offset) * (1 - exp(-dtReal / 0.25))
    inertiaScale += (p.inertia - inertiaScale) * (1 - exp(-dtReal / 0.3))
    airRate += (env.deviceRate - airRate) * (1 - exp(-dtReal / 0.9))
    effectiveGravity = V3(0, 0, -Self.g0 * p.gravity) - env.linearAccel
    spinSweep = 0

    let scale = max(p.timeScale, 0.02)
    let w3 = spinRate
    let fric = p.friction * p.friction
    var c = Context(
      I1: I1, I3: I3, offset: offset, gravity: effectiveGravity,
      dipole: p.magnet * Self.maxDipole, field: env.magneticField,
      motorOn: p.motorRPM > 1, motorTarget: (w3 < -5 ? -1 : 1) * p.motorRPM * 2 * .pi / 60,
      swivel: Self.swivelFriction * fric, spin: Self.spinFriction * fric,
      // In slow motion the phone turns faster relative to the rotor's clock.
      deviceRate: env.deviceRate / scale, airRate: airRate / scale,
      rho: env.airDensity, extra: env.extraTorque)
    externalTorque = torque(axis: axis, c)

    guard !paused, dtReal > 0 else {
      axisSpeed = 0
      return
    }
    let dt = dtReal * scale

    // Substeps resolve the fastest motion present: nutation (≈ L₃/I₁ for a fast top),
    // pendulum swing, magnetic oscillation, or friction relaxation.
    let l3 = abs(simd_dot(momentum, axis))
    var fastest = l3 / c.I1
    fastest = max(fastest, sqrt(Self.mass * simd_length(c.gravity) * abs(c.offset) / c.I1))
    fastest = max(fastest, sqrt(c.dipole * simd_length(c.field) / c.I1))
    fastest = max(fastest, (c.swivel + c.rho * Self.airTransverse) / c.I1)
    fastest = max(fastest, simd_length(angularVelocity - simd_dot(angularVelocity, axis) * axis))
    let n = Int(clamped((dt * fastest / 0.1).rounded(.up), 1, 2000))
    let h = dt / Double(n)
    c.motorTarget = (w3 < -5 ? -1 : 1) * p.motorRPM * 2 * .pi / 60

    for _ in 0..<n {
      rk4(h, c)
      let t = cageX - simd_dot(cageX, axis) * axis
      cageX = simd_length(t) > 1e-6 ? simd_normalize(t) : perpendicular(to: axis)
      let spin = simd_dot(momentum, axis) / c.I3
      spinAngle += spin * h
      spinSweep += spin * h
    }
    spinAngle = spinAngle.truncatingRemainder(dividingBy: 2 * .pi)
    externalTorque = torque(axis: axis, c)
    axisSpeed = simd_length(simd_cross(angularVelocity, axis))

    let horizontal = hypot(axis.x, axis.y)
    let azimuth = atan2(axis.y, axis.x)
    if let last = lastAzimuth, horizontal > 0.03 {
      let rate = wrapAngle(azimuth - last) / dt
      precessionRate += (rate - precessionRate) * (1 - exp(-dtReal / 0.6))
    } else if horizontal <= 0.03 {
      precessionRate *= exp(-dtReal / 0.6)
    }
    lastAzimuth = azimuth
  }

  /// Gravity (plus the phone's acceleration) on the offset centre of mass, and the
  /// magnetic dipole in the field. Excludes motor and friction.
  private func torque(axis e: V3, _ c: Context) -> V3 {
    simd_cross(c.offset * e, Self.mass * c.gravity) + c.dipole * simd_cross(e, c.field)
  }

  private func derivative(_ e: V3, _ L: V3, _ c: Context) -> (V3, V3) {
    let l3 = simd_dot(L, e)
    let lPerp = L - l3 * e
    let w = lPerp / c.I1 + (l3 / c.I3) * e
    let de = simd_cross(w, e)

    var tau = torque(axis: e, c) + c.extra
    if c.motorOn {
      let w3 = l3 / c.I3
      tau += clamped(Self.motorGain * (c.motorTarget - w3), -Self.motorTorque, Self.motorTorque) * e
    }
    // The pivot is held by the phone, so its friction acts on motion relative to the phone.
    let rel = w - c.deviceRate
    let rel3 = simd_dot(rel, e)
    tau -= c.swivel * (rel - rel3 * e) + c.spin * rel3 * e
    // Air drag acts relative to the air, which itself is dragged around by the bubble.
    let ra = w - c.airRate
    let ra3 = simd_dot(ra, e)
    tau -=
      c.rho
      * ((Self.airLinear + Self.airQuadratic * abs(ra3)) * ra3 * e
        + Self.airTransverse * (ra - ra3 * e))
    return (de, tau)
  }

  private func rk4(_ h: Double, _ c: Context) {
    let e0 = axis
    let l0 = momentum
    let (k1e, k1l) = derivative(e0, l0, c)
    let (k2e, k2l) = derivative(simd_normalize(e0 + 0.5 * h * k1e), l0 + 0.5 * h * k1l, c)
    let (k3e, k3l) = derivative(simd_normalize(e0 + 0.5 * h * k2e), l0 + 0.5 * h * k2l, c)
    let (k4e, k4l) = derivative(simd_normalize(e0 + h * k3e), l0 + h * k3l, c)
    axis = simd_normalize(e0 + h / 6 * (k1e + 2 * k2e + 2 * k3e + k4e))
    momentum = l0 + h / 6 * (k1l + 2 * k2l + 2 * k3l + k4l)
  }

  // MARK: Interaction

  /// Places the rotor at `tilt` from vertical, spinning, already in steady precession
  /// so it starts smoothly instead of lurching.
  func launch(params p: GyroParams, tilt: Double = 0.32, azimuth: Double = 0.6, rpm: Double? = nil)
  {
    offset = p.balance * Self.maxOffset
    inertiaScale = p.inertia
    let e = V3(sin(tilt) * cos(azimuth), sin(tilt) * sin(azimuth), cos(tilt))
    axis = e
    let spinRPM = rpm ?? (p.motorRPM > 1 ? p.motorRPM : 3000)
    let l3 = I3 * spinRPM * 2 * .pi / 60
    let mgl = Self.mass * Self.g0 * p.gravity * offset
    let cosT = e.z
    var omegaP = mgl / max(abs(l3), 1e-9)
    // Slow root of I₁ cosθ Ω² − L₃ Ω + mgℓ = 0.
    if abs(cosT) > 1e-3 {
      let disc = l3 * l3 - 4 * I1 * cosT * mgl
      if disc > 0 { omegaP = (l3 - sqrt(disc)) / (2 * I1 * cosT) }
    }
    momentum = l3 * e + I1 * omegaP * (V3(0, 0, 1) - cosT * e)
    cageX = perpendicular(to: e)
    spinAngle = 0
    precessionRate = omegaP
    lastAzimuth = nil
  }

  func applyImpulse(_ dL: V3) { momentum += dL }

  /// Adds angular momentum along the spin axis (a string pull or a finger on the rim).
  func addSpin(_ dL3: Double) { momentum += dL3 * axis }

  /// Kinetic + potential energy, for checking the integrator.
  var energy: Double {
    let l3 = simd_dot(momentum, axis)
    let lp = momentum - l3 * axis
    return simd_length_squared(lp) / (2 * I1) + l3 * l3 / (2 * I3)
      - Self.mass * simd_dot(offset * axis, effectiveGravity)
  }
}
