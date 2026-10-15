import Foundation
import simd

/// Mirrors `Uniforms` in Holo.metal. "Bubble frame" is the unit sphere's own frame: the
/// phone's frame normally, the anchored bubble's frame in AR.
struct HoloUniforms {
  var attitude = matrix_identity_float4x4  // bubble frame → physics world (Z up)
  var viewProj = matrix_identity_float4x4  // bubble frame → clip
  var viewport = F4.zero  // width, height, bubble centre x, y (pixels)
  var camera = F4.zero  // focal (px), camera distance, time, EDR headroom
  var gravity = F4.zero  // phone-frame direction of fall, |g|
  var jiggle = F4.zero  // quadrupole deformation, breathing
  var film = F4.zero  // drain, swirl, north azimuth, has north
  var post = F4.zero  // bloom, scanlines, aberration, reduce motion
  var lightA = F4.zero  // phone-frame light direction, intensity
  var lightB = F4.zero
  var misc = F4.zero  // bubble radius (px)
  var eye = F4.zero  // camera position in the bubble frame, AR flag
  var camA = F4.zero  // view → camera-image transform a, b, c, d
  var camB = F4.zero  // tx, ty, sound shimmer, —
  var ripples: (F4, F4, F4, F4) = (F4(0, 0, 0, -1), F4(0, 0, 0, -1), F4(0, 0, 0, -1), F4(0, 0, 0, -1))
}

/// Mirrors `LineInstance` in Holo.metal: a glowing segment, phone frame, widths in pixels.
struct LineInstance {
  var a: F4
  var b: F4
  var ca: F4
  var cb: F4
}

enum HoloPalette {
  static let rotor = F3(0.30, 0.88, 1.00)
  static let rotorCore = F3(0.85, 0.97, 1.00)
  static let cage = F3(0.62, 0.42, 1.00)
  static let axle = F3(0.75, 0.86, 1.00)
  static let momentum = F3(0.25, 1.00, 0.85)
  static let torque = F3(1.00, 0.32, 0.80)
  static let gravity = F3(1.00, 0.66, 0.22)
  static let field = F3(0.50, 1.00, 0.42)
  static let trailHead = F3(0.35, 1.00, 0.90)
  static let trailTail = F3(0.55, 0.35, 1.00)
  static let horizon = F3(0.45, 0.60, 1.00)
  static let north = F3(1.00, 0.35, 0.40)
  static let mote = F3(0.70, 0.85, 1.00)
  static let emitter = F3(0.30, 0.75, 1.00)
  static let phosphor = F3(0.35, 1.00, 0.55)
  static let fieldLine = F3(0.40, 1.00, 0.72)
  static let emf = F3(1.0, 0.85, 0.35)

  /// Low notes magenta, through amber, green and cyan, to violet highs.
  static func spectrum(_ x: Float) -> F3 {
    let t = x * 0.85
    return F3(
      0.55 + 0.45 * cos(2 * .pi * (t + 0.0)), 0.55 + 0.45 * cos(2 * .pi * (t + 0.67)),
      0.55 + 0.45 * cos(2 * .pi * (t + 0.33)))
  }
}

/// The gyroscope's placement in the bubble frame: rotor centre, cage axes (u, v) and spin
/// axis (e), the pivot, and sizes in bubble radii.
struct GyroPose {
  var center = F3.zero
  var u = F3(1, 0, 0)
  var v = F3(0, 1, 0)
  var e = F3(0, 0, 1)
  var pivot = F3.zero
  var rotorRadius: Float = 0.36
  var cageRadius: Float = 0.4
  var axleHalf: Float = 0.45
  var ell: Float = 0
  var spinAngle: Float = 0
  var sweep: Float = 0
}

/// Where the viewer is, in the bubble frame: the direction toward the eye and a screen-
/// aligned right/up pair, plus how thick lines should be at this distance.
struct ViewBasis {
  var eye = F3(0, 0, 3.2)
  var toEye = F3(0, 0, 1)
  var right = F3(1, 0, 0)
  var up = F3(0, 1, 0)
  var widthScale: Float = 1
}

