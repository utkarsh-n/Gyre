import Foundation
import Observation
import QuartzCore
import SwiftUI
import simd

struct Telemetry: Equatable {
  var rpm = 0.0
  var precessionHz = 0.0
  var tiltDegrees = 0.0
  var fieldMicroTesla = 0.0
  var fieldCalibrated = false
  var pressureKPa: Double?
  var deviceRateDegrees = 0.0
  var shakeG = 0.0
  var liveSensors = false
  var soundLevel = 0.0
  var radioState: RadioSense.State = .off
  var radios = 0
  var onWiFi = false
  var cellular: String?
  var emf = 0.0
}

struct Ripple {
  var direction: F3
  var start: Double
}

/// What the microphone drives when Listen is turned up.
enum SoundTarget: Int, CaseIterable {
  case gravity, air, spin, kicks, film
}

enum ScopeStyle: Int {
  case off, ring, trace, xy
}

enum VisualStyle: Int {
  case off, radial, spectral, music
}

/// The Sound page's knobs. Stored as doubles so they share the knob machinery.
struct SoundParams: Equatable {
  var listen = 0.6  // modulation depth
  var target = 0.0  // SoundTarget
  var gain = 1.0  // microphone sensitivity
  var scope = 1.0  // ScopeStyle
  var visual = 1.0  // VisualStyle
  var radio = 0.0  // Bluetooth/Wi-Fi/EMF visibility and modulation depth
}

/// The spectrum visualiser's state: smoothed bands, their history for the waterfall, the
/// three broad bands, and beat shockwaves.
struct AudioVisuals {
  struct Shock {
    var start: Double
    var hue: Float
    var strength: Float
  }

  var bands = [Float](repeating: 0, count: Spectrum.bandCount)
  var peaks = [Float](repeating: 0, count: Spectrum.bandCount)
  var history: [[Float]] = []
  var bass: Float = 0
  var mid: Float = 0
  var treble: Float = 0
  var shocks: [Shock] = []
  var active = false
}

/// A radio emitter placed around the bubble: direction is symbolic (iOS can't tell where
/// a signal comes from), distance follows signal strength.
struct RadioEmitter {
  enum Kind { case apple, other, wifi, cellular }
  var position: V3  // physics world, scene units from the bubble's centre
  var strength: Float  // 0…1
  var kind: Kind

  var color: F3 {
    switch kind {
    case .apple: F3(0.85, 0.95, 1.0)
    case .other: F3(1.0, 0.68, 0.3)
    case .wifi: F3(0.35, 0.65, 1.0)
    case .cellular: F3(0.8, 0.45, 1.0)
    }
  }
}

/// A wavefront rolling in from an emitter toward the gyroscope.
struct RadioWave {
  var origin: V3
  var start: Double
  var strength: Float
  var color: F3
  var hit = false
}

/// The oscilloscope's latest traces, soft-limited to −1…1.
struct ScopeData {
  var trace: [Float] = []
  /// Earlier traces, oldest first, drawn fainter: phosphor persistence.
  var history: [[Float]] = []
  /// Delay-embedded pairs (x(t), x(t + 1 ms)) for the XY display.
  var xy: [SIMD2<Float>] = []
  var active = false
}

/// Owns the toy: reads the sensors, steps the physics, drives haptics and sound, and turns
/// touches into torques. The renderer calls `advance(dt:ar:)` once per display frame.
@Observable
final class GyroModel {
  var params = GyroParams()
  var sound = SoundParams()
  var showVectors = true
  var showTrail = true
  var showMotes = true
  /// Magnetic field lines around the bubble, shown once the rotor is magnetised.
  var showFieldLines = true
  /// What the spinning thing looks like.
  var object: GyroObject = .gyroscope
  var glass = GlassParams()
  /// Everything but the wireframe has a solid body.
  var metalGyro: Bool { object != .wireframe }
  /// Draw the rotor's centre of mass at the bubble's centre instead of the pivot. Purely a
  /// change of view: the physics still pivots on the ball joint.
  var harmonicCenter = false
  var soundOn = true
  var hapticsOn = true {
    didSet { haptics.enabled = hapticsOn }
  }
  var useBarometer = false {
    didSet { useBarometer ? motion.startBarometer() : motion.stopBarometer() }
  }
  var paused = false {
    didSet { sim.paused = paused }
  }
  var telemetry = Telemetry()
  var activeKnob: KnobID?
  var isRunning = false
  private(set) var micState: MicListener.State = .off

  @ObservationIgnored var reduceMotion = false
  @ObservationIgnored let motion = MotionSource()
  @ObservationIgnored let sim = GyroSim()
  @ObservationIgnored let motes = MoteField()
  @ObservationIgnored let haptics = Haptics()
  @ObservationIgnored let hum = HumSynth()
  @ObservationIgnored let mic = MicListener()
  @ObservationIgnored let ar = ARController()
  @ObservationIgnored let radio = RadioSense()
  @ObservationIgnored private let spectrum = Spectrum()
  @ObservationIgnored private(set) var audio = AudioVisuals()
  @ObservationIgnored private(set) var emitters: [RadioEmitter] = []
  @ObservationIgnored private(set) var radioWaves: [RadioWave] = []
  /// The last wave to reach the rotor: its colour flashes on the rotor's glow.
  @ObservationIgnored private(set) var radioFlash: (color: F3, start: Double)?
  @ObservationIgnored private(set) var emf = 0.0
  @ObservationIgnored private var emfMean = 0.0
  @ObservationIgnored private var emfVariance = 0.0
  @ObservationIgnored private var lastHistory = 0.0
  @ObservationIgnored private var carrierDue: [Double] = [0, 0]
  @ObservationIgnored private var radioActivity = 0.0
  @ObservationIgnored private(set) var jiggle = Jiggle()
  /// Motion of the frame that holds the pivot: the phone, or the AR bubble.
  @ObservationIgnored private(set) var sample = MotionSample.resting
  /// The viewer's frame (phone, or AR camera in portrait axes) → physics world.
  @ObservationIgnored private(set) var viewAttitude = simd_quatd.identity
  @ObservationIgnored private(set) var trail = TrailBuffer(capacity: 420)
  @ObservationIgnored private(set) var ripples: [Ripple] = []
  @ObservationIgnored private(set) var scope = ScopeData()
  /// 0…1, how strongly sound is shimmering the film this frame.
  @ObservationIgnored private(set) var filmDrive = 0.0
  /// 0 = true centre (pivot at the bubble's centre), 1 = harmonic centre; eased.
  @ObservationIgnored private(set) var centerBlend = 0.0
  @ObservationIgnored private(set) var clock = 0.0
  /// The bubble's square region in window points, published by the layout.
  @ObservationIgnored var bubbleRegion: CGRect = .zero
  /// Where the AR bubble appears on screen, in window points; set by the renderer.
  @ObservationIgnored var arScreen: (center: CGPoint, radius: CGFloat)?
  @ObservationIgnored private var lastTelemetry = 0.0
  @ObservationIgnored private var lastTrail = 0.0
  @ObservationIgnored private var nodMean = 0.0
  @ObservationIgnored private var crackleDue = 0.0
  @ObservationIgnored private var touch: TouchState?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var soundFloor = 0.0
  @ObservationIgnored private var soundEnvelope = 0.0
  @ObservationIgnored private var turbulence = V3.zero
  @ObservationIgnored private var turbulenceTarget = V3.zero
  @ObservationIgnored private var turbulenceDue = 0.0
  @ObservationIgnored private var lastRate = V3.zero
  @ObservationIgnored private var rateDot = V3.zero

  /// Distance from camera to bubble centre, in bubble radii.
  static let cameraDistance = 3.2
  /// Scene units (bubble radii) per metre: the bubble is about 17 cm across.
  static let sceneScale = 12.0

  var timeScale: Double { params.timeScale }
  /// Bubble centre and radius in window points.
  var bubbleLayout: (center: CGPoint, radius: CGFloat) {
    let r = bubbleRegion
    return (CGPoint(x: r.midX, y: r.midY), min(r.width, r.height) * 0.44)
  }
  var rotorRadius: Float { min(0.36 * Float(sim.inertiaScale.squareRoot()), 0.45) }
  var soundTarget: SoundTarget { SoundTarget(rawValue: Int(sound.target.rounded())) ?? .gravity }
  var scopeStyle: ScopeStyle { ScopeStyle(rawValue: Int(sound.scope.rounded())) ?? .ring }
  var visualStyle: VisualStyle { VisualStyle(rawValue: Int(sound.visual.rounded())) ?? .radial }