/// Builds the hologram's line geometry for one frame, in the bubble frame where the bubble
/// is the unit sphere at the origin.
struct HoloSceneBuilder {
  private(set) var lines: [LineInstance] = []
  var pxScale: Float = 3
  /// Height of the hologram's sweeping scan band, and the flicker gain.
  private(set) var bandY: Float = 9
  private(set) var flicker: Float = 1
  private var view = ViewBasis()
  private var wx = F3(1, 0, 0)
  private var wy = F3(0, 1, 0)
  private var wz = F3(0, 0, 1)
  /// Where the gyroscope is this frame, for placing the metal meshes.
  private(set) var pose = GyroPose()
  /// The first `objectLineCount` lines belong to the spinning object (the glass orb
  /// refracts those); the rest are the bubble's own.
  private(set) var objectLineCount = 0

  init() { lines.reserveCapacity(4096) }

  // MARK: Primitives

  private func cue(_ p: F3) -> Float {
    let depth = 0.35 + 0.65 * smoothstep(-1.1, 1.0, simd_dot(p, view.toEye))
    let d = (p.y - bandY) / 0.07
    return 0.72 * depth * (1 + 0.9 * exp(-d * d)) * flicker
  }

  private func width(_ w: Float, _ p: F3) -> Float {
    w * pxScale * view.widthScale * (0.75 + 0.25 * smoothstep(-1, 1, simd_dot(p, view.toEye)))
  }

  mutating func seg(_ a: F3, _ b: F3, _ ca: F3, _ cb: F3, alpha: Float = 1, alphaB: Float? = nil, width w: Float) {
    lines.append(
      LineInstance(
        a: F4(a, width(w, a)), b: F4(b, width(w, b)),
        ca: F4(ca * cue(a), alpha), cb: F4(cb * cue(b), alphaB ?? alpha)))
  }

  mutating func point(_ p: F3, _ color: F3, size: Float, alpha: Float = 1) {
    seg(p, p, color, color, alpha: alpha, width: size)
  }

  /// A circle (or arc) of `radius` in the plane spanned by unit vectors `u`, `v`.
  mutating func ring(
    _ center: F3, _ u: F3, _ v: F3, radius: Float, color: F3, width: Float, alpha: Float = 1,
    segments: Int = 64, start: Float = 0, sweep: Float = 2 * .pi, dashed: Bool = false
  ) {
    let n = max(2, Int(Float(segments) * min(abs(sweep), 2 * .pi) / (2 * .pi)) + 1)
    var prev = center + radius * (cos(start) * u + sin(start) * v)
    for i in 1...n {
      let t = start + sweep * Float(i) / Float(n)
      let p = center + radius * (cos(t) * u + sin(t) * v)
      if !dashed || i % 2 == 0 { seg(prev, p, color, color, alpha: alpha, width: width) }
      prev = p
    }
  }

  mutating func arrow(from a: F3, to b: F3, color: F3, width w: Float, alpha: Float = 1) {
    let d = b - a
    let len = simd_length(d)
    guard len > 1e-4 else { return }
    let dir = d / len
    seg(a, b, color * 0.55, color, alpha: alpha, width: w)
    var side = simd_cross(dir, view.toEye)
    if simd_length(side) < 0.2 { side = simd_cross(dir, view.up) }
    side = side.unit
    let head = min(0.07, len * 0.35)
    seg(b, b - dir * head + side * head * 0.55, color, color, alpha: alpha, width: w)
    seg(b, b - dir * head - side * head * 0.55, color, color, alpha: alpha, width: w)
  }

  /// Three rim markers drawn as arcs over the angle swept this frame: honest motion blur.
  private mutating func markers(
    center: F3, u: F3, v: F3, radius: Float, psi: Float, sweep: Float, alpha: Float, flash: (F3, Float)? = nil
  ) {
    let span = min(abs(sweep), 2 * .pi)
    var markerAlpha = clamped(0.45 / max(span, 0.01), 0.08, 0.9) * alpha
    var color = HoloPalette.rotorCore
    if let (tint, amount) = flash, amount > 0.01 {
      // A radio wave just arrived: the rotor's glow takes its colour for a moment.
      color = simd_mix(color, tint * 1.6, F3(repeating: amount))
      markerAlpha = min(markerAlpha + amount * 0.6, 1)
    }
    for k in 0..<3 {
      let a = psi + Float(k) * 2 * .pi / 3
      ring(
        center, u, v, radius: radius, color: color, width: 2.6, alpha: markerAlpha,
        segments: 72, start: a - (sweep < 0 ? -span : span), sweep: max(sweep < 0 ? -span : span, 0.02))
    }
  }