  // MARK: Lifecycle

  func start() {
    motion.start()
    haptics.start()
    if soundOn { hum.start() }
    if useBarometer { motion.startBarometer() }
    if !started {
      started = true
      relaunch(quietly: true)
      let args = ProcessInfo.processInfo.arguments
      if args.contains("-startMic") { toggleMic() }
      if args.contains("-startAR") { ar.start() }
    } else {
      ar.resume()
    }
    isRunning = true
  }

  func stop() {
    motion.stop()
    haptics.stop()
    hum.stop()
    isRunning = false
  }

  func relaunch(quietly: Bool = false) {
    sim.launch(params: params, tilt: 0.3, azimuth: Double.random(in: 0..<(2 * .pi)))
    trail.clear()
    if !quietly { haptics.spinUp() }
  }

  func apply(_ experiment: Experiment) {
    withAnimation(.smooth(duration: 0.6)) { params = experiment.params }
    sim.launch(params: experiment.params, tilt: experiment.tilt, azimuth: Double.random(in: 0..<(2 * .pi)))
    trail.clear()
    paused = false
    haptics.spinUp()
  }

  func select(_ next: GyroObject) {
    guard next != object else { return }
    object = next
    haptics.transient(intensity: 0.7, sharpness: 0.55)
  }

  func resetKnobs(on page: ConsolePage) {
    withAnimation(.smooth(duration: 0.5)) {
      switch page {
      case .physics: params = GyroParams()
      case .signals: sound = SoundParams()
      case .object: glass = GlassParams()
      }
    }
    haptics.transient(intensity: 0.6, sharpness: 0.5)
  }

  func toggleMic() {
    if micState == .on || micState == .starting {
      mic.stop()
      micState = .off
      scope = ScopeData()
      audio = AudioVisuals()
      spectrum.reset()
      soundEnvelope = 0
      filmDrive = 0
    } else {
      mic.start { [weak self] state in self?.micState = state }
    }
    haptics.transient(intensity: 0.5, sharpness: 0.6)
  }

  func toggleAR() {
    if ar.isActive {
      ar.stop()
      arScreen = nil
    } else {
      ar.start()
    }
    trail.clear()
    haptics.transient(intensity: 0.6, sharpness: 0.5)
  }

  func placeOrPickUp() {
    if ar.placed {
      ar.pickUp()
    } else {
      ar.place(at: nil, viewSize: windowSize, bubbleCenter: arScreen?.center)
    }
    haptics.transient(intensity: 0.85, sharpness: 0.35)
  }

  @ObservationIgnored var windowSize: CGSize = .zero

  // MARK: Frame

  func advance(dt: Double, ar arFrame: ARFrameState?) {
    clock += dt
    var s = motion.sample(dt: dt)
    if let f = arFrame {
      // In AR the pivot is held by the bubble: by the phone while carried, by the room
      // once placed. The phone's own sensors still tell us how it is moving.
      let camera = simd_quatf(simd_float3x3(
        SIMD3(f.cameraToWorld.columns.0.x, f.cameraToWorld.columns.0.y, f.cameraToWorld.columns.0.z),
        SIMD3(f.cameraToWorld.columns.1.x, f.cameraToWorld.columns.1.y, f.cameraToWorld.columns.1.z),
        SIMD3(f.cameraToWorld.columns.2.x, f.cameraToWorld.columns.2.y, f.cameraToWorld.columns.2.z))).normalized.double
      let bubble = f.bubbleRotation.double
      let attitude = ARController.simFromAR * bubble
      var rate = V3.zero
      var accel = V3.zero
      if f.carrying {
        // The bubble rides 45 cm ahead of the phone, so turning the phone also swings it:
        // add the lever arm's tangential and centripetal acceleration.
        rate = s.rotationRate
        rateDot += ((rate - lastRate) / max(dt, 1e-3) - rateDot) * (1 - exp(-dt / 0.05))
        lastRate = rate
        let r = V3(Double(f.carryOffset.x), Double(f.carryOffset.y), Double(f.carryOffset.z))
        let lever = simd_cross(rateDot, r) + simd_cross(rate, simd_cross(rate, r))
        accel = s.userAcceleration + lever / GyroSim.g0
      }
      let field = bubble.inverse.act(camera.act(s.magneticField))
      s = MotionSample(
        attitude: attitude, rotationRate: rate, gravity: attitude.inverse.act(V3(0, 0, -1)),
        userAcceleration: accel, magneticField: field, fieldCalibrated: s.fieldCalibrated)
      viewAttitude = ARController.simFromAR * camera
    } else {
      viewAttitude = s.attitude
    }
    sample = s
    let a = sample.attitude
    centerBlend += ((harmonicCenter ? 1 : 0) - centerBlend) * (1 - exp(-dt / 0.22))

    // Sound modulation: the microphone's envelope pushes on whichever knob it drives.
    var p = params
    var env = GyroEnvironment()
    filmDrive = 0
    if micState == .on {
      let snap = mic.snapshot(count: 2048, dt: dt)
      updateScope(snap)
      updateVisuals(snap, dt: dt)
      let m = envelope(snap, dt: dt)
      let depth = sound.listen
      switch soundTarget {
      case .gravity:
        p.gravity += depth * m * 2
      case .air:
        p.air *= 1 + 3 * depth * m
        if clock >= turbulenceDue {
          turbulenceDue = clock + 0.1
          let dir = perpendicular(to: sim.axis)
          let spin = simd_quatd(angle: Double.random(in: 0..<(2 * .pi)), axis: sim.axis)
          turbulenceTarget = spin.act(dir) * depth * m * 0.004
        }
      case .spin:
        env.extraTorque = sim.axis * (depth * m * 0.003 * (sim.spinRate < -5 ? -1 : 1))
      case .kicks:
        if snap.onset > 0, depth > 0.01 { kick(strength: depth * min(Double(snap.onset) / 5, 1)) }
      case .film:
        filmDrive = depth * m
        if snap.onset > 0, depth > 0.01 { ripple(at: randomFrontDirection(), haptic: false) }
        if !reduceMotion { jiggle.kick(randomUnit() * Float(Double(snap.bass) * sound.gain * depth * 2)) }
      }
    } else if scope.active || audio.active {
      scope = ScopeData()
      audio = AudioVisuals()
    }
    updateRadio(dt: dt)
    turbulence += ((soundTarget == .air && micState == .on ? turbulenceTarget : .zero) - turbulence) * (1 - exp(-dt / 0.08))
    env.extraTorque += turbulence

    env.deviceRate = a.act(sample.rotationRate)
    env.linearAccel = a.act(sample.userAcceleration) * GyroSim.g0
    env.magneticField = a.act(sample.magneticField) * 1e-6
    let pressureFactor = useBarometer ? (motion.pressureKPa ?? 101.325) / 101.325 : 1
    env.airDensity = p.air * pressureFactor
    sim.step(dtReal: dt, env: env, params: p)

    let simDt = paused ? 0 : Float(dt * timeScale)
    let inverse = a.inverse
    let gravityDevice = inverse.act(V3(0, 0, -1)).f * Float(p.gravity)
    let swirl = inverse.act(sim.airRate - env.deviceRate).f
    let axis = inverse.act(sim.axis).f
    motes.step(
      dt: simDt, gravity: gravityDevice, jolt: sample.userAcceleration.f,
      air: Float(env.airDensity), swirl: swirl,
      rotorCenter: axis * Float(sim.offset * Self.sceneScale * (1 - centerBlend)), rotorAxis: axis,
      rotorSpin: Float(sim.spinRate * timeScale), rotorRadius: rotorRadius)
    jiggle.step(dt: Float(dt), accel: sample.userAcceleration.f, enabled: !reduceMotion)
    ripples.removeAll { clock - $0.start > 2.5 }

    if !paused, clock - lastTrail >= 1.0 / 60 {
      lastTrail = clock
      trail.append(sim.axis.f)
    }

    updateFeedback(dt: dt, env: env)
    updateEMF(s.magneticField, dt: dt)

    if clock - lastTelemetry > 0.1 {
      lastTelemetry = clock
      telemetry = Telemetry(
        rpm: sim.rpm,
        precessionHz: sim.precessionRate / (2 * .pi),
        tiltDegrees: sim.tilt * 180 / .pi,
        fieldMicroTesla: sample.magneticField.length,
        fieldCalibrated: sample.fieldCalibrated,
        pressureKPa: motion.pressureKPa,
        deviceRateDegrees: s.rotationRate.length * 180 / .pi,
        shakeG: s.userAcceleration.length,
        liveSensors: motion.isLive,
        soundLevel: micState == .on ? soundEnvelope : 0,
        radioState: radio.state, radios: radio.devices.count, onWiFi: radio.onWiFi, cellular: radio.cellular,
        emf: emf)
    }
  }