  /// Lines of the magnetic field around and through the bubble: the field the
  /// magnetometer measures, bent near the rotor by the rotor's own dipole once it's
  /// magnetised. They brighten with the Magnet knob, crowd closer as the field
  /// strengthens (line density is field strength), and carry pulses flowing along B.
  private mutating func fieldLines(
    field: F3, rotorCenter c: F3, rotorAxis axis: F3, magnet: Float, time t: Float, reduceMotion: Bool
  ) {
    let strength = simd_length(field) / 50  // Earth's field ≈ 1
    guard strength > 0.02 else { return }
    let visibility = smoothstep(0, 0.75, magnet)
    let b = field / 50
    let bHat = b / strength
    // A drawing-scale dipole: it dominates the external field within about half a
    // bubble radius of the rotor at full magnetisation.
    let dipole = magnet * 0.12
    func fieldAt(_ p: F3) -> F3 {
      let r = p - c
      let d = simd_length(r)
      guard d > 1e-3 else { return b }
      let rh = r / d
      return b + dipole * (3 * simd_dot(axis, rh) * rh - axis) / (d * d * d)
    }

    let s1 = simd_cross(bHat, abs(bHat.x) < 0.9 ? F3(1, 0, 0) : F3(0, 1, 0)).unit
    let s2 = simd_cross(bHat, s1)
    let spacing = max(0.5 / clamped(strength, 0.5, 8).squareRoot(), 0.3)
    let reach: Float = 1.6
    var seeds: [F3] = []
    var y = -reach
    var row = 0
    while y <= reach {
      var x = -reach + (row % 2 == 1 ? spacing / 2 : 0)
      while x <= reach {
        if x * x + y * y <= reach * reach { seeds.append(s1 * x + s2 * y) }
        x += spacing
      }
      y += spacing * 0.866
      row += 1
    }

    let step: Float = 0.09
    let speed = reduceMotion ? 0 : 0.35 + 0.8 * magnet
    let color = HoloPalette.fieldLine
    for seed in seeds {
      for direction: Float in [1, -1] {
        var p = seed
        var s: Float = 0
        for _ in 0..<50 {
          let k1 = fieldAt(p)
          let l1 = simd_length(k1)
          guard l1 > 1e-4 else { break }
          let k2 = fieldAt(p + k1 / l1 * (0.5 * step * direction))
          let l2 = simd_length(k2)
          guard l2 > 1e-4 else { break }
          let q = p + k2 / l2 * (step * direction)
          if simd_length(q - c) < 0.1 || simd_length(q) > 1.9 { break }
          s += step * direction
          // Pulses travel along +B; the field is brighter where it's stronger.
          let wave = 0.5 + 0.5 * cos(2 * .pi * (s / 0.5 - t * speed))
          let pulse = pow(wave, 6)
          // Dissolve into the surroundings, and never smear across the viewer's face.
          let fade = (1 - smoothstep(1.05, 1.9, simd_length(q))) * smoothstep(1.0, 2.0, simd_distance(q, view.eye))
          let boost = 0.7 + 0.3 * tanh(l2 / (2 * strength))
          let alpha = visibility * fade * boost * (0.1 + 0.6 * pulse)
          if alpha > 0.01 {
            let tint = simd_mix(color, F3(0.9, 1.0, 0.95), F3(repeating: pulse * 0.5))
            seg(p, q, tint, tint, alpha: alpha, width: 1.2)
          }
          p = q
        }
      }
    }
  }

  /// Fades a point that drifts outside the bubble or toward the viewer's eye.
  private func surroundFade(_ p: F3, from inner: Float = 1.05, to outer: Float = 2.3) -> Float {
    (1 - smoothstep(inner, outer, simd_length(p))) * smoothstep(1.0, 2.0, simd_distance(p, view.eye))
  }

  /// A circle facing the viewer.
  private mutating func billboard(
    _ center: F3, radius: (Float) -> Float, color: F3, alpha: Float, width: Float, segments: Int = 72, fade: Bool = false
  ) {
    var prev: F3?
    for i in 0...segments {
      let a = Float(i) / Float(segments) * 2 * .pi
      let p = center + (view.right * cos(a) + view.up * sin(a)) * radius(a)
      if let q = prev {
        let f = fade ? surroundFade(p) : 1
        if alpha * f > 0.01 { seg(q, p, color, color, alpha: alpha * f, width: width) }
      }
      prev = p
    }
  }