  // MARK: Sound

  /// Loudness above the room's own noise, 0…1, with a quick attack and slower release.
  /// The floor follows the quietest recent level, so a steady background (including the
  /// rotor's own hum) settles to zero and only changes in sound move the bubble.
  private func envelope(_ snap: MicSnapshot, dt: Double) -> Double {
    let level = Double(snap.level) * sound.gain
    let db = 20 * log10(max(level, 1e-6))
    let raw = clamped((db + 55) / 45, 0, 1)
    soundFloor += (raw - soundFloor) * (1 - exp(-dt / (raw < soundFloor ? 0.4 : 20)))
    let above = max(0, raw - soundFloor - 0.04) / max(1 - soundFloor, 0.25)
    let tau = above > soundEnvelope ? 0.03 : 0.35
    soundEnvelope += (min(above * 1.5, 1) - soundEnvelope) * (1 - exp(-dt / tau))
    return soundEnvelope
  }

  /// Triggers like a real oscilloscope (on the latest rising zero crossing) so a steady
  /// tone stands still, and keeps a few earlier traces for phosphor persistence.
  private func updateScope(_ snap: MicSnapshot) {
    let s = snap.samples
    let n = s.count
    let window = 1024
    let gain = Float(sound.gain) * 5
    let hysteresis = 0.02 / gain
    var start = n - window
    var i = n - window
    while i > n - window - 900, i > 1 {
      if s[i - 1] < -hysteresis, s[i] >= 0 {
        start = i
        break
      }
      i -= 1
    }
    let points = 192
    var trace = [Float](repeating: 0, count: points)
    for k in 0..<points { trace[k] = tanh(s[start + k * window / points] * gain) }
    if !scope.trace.isEmpty {
      scope.history.append(scope.trace)
      if scope.history.count > 3 { scope.history.removeFirst() }
    }
    scope.trace = trace
    let lag = 48
    var xy: [SIMD2<Float>] = []
    xy.reserveCapacity(300)
    for k in 0..<300 {
      let j = n - 700 + k * 2
      xy.append(SIMD2(tanh(s[j] * gain), tanh(s[j + lag] * gain)))
    }
    scope.xy = xy
    scope.active = true
  }

  /// The spectrum for the visualiser, its waterfall history, and a shockwave per beat.
  private func updateVisuals(_ snap: MicSnapshot, dt: Double) {
    guard visualStyle != .off else {
      if audio.active { audio = AudioVisuals() }
      return
    }
    spectrum.update(snap.samples, gain: Float(sound.gain), dt: Float(dt))
    audio.bands = spectrum.bands
    audio.peaks = spectrum.peaks
    let b = spectrum.bands
    audio.bass = b[0..<10].reduce(0, +) / 10
    audio.mid = b[10..<30].reduce(0, +) / 20
    audio.treble = b[30..<48].reduce(0, +) / 18
    if clock - lastHistory >= 0.05 {
      lastHistory = clock
      audio.history.append(b)
      if audio.history.count > 30 { audio.history.removeFirst() }
    }
    if snap.onset > 0 {
      var weighted: Float = 0
      var total: Float = 0
      for (i, v) in b.enumerated() {
        weighted += Float(i) * v
        total += v
      }
      let centroid = total > 0 ? weighted / total / Float(b.count) : 0.3
      audio.shocks.append(.init(start: clock, hue: centroid, strength: min(snap.onset / 4, 1)))
      if audio.shocks.count > 6 { audio.shocks.removeFirst() }
      if visualStyle == .music { ripple(at: randomFrontDirection(), haptic: false) }
    }
    audio.shocks.removeAll { clock - $0.start > 1.2 }
    audio.active = true
  }

  // MARK: Radio

  /// Radios become emitters around the bubble; each packet sends a wave in, and each wave
  /// that reaches the rotor nudges it, flashes it and ticks the hum and the haptics.
  private func updateRadio(dt: Double) {
    let depth = sound.radio
    guard depth > 0.005 else {
      if radio.state != .off {
        radio.stop()
        emitters = []
        radioWaves = []
      }
      return
    }
    if radio.state == .off { radio.start() }
    radio.tick(clock)

    func place(_ id: UUID, rssi: Double) -> V3 {
      let u = id.uuid
      let azimuth = (Double(u.0) * 256 + Double(u.1)) / 65536 * 2 * .pi
      let elevation = -0.25 + 0.75 * Double(u.2) / 255
      let distance = 1.25 + clamped((-rssi - 40) / 45, 0, 1)
      return V3(cos(elevation) * cos(azimuth), cos(elevation) * sin(azimuth), sin(elevation)) * distance
    }
    func strength(_ rssi: Double) -> Float { Float(clamped((rssi + 100) / 60, 0.05, 1)) }

    var next: [RadioEmitter] = radio.devices.values.map {
      RadioEmitter(position: place($0.id, rssi: $0.rssi), strength: strength($0.rssi), kind: $0.apple ? .apple : .other)
    }
    let wifi = RadioEmitter(position: V3(0.62, 0.55, 0.35).unit * 2.1, strength: 0.6, kind: .wifi)
    let cell = RadioEmitter(position: V3(-0.8, -0.3, 0.5).unit * 2.4, strength: 0.45, kind: .cellular)
    if radio.onWiFi { next.append(wifi) }
    if radio.cellular != nil { next.append(cell) }
    emitters = next

    for (id, rssi) in radio.drainPulses() {
      let kind: RadioEmitter.Kind = radio.devices[id]?.apple == true ? .apple : .other
      let e = RadioEmitter(position: place(id, rssi: rssi), strength: strength(rssi), kind: kind)
      radioWaves.append(RadioWave(origin: e.position, start: clock, strength: e.strength, color: e.color))
    }
    // The connections the phone is using pulse steadily.
    for (i, carrier) in [(radio.onWiFi, wifi, 1.7), (radio.cellular != nil, cell, 2.6)].enumerated()
    where carrier.0 && clock >= carrierDue[i] {
      carrierDue[i] = clock + carrier.2
      radioWaves.append(RadioWave(origin: carrier.1.position, start: clock, strength: carrier.1.strength, color: carrier.1.color))
    }
    if radioWaves.count > 24 { radioWaves.removeFirst(radioWaves.count - 24) }

    let rotor = sim.axis * sim.offset * Self.sceneScale * (1 - centerBlend)
    radioActivity *= exp(-dt / 0.6)
    for i in radioWaves.indices where !radioWaves[i].hit {
      let w = radioWaves[i]
      let reach = (clock - w.start) * Self.radioWaveSpeed
      if reach >= simd_length(w.origin - rotor) {
        radioWaves[i].hit = true
        let dir = (rotor - w.origin).unit
        // A few percent of the rotor's angular momentum: a shiver and a nod, not a knockout.
        let push = Double(w.strength) * depth * clamped(0.035 * sim.momentum.length, 0.00008, 0.0006)
        sim.applyImpulse(simd_cross(sim.axis, dir).unit * push)
        radioFlash = (w.color, clock)
        radioActivity = min(radioActivity + Double(w.strength) * 0.5, 2)
        haptics.transient(intensity: Float(0.15 + 0.3 * depth) * w.strength, sharpness: 0.95, minGap: 0.1)
      }
    }
    radioWaves.removeAll { w in (clock - w.start) * Self.radioWaveSpeed > simd_length(w.origin - rotor) + 0.5 }
  }

  /// Wavefronts travel at this many bubble radii per second.
  static let radioWaveSpeed = 1.2

  /// Electromagnetic activity: how much the magnetometer's reading flickers around its
  /// recent mean, in µT. Chargers, laptops and mains wiring raise it.
  private func updateEMF(_ field: V3, dt: Double) {
    let magnitude = field.length
    emfMean += (magnitude - emfMean) * (1 - exp(-dt / 0.5))
    let deviation = magnitude - emfMean
    emfVariance += (deviation * deviation - emfVariance) * (1 - exp(-dt / 0.4))
    emf = emfVariance.squareRoot()
  }