  // MARK: Audio visualiser

  private mutating func audioVisuals(
    _ a: AudioVisuals, style: VisualStyle, rotorCenter c: F3, rotorRadius r: Float, clock: Double, time t: Float
  ) {
    let n = a.bands.count
    switch style {
    case .off:
      break

    case .radial:
      // The spectrum bursts from the bubble's rim, mirrored left and right, lows at the top.
      for i in 0..<(2 * n) {
        let k = i < n ? i : 2 * n - 1 - i
        let angle = Float.pi / 2 + (Float(i) + 0.5) / Float(2 * n) * 2 * .pi
        let dir = view.right * cos(angle) + view.up * sin(angle)
        let level = a.bands[k]
        let color = HoloPalette.spectrum(Float(k) / Float(n))
        let inner: Float = 1.05
        let outer = inner + 0.03 + 0.5 * level
        seg(dir * inner, dir * outer, color * 0.5, color, alpha: 0.3 + 0.65 * level, width: 3.2)
        point(dir * (inner + 0.05 + 0.5 * a.peaks[k]), color, size: 2.4, alpha: 0.35 + 0.5 * a.peaks[k])
      }

    case .spectral:
      // A waterfall of ridge lines across the bubble's floor, newest at the front.
      var right = view.right - wz * simd_dot(view.right, wz)
      if simd_length(right) < 0.2 { right = wx }
      right = right.unit
      var toward = view.toEye - wz * simd_dot(view.toEye, wz)
      if simd_length(toward) < 0.2 { toward = simd_cross(wz, right) }
      toward = toward.unit
      let rows = a.history.count
      for (j, row) in a.history.enumerated() {
        let age = Float(rows - 1 - j) / Float(max(rows - 1, 1))
        let base = wz * -0.45 + toward * (0.55 - 1.1 * age)
        let alpha = pow(1 - age, 1.3) * 0.85
        guard alpha > 0.02 else { continue }
        var prev: F3?
        for (i, level) in row.enumerated() {
          let x = -0.78 + 1.56 * Float(i) / Float(n - 1)
          let p = base + right * x + wz * (0.34 * level)
          if let q = prev, simd_length(p) < 0.97, simd_length(q) < 0.97 {
            let color = simd_mix(HoloPalette.spectrum(Float(i) / Float(n)), F3(1, 1, 1), F3(repeating: j == rows - 1 ? 0.35 : 0))
            seg(q, p, color, color, alpha: alpha, width: j == rows - 1 ? 1.8 : 1.2)
          }
          prev = p
        }
      }

    case .music:
      // Bass, mid and treble halos around the rotor, rippling with their slice of the spectrum.
      let energies = [a.bass, a.mid, a.treble]
      let ranges = [0..<10, 10..<30, 30..<48]
      for k in 0..<3 {
        let energy = energies[k]
        let slice = Array(a.bands[ranges[k]])
        let base = r * (1.35 + 0.3 * Float(k))
        let color = HoloPalette.spectrum([0.02, 0.45, 0.85][k])
        billboard(
          c,
          radius: { angle in
            // Mirror the slice around the ring and blend between neighbouring bands.
            let span = Float(slice.count - 1)
            var x = (angle / (2 * .pi)) * 2
            if x > 1 { x = 2 - x }
            let f = min(max(x, 0), 1) * span
            let i = Int(f)
            let band = slice[i] + (slice[min(i + 1, slice.count - 1)] - slice[i]) * (f - Float(i))
            return base * (1 + 0.1 * energy * sin(angle * Float(3 + 2 * k) + t * Float(1 + k)) + 0.12 * band)
          }, color: color, alpha: 0.2 + 0.7 * energy, width: 1.6 + 2.2 * energy, segments: 96)
      }
      // A shockwave leaves the rotor on every beat.
      for shock in a.shocks {
        let age = Float(clock - shock.start)
        let radius = r * 1.2 + age * 1.5
        let alpha = (1 - age / 1.2) * shock.strength
        guard alpha > 0.02 else { continue }
        let color = HoloPalette.spectrum(shock.hue)
        billboard(c, radius: { _ in radius }, color: color, alpha: alpha, width: 2.2, fade: true)
        ring(c, wx, wy, radius: radius, color: color, width: 1.4, alpha: alpha * 0.5, segments: 72)
      }
    }
  }