  /// A beat or a clap knocks the rotor sideways, scaled to its angular momentum.
  private func kick(strength: Double) {
    let dir = simd_quatd(angle: Double.random(in: 0..<(2 * .pi)), axis: sim.axis).act(perpendicular(to: sim.axis))
    sim.applyImpulse(dir * strength * clamped(0.4 * sim.momentum.length, 0.0008, 0.0065))
    ripple(at: randomFrontDirection(), haptic: true)
    mic.ignoreOnsets(for: 0.2)
  }

  private func randomUnit() -> F3 {
    F3(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)).unit
  }

  /// A point on the side of the bubble facing the viewer, in the bubble frame.
  private func randomFrontDirection() -> F3 {
    let v = V3(Double.random(in: -0.6...0.6), Double.random(in: -0.6...0.6), 0.8).unit
    return sample.attitude.inverse.act(viewAttitude.act(v)).f
  }

  private func ripple(at direction: F3, haptic: Bool) {
    ripples.append(Ripple(direction: direction, start: clock))
    if ripples.count > 4 { ripples.removeFirst() }
    if haptic { haptics.transient(intensity: 0.75, sharpness: 0.5) }
  }

  // MARK: Feedback

  private func updateFeedback(dt: Double, env: GyroEnvironment) {
    let apparentSpin = paused ? 0 : abs(sim.spinRate) * timeScale
    let revs = apparentSpin / (2 * .pi)
    let spinNorm = min(revs / 150, 1)
    // What you'd feel turning a real spinning gyroscope: the torque needed to swing its
    // angular momentum around with the phone.
    let strain = paused ? 0 : min(simd_length(simd_cross(env.deviceRate, sim.momentum)) / 0.03, 1)
    // Nutation shows up as the axis speed pulsing around its running mean.
    let speed = sim.axisSpeed * timeScale
    nodMean += (speed - nodMean) * (1 - exp(-dt / 0.8))
    let nod = clamped((speed - nodMean) / max(nodMean, 0.3), -0.7, 0.7)

    var intensity = spinNorm > 0.003 ? 0.1 + 0.34 * spinNorm.squareRoot() : 0
    intensity = intensity * (1 + 0.6 * nod) + 0.55 * strain
    // A placed AR bubble isn't in your hand, so it hums only faintly.
    if ar.isActive, ar.placed { intensity *= 0.35 }
    haptics.updateHum(
      intensity: Float(intensity), sharpness: Float(0.12 + 0.65 * spinNorm + 0.2 * strain))

    let c = hum.controls
    c.rotorHz = revs
    c.level = soundOn ? min(1, pow(spinNorm, 0.6) * 1.15) : 0
    c.hiss = soundOn ? params.friction * spinNorm.squareRoot() * 0.4 + strain * 0.15 : 0
    c.whoosh = soundOn ? min(env.airDensity, 3) * spinNorm * 0.5 : 0
    c.wobble = abs(nod) * 0.5
    c.vibrato = sound.radio * min(radioActivity, 1) * 0.02
    c.wobbleHz = abs(sim.precessionRate * timeScale) / (2 * .pi) * 2 + 1.5
    let rotorX = viewAttitude.inverse.act(sim.axis).x * sim.offset * Self.sceneScale
    c.pan = clamped(rotorX * 1.6, -0.8, 0.8)
    if soundOn, !hum.running, isRunning { hum.start() }

    // A magnet near the phone crackles in your hand, faster the stronger the field.
    let field = sample.magneticField.length
    if params.magnet > 0.01, field > 120, clock >= crackleDue {
      let rate = min((field - 100) / 30, 30)
      crackleDue = clock + Double.random(in: 0.3...1.7) / rate
      haptics.transient(intensity: Float(0.35 + 0.4 * params.magnet), sharpness: 1)
    }
  }

  // MARK: Touch

  private struct TouchState {
    var last: CGPoint
    var lastTime: Double
    var startTime: Double
    var travel: CGFloat
    var tilting: Bool
  }

  @ObservationIgnored var pinching = false

  /// Converts a point in the bubble region's local space to the bubble's plane as seen by
  /// the viewer, in bubble radii with +y up.
  private func bubblePoint(_ p: CGPoint, in size: CGSize) -> SIMD2<Double> {
    if ar.isActive {
      guard let s = arScreen, s.radius > 1 else { return SIMD2(9, 9) }
      let x = Double(bubbleRegion.minX + p.x - s.center.x) / Double(s.radius)
      let y = -Double(bubbleRegion.minY + p.y - s.center.y) / Double(s.radius)
      return SIMD2(x, y)
    }
    let r = Double(min(size.width, size.height) * 0.44)
    let k = Self.cameraDistance / (Self.cameraDistance * Self.cameraDistance - 1).squareRoot()
    return SIMD2((Double(p.x) - Double(size.width) / 2) / r * k, -(Double(p.y) - Double(size.height) / 2) / r * k)
  }

  func touchChanged(at location: CGPoint, in size: CGSize) {
    guard !pinching else { return }
    let now = clock
    guard var t = touch else {
      let p = bubblePoint(location, in: size)
      let outside = simd_length(p) > 1.0
      touch = TouchState(last: location, lastTime: now, startTime: now, travel: 0, tilting: !motion.isLive && outside)
      return
    }
    let dx = location.x - t.last.x
    let dy = location.y - t.last.y
    t.travel += hypot(dx, dy)
    let dt = max(now - t.lastTime, 1.0 / 240)
    if t.tilting {
      motion.simYaw -= Double(dx) * 0.008
      motion.simPitch = clamped(motion.simPitch - Double(dy) * 0.008, -0.2, .pi - 0.2)
    } else if t.travel > 8 {
      stringPull(from: t.last, to: location, dt: dt, in: size)
    }
    t.last = location
    t.lastTime = now
    touch = t
  }

  func touchEnded(at location: CGPoint, in size: CGSize) {
    defer { touch = nil }
    guard !pinching, let t = touch, !t.tilting || ar.isActive, t.travel <= 8, clock - t.startTime < 0.4 else { return }
    let p = bubblePoint(location, in: size)
    if ar.isActive, simd_length(p) > 1.15 {
      // Tapping the room while carrying sets the bubble down there.
      if !ar.placed {
        let point = CGPoint(x: bubbleRegion.minX + location.x, y: bubbleRegion.minY + location.y)
        ar.place(at: point, viewSize: windowSize, bubbleCenter: arScreen?.center)
        haptics.transient(intensity: 0.85, sharpness: 0.35)
      }
      return
    }
    flick(at: p)
  }

  /// A finger dragged across the rotor's rim adds spin along the axis: torque r × F.
  private func stringPull(from a: CGPoint, to b: CGPoint, dt: Double, in size: CGSize) {
    let p0 = bubblePoint(a, in: size)
    let p1 = bubblePoint(b, in: size)
    guard simd_length(p1) < 1.6 else { return }
    let axis = viewAttitude.inverse.act(sim.axis)
    let center = axis * sim.offset * Self.sceneScale * (1 - centerBlend)
    let r = V3(p1.x - center.x, p1.y - center.y, 0.45)
    let d = V3(p1.x - p0.x, p1.y - p0.y, 0)
    let speed = simd_length(d) / dt
    let gain = clamped(speed / 2.5, 0.35, 2.5)
    let dL = simd_dot(simd_cross(r, d), axis) * 0.012 * gain
    sim.addSpin(dL)
    if abs(dL) > 1e-5 {
      haptics.transient(
        intensity: Float(clamped(abs(dL) / 0.0015, 0.15, 0.85)), sharpness: 0.75, minGap: 0.03)
    }
  }

  /// A tap pokes the rotor: the finger pushes into the screen at that point, a torque
  /// impulse that knocks the axis into nutation. Its size follows the rotor's angular
  /// momentum, so a fast rotor nods visibly and a slow one rocks rather than tumbling.
  private func flick(at p: SIMD2<Double>) {
    guard simd_length(p) < 1.1 else { return }
    let r = V3(p.x, p.y, 0.4)
    let push = clamped(0.45 * sim.momentum.length, 0.0008, 0.0065)
    let impulse = simd_cross(r, V3(0, 0, -push))
    sim.applyImpulse(viewAttitude.act(impulse))
    let z = max(0, 1 - simd_length_squared(p)).squareRoot()
    let dir = sample.attitude.inverse.act(viewAttitude.act(V3(p.x, p.y, z).unit))
    ripple(at: dir.f, haptic: false)
    haptics.transient(intensity: 0.9, sharpness: 0.45)
    mic.ignoreOnsets(for: 0.2)
  }
}