  // MARK: Radio

  /// Radio emitters around the bubble, the wavefronts rolling in from them, the flowing
  /// links that carry them to the rotor, and the EMF shimmer around it. Every colour is
  /// live: spectral position, current strength and location (see `RadioColor`).
  private mutating func radioField(
    model m: GyroModel, toPhone: (V3) -> F3, rotorCenter c: F3, rotorRadius r: Float, time t: Float
  ) {
    let depth = Float(m.sound.radio)
    let visibility = smoothstep(0, 0.6, depth)
    var live: [UUID: RadioEmitter] = [:]
    for e in m.emitters {
      if let id = e.id { live[id] = e }
      let p = toPhone(e.position)
      let fade = surroundFade(p, from: 1.6, to: 2.8)
      guard fade > 0.02 else { continue }
      let color = e.color
      point(p, color, size: 3 + 4 * e.strength, alpha: visibility * fade)
      let size = 0.035 + 0.02 * e.strength
      switch e.kind {
      case .apple, .wifi, .cellular:
        billboard(p, radius: { _ in size }, color: color, alpha: 0.6 * visibility * fade, width: 1, segments: 16)
      case .other:
        // Other makers' radios get a diamond.
        billboard(p, radius: { _ in size * 1.2 }, color: color, alpha: 0.6 * visibility * fade, width: 1, segments: 4)
      }
      if e.kind == .wifi || e.kind == .cellular {
        billboard(p, radius: { _ in size * 1.8 }, color: color, alpha: 0.3 * visibility * fade, width: 1, segments: 24)
      }
      // Packets stream in toward the rotor, their colour blending into its glow.
      let link = c - p
      let dashes = 7
      for k in 0..<dashes {
        let s = (Float(k) + (t * (0.4 + 0.6 * e.strength)).truncatingRemainder(dividingBy: 1)) / Float(dashes)
        let a0 = p + link * s
        let a1 = p + link * min(s + 0.04, 1)
        let f = surroundFade(a0, from: 1.6, to: 2.8)
        let tint = simd_mix(color, HoloPalette.rotorCore * 0.8, F3(repeating: s * s))
        seg(a0, a1, tint, tint, alpha: 0.35 * visibility * f * e.strength, width: 1.2)
      }
    }
    for w in m.radioWaves {
      let radius = Float((m.clock - w.start) * GyroModel.radioWaveSpeed)
      let origin = toPhone(w.origin)
      let travel = max(simd_distance(origin, c), 0.1)
      // A spreading wave thins out: weaker, paler, dimmer as it travels. Its source's
      // current strength (if it's still heard) keeps its colour live.
      let source = w.source.flatMap { live[$0] }
      let spread = 1 / (1 + 1.5 * (radius / travel) * (radius / travel))
      let strength = (source?.strength ?? w.strength) * spread
      let color = RadioColor.of(spectral: source?.spectral ?? w.spectral, strength: strength, at: w.origin)
      let alpha = visibility * w.strength * (w.hit ? max(0, 1 - (radius - travel) / 0.5) : 0.3 + 0.5 * min(radius / travel, 1))
      guard alpha > 0.02 else { continue }
      billboard(origin, radius: { _ in radius }, color: color, alpha: alpha * 0.8, width: 1.3, segments: 96, fade: true)
    }
    // EMF: the magnetometer's flicker shimmers around the rotor, coloured by how fast it
    // flickers and how strong it is.
    let emf = Float(min(m.emf / 0.6, 1))
    if emf > 0.02 {
      let color = RadioColor.of(spectral: RadioColor.emf(hz: m.emfHz), strength: 0.35 + 0.65 * emf, at: V3(0, 0, 0.3))
      billboard(
        c,
        radius: { angle in
          r * 1.55 * (1 + 0.12 * emf * sin(angle * 23 + t * 41) * sin(angle * 7 - t * 17))
        }, color: color, alpha: 0.15 + 0.5 * emf * visibility, width: 1.2, segments: 120)
    }
  }

  // MARK: Scene

  mutating func build(model m: GyroModel, time t: Float, reduceMotion: Bool, view basis: ViewBasis) {
    lines.removeAll(keepingCapacity: true)
    view = basis
    bandY = reduceMotion ? 9 : -1.4 + 2.8 * (t / 4.2 - floor(t / 4.2))
    flicker = reduceMotion ? 1 : 1 + 0.025 * sin(t * 47) * sin(t * 13.3)

    let inverse = m.sample.attitude.inverse
    func toPhone(_ v: V3) -> F3 { inverse.act(v).f }
    let sim = m.sim
    let e = toPhone(sim.axis)
    let u = toPhone(sim.cageX)
    let v = simd_cross(e, u)
    let ell = Float(sim.offset * GyroModel.sceneScale)
    let rotorR = m.rotorRadius
    // True centre puts the pivot at the bubble's centre; harmonic centre puts the rotor's
    // centre of mass there and lets the pivot ride along the axle instead.
    let h = Float(m.centerBlend)
    let center = e * ell * (1 - h)
    let pivot = center - e * ell
    let cageR = rotorR * 1.12
    let axleHalf = rotorR * 1.25
    let sweep = Float(sim.spinSweep)
    let psi = Float(sim.spinAngle)
    let metal = m.metalGyro
    pose = GyroPose(
      center: center, u: u, v: v, e: e, pivot: pivot, rotorRadius: rotorR, cageRadius: cageR,
      axleHalf: axleHalf, ell: ell, spinAngle: psi, sweep: sweep)

    wx = toPhone(V3(1, 0, 0))
    wy = toPhone(V3(0, 1, 0))
    wz = toPhone(V3(0, 0, 1))
    var flash: (F3, Float)?
    if let f = m.radioFlash {
      flash = (f.color, Float(exp(-(m.clock - f.start) * 4)) * Float(m.sound.radio))
    }

    // The spinning object's own lines come first, so the glass orb can refract them.
    switch m.object {
    case .planet:
      // A glowing axis through the poles.
      seg(center - e * axleHalf, center + e * axleHalf, HoloPalette.axle, HoloPalette.axle, alpha: 0.5, width: 1.4)
    case .top:
      // A machined top looks still when it spins; faint streaks say otherwise.
      markers(center: center, u: u, v: v, radius: rotorR * 1.03, psi: psi, sweep: sweep, alpha: 0.3, flash: flash)
    case .wireframe, .gyroscope, .glassOrb:
      // Axle, covering the pivot whichever side the rotor sits on.
      if !metal {
        let lo = min(-ell, -axleHalf)
        let hi = max(-ell, axleHalf)
        seg(center + e * lo, center + e * hi, HoloPalette.axle, HoloPalette.axle, alpha: 0.85, width: 1.8)
        point(center + e * axleHalf, HoloPalette.axle, size: 5)
        point(center - e * axleHalf, HoloPalette.axle, size: 5)
      }

      // Rotor. In wireframe, spokes fade into a blur as the spin outruns the display; on
      // the metal only glowing edges remain.
      let edge: Float = metal ? 0.22 : 1
      let thick = rotorR * 0.12
      ring(center + e * thick, u, v, radius: rotorR, color: HoloPalette.rotor, width: 1.8, alpha: edge, segments: 72)
      ring(center - e * thick, u, v, radius: rotorR, color: HoloPalette.rotor, width: 1.8, alpha: edge, segments: 72)
      if !metal {
        ring(center, u, v, radius: rotorR * 0.62, color: HoloPalette.rotor, width: 1, alpha: 0.45, segments: 56)
        ring(center, u, v, radius: rotorR * 0.16, color: HoloPalette.rotorCore, width: 1.4, segments: 24)
        let spokeAlpha = 1 - smoothstep(0.35, 1.4, abs(sweep))
        if spokeAlpha > 0.01 {
          for k in 0..<6 {
            let a = psi + Float(k) * .pi / 3
            let d = cos(a) * u + sin(a) * v
            seg(center + d * rotorR * 0.16, center + d * rotorR, HoloPalette.rotorCore, HoloPalette.rotor, alpha: spokeAlpha, width: 1.6)
          }
        }
        let blur = 1 - spokeAlpha
        if blur > 0.01 {
          for r in stride(from: Float(0.25), through: 0.9, by: 0.13) {
            ring(center, u, v, radius: rotorR * r, color: HoloPalette.rotor, width: 1, alpha: 0.07 * blur, segments: 48)
          }
        }
      }
      markers(
        center: center, u: u, v: v, radius: metal ? rotorR * 1.01 : rotorR * 0.9, psi: psi, sweep: sweep,
        alpha: metal ? 0.7 : 1, flash: flash)

      // Cage: two meridians through the axle and an equator. It turns with the axis but
      // doesn't spin.
      let cageEdge: Float = metal ? 0.2 : 1
      ring(center, u, e, radius: cageR, color: HoloPalette.cage, width: 1.5, alpha: 0.8 * cageEdge, segments: 72)
      ring(center, v, e, radius: cageR, color: HoloPalette.cage, width: 1.5, alpha: 0.8 * cageEdge, segments: 72)
      ring(center, u, v, radius: cageR, color: HoloPalette.cage, width: 1.3, alpha: 0.55 * cageEdge, segments: 72)
    }
    objectLineCount = lines.count

    // Projector under the bubble, fixed to the phone.
    let base = F3(0, -1.07, 0)
    ring(base, F3(1, 0, 0), F3(0, 0, 1), radius: 0.42, color: HoloPalette.emitter, width: 1.4, alpha: 0.55, segments: 72)
    ring(base, F3(1, 0, 0), F3(0, 0, 1), radius: 0.26, color: HoloPalette.emitter, width: 1, alpha: 0.35, segments: 48)
    for i in 0..<8 {
      let a = Float(i) / 8 * 2 * .pi + t * 0.15
      let foot = base + 0.42 * F3(cos(a), 0, sin(a))
      let top = F3(cos(a) * 0.62, -0.79, sin(a) * 0.62)
      seg(foot, top, HoloPalette.emitter, HoloPalette.emitter, alpha: 0.28, alphaB: 0, width: 1)
    }

    // World horizon, fixed in space, with a tick toward magnetic north.
    ring(.zero, wx, wy, radius: 0.93, color: HoloPalette.horizon, width: 1, alpha: 0.22, segments: 120, dashed: true)
    for k in 0..<12 {
      let a = Float(k) * .pi / 6
      let dir = cos(a) * wx + sin(a) * wy
      seg(dir * 0.9, dir * 0.95, HoloPalette.horizon, HoloPalette.horizon, alpha: 0.35, width: 1)
    }
    let fieldWorld = m.sample.attitude.act(m.sample.magneticField)
    if hypot(fieldWorld.x, fieldWorld.y) > 5 {
      let a = Float(atan2(fieldWorld.y, fieldWorld.x))
      let dir = cos(a) * wx + sin(a) * wy
      seg(dir * 0.86, dir * 0.97, HoloPalette.north, HoloPalette.north, alpha: 0.9, width: 1.8)
      point(dir * 0.97, HoloPalette.north, size: 4, alpha: 0.9)
    }

    // Vectors: angular momentum L, the torque τ = dL/dt drawn at its tip, gravity on the
    // centre of mass, and the measured magnetic field.
    if m.showVectors {
      let lWorld = sim.momentum
      let lMag = Float(lWorld.length)
      let lDir = toPhone(lWorld.unit)
      let lLen = 0.3 + 0.45 * tanh(lMag / 0.012)
      let lTip = lDir * lLen
      arrow(from: .zero, to: lTip, color: HoloPalette.momentum, width: 2.4)
      let tau = sim.externalTorque
      let tauMag = Float(tau.length)
      if tauMag > 1e-6 {
        arrow(from: lTip, to: lTip + toPhone(tau.unit) * 0.3 * tanh(tauMag / 0.006), color: HoloPalette.torque, width: 2)
      }
      let g = sim.effectiveGravity
      let gMag = Float(g.length / GyroSim.g0)
      if gMag > 0.02, abs(ell) > 0.02 {
        arrow(from: center, to: center + toPhone(g.unit) * min(0.24 * gMag, 0.55), color: HoloPalette.gravity, width: 1.8, alpha: 0.9)
      }
      if m.params.magnet > 0.01, fieldWorld.length > 1 {
        let fLen = 0.3 + 0.35 * tanh(Float(fieldWorld.length) / 120)
        arrow(from: .zero, to: toPhone(fieldWorld.unit) * fLen, color: HoloPalette.field, width: 1.8, alpha: 0.9)
      }
    }

    if m.showFieldLines, m.params.magnet > 0.005 {
      fieldLines(
        field: m.sample.magneticField.f, rotorCenter: center, rotorAxis: e, magnet: Float(m.params.magnet), time: t,
        reduceMotion: reduceMotion)
    }

    // Trace of the axle tip: precession, with nutation loops on top.
    if m.showTrail, m.trail.count > 2 {
      let n = Float(m.trail.count)
      let tipDistance = m.object == .top ? rotorR * 1.56 : axleHalf
      let reach = ell * (1 - h) + (ell >= -0.001 ? tipDistance : -tipDistance)
      var prev: F3?
      m.trail.forEach { i, dir in
        let q = inverse.act(V3(Double(dir.x), Double(dir.y), Double(dir.z))).f * reach
        if let a = prev {
          let k = Float(i) / n
          let color = simd_mix(HoloPalette.trailTail, HoloPalette.trailHead, F3(repeating: k))
          seg(a, q, color, color, alpha: pow(k, 1.6) * 0.9, width: 1.6)
        }
        prev = q
      }
    }

    // The microphone's oscilloscope, in phosphor green with fading earlier sweeps.
    if m.scope.active {
      let traces = m.scope.history + [m.scope.trace]
      switch m.scopeStyle {
      case .off:
        break
      case .ring:
        for (k, trace) in traces.enumerated() where trace.count > 2 {
          let age = Float(traces.count - 1 - k)
          let alpha: Float = age == 0 ? 0.85 : 0.3 / (age + 0.5)
          var prev: F3?
          for (i, y) in trace.enumerated() {
            let a = Float(i) / Float(trace.count - 1) * 2 * .pi
            let p = (cos(a) * wx + sin(a) * wy) * (0.78 + 0.13 * y)
            if let q = prev { seg(q, p, HoloPalette.phosphor, HoloPalette.phosphor, alpha: alpha, width: 1.5) }
            prev = p
          }
        }
      case .trace:
        let origin = -view.up * 0.56
        let halfW: Float = 0.7
        let halfH: Float = 0.2
        let grid = HoloPalette.phosphor * 0.5
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
          let a = origin + view.right * (halfW * x) + view.up * (halfH * y)
          let b = origin + view.right * (halfW * (y == -1 ? -x : x)) + view.up * (halfH * (x == 1 ? -y : y))
          seg(a, b, grid, grid, alpha: 0.18, width: 1)
        }
        seg(origin - view.right * halfW, origin + view.right * halfW, grid, grid, alpha: 0.14, width: 1)
        for i in 1..<8 {
          let x = (Float(i) / 4 - 1) * halfW
          let c = origin + view.right * x
          seg(c - view.up * 0.03, c + view.up * 0.03, grid, grid, alpha: 0.2, width: 1)
        }
        for (k, trace) in traces.enumerated() where trace.count > 2 {
          let age = Float(traces.count - 1 - k)
          let alpha: Float = age == 0 ? 0.9 : 0.3 / (age + 0.5)
          var prev: F3?
          for (i, y) in trace.enumerated() {
            let x = (Float(i) / Float(trace.count - 1) * 2 - 1) * halfW
            let p = origin + view.right * x + view.up * (y * halfH * 0.92)
            if let q = prev { seg(q, p, HoloPalette.phosphor, HoloPalette.phosphor, alpha: alpha, width: 1.6) }
            prev = p
          }
        }
      case .xy:
        var prev: F3?
        let n = Float(max(m.scope.xy.count - 1, 1))
        for (i, xy) in m.scope.xy.enumerated() {
          let p = (wx * xy.x + wy * xy.y) * 0.62
          if let q = prev {
            seg(q, p, HoloPalette.phosphor, HoloPalette.phosphor, alpha: 0.25 + 0.65 * Float(i) / n, width: 1.4)
          }
          prev = p
        }
      }
    }

    if m.audio.active {
      audioVisuals(m.audio, style: m.visualStyle, rotorCenter: center, rotorRadius: rotorR, clock: m.clock, time: t)
    }
    if m.sound.radio > 0.005 {
      radioField(model: m, toPhone: toPhone, rotorCenter: center, rotorRadius: rotorR, time: t)
    }

    // Dust in the bubble's air.
    if m.showMotes {
      for mote in m.motes.motes {
        let tw = reduceMotion ? 0.8 : 0.55 + 0.45 * sin(t * (1 + mote.seed * 2) + mote.seed * 10)
        point(mote.p, HoloPalette.mote, size: 1.6 + mote.seed, alpha: 0.38 * tw)
      }
    }
  }
}
