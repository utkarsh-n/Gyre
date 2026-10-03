import SwiftUI

enum KnobID: String, CaseIterable, Identifiable {
  case motor, inertia, gravity, balance, friction, air, magnet, time
  case listen, drives, gain, scope, visual, radio
  case frost, dispersion, refraction
  var id: String { rawValue }
}

/// What the spinning thing looks like. The physics is always the gyroscope's rotor; the
/// object is a skin over it.
enum GyroObject: Int, CaseIterable, Identifiable {
  case wireframe, gyroscope, glassOrb, top, planet
  var id: Int { rawValue }

  var title: String {
    switch self {
    case .wireframe: "Wireframe"
    case .gyroscope: "Gyroscope"
    case .glassOrb: "Glass orb"
    case .top: "Top"
    case .planet: "Planet"
    }
  }

  var symbol: String {
    switch self {
    case .wireframe: "cube.transparent"
    case .gyroscope: "gyroscope"
    case .glassOrb: "bubbles.and.sparkles"
    case .top: "cone.fill"
    case .planet: "circle.and.line.horizontal"
    }
  }

  var subtitle: String {
    switch self {
    case .wireframe: "The hologram alone: rotor, cage and axle drawn in light."
    case .gyroscope: "Turned, brushed, anodised holo-metal that reflects its surroundings."
    case .glassOrb: "The gyroscope sealed in an abraded glass orb that turns with it."
    case .top: "A machined titanium top, Inception-style, brushed on the lathe. Does it ever fall?"
    case .planet: "A ringed gas giant whose axis precesses, as Earth's does every 26,000 years."
    }
  }
}

/// The glass orb's knobs.
struct GlassParams: Equatable {
  var frost = 0.45
  var dispersion = 0.5
  var refraction = 0.5
}

struct KnobDetent: Hashable {
  let value: Double
  let label: String
}

/// A knob's range, mapping, detents and words.
struct KnobSpec: Identifiable {
  let id: KnobID
  let title: String
  let symbol: String
  let tint: Color
  let range: ClosedRange<Double>
  let defaultValue: Double
  var logarithmic = false
  /// Where the value arc starts; bipolar knobs light up from their zero.
  var origin: Double? = nil
  var detents: [KnobDetent] = []
  /// Values snap to this step while dragging.
  var step: Double = 0
  let hint: String
  let detail: String
  let keyPath: ReferenceWritableKeyPath<GyroModel, Double>
  let format: (Double) -> String

  /// A rotary switch: whole-number positions, each a named detent.
  var isSwitch: Bool { step >= 1 }

  func position(of value: Double) -> Double {
    let v = clamped(value, range.lowerBound, range.upperBound)
    if logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
    return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  func value(at position: Double) -> Double {
    let p = clamped(position, 0, 1)
    var v =
      logarithmic
      ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
      : range.lowerBound + p * (range.upperBound - range.lowerBound)
    if step > 0 { v = (v / step).rounded() * step }
    return clamped(v, range.lowerBound, range.upperBound)
  }

  var originPosition: Double { position(of: origin ?? range.lowerBound) }

  func detent(at value: Double) -> KnobDetent? {
    detents.first { abs(position(of: $0.value) - position(of: value)) < 0.004 }
  }

  static func spec(_ id: KnobID) -> KnobSpec { (physics + sound + glass).first { $0.id == id }! }

  static let physics: [KnobSpec] = [
    KnobSpec(
      id: .motor, title: "Motor", symbol: "fanblades.fill", tint: Color(red: 0.36, green: 0.86, blue: 1.0),
      range: 0...12000, defaultValue: 3000, detents: [KnobDetent(value: 0, label: "Off · coasting")], step: 50,
      hint: "Spin the motor holds the rotor at. Off lets it coast, slow down and eventually topple.",
      detail:
        "A governor on the rotor's axle. It pushes the spin toward the set speed with limited torque, so a heavier rotor takes longer to come up to speed. At Off, air and bearing friction wind the rotor down until it can no longer stay upright.",
      keyPath: \.params.motorRPM,
      format: { $0 < 1 ? "Off" : "\(Int($0).formatted()) rpm" }),
    KnobSpec(
      id: .inertia, title: "Inertia", symbol: "circle.circle.fill", tint: Color(red: 0.30, green: 1.0, blue: 0.82),
      range: 0.25...3, defaultValue: 1, logarithmic: true, detents: [KnobDetent(value: 1, label: "Brass disc")],
      hint: "Moment of inertia. More of it means more angular momentum, a stiffer axis and slower precession.",
      detail:
        "Moves mass toward the rotor's rim. With the motor on, more inertia means more angular momentum at the same speed, so the axis is stiffer and precesses more slowly. With the motor off, angular momentum is conserved, so adding inertia slows the spin, like a skater opening their arms.",
      keyPath: \.params.inertia,
      format: { String(format: "×%.2f", $0) }),
    KnobSpec(
      id: .gravity, title: "Gravity", symbol: "arrow.down.to.line", tint: Color(red: 1.0, green: 0.70, blue: 0.28),
      range: -1...3, defaultValue: 1, origin: 0,
      detents: [
        KnobDetent(value: -1, label: "Inverted"), KnobDetent(value: 0, label: "Zero-g"),
        KnobDetent(value: 0.166, label: "Moon"), KnobDetent(value: 0.38, label: "Mars"),
        KnobDetent(value: 1, label: "Earth"), KnobDetent(value: 2.53, label: "Jupiter"),
      ], step: 0.01,
      hint: "Local gravity inside the bubble. Its direction is real: it's measured by your phone's accelerometer.",
      detail:
        "Scales the gravity your accelerometer measures. Gravity pulls on the off-centre rotor and the resulting torque swings the angular momentum sideways: precession. Stronger gravity, faster precession. Zero-g leaves only the gyroscope's inertia. Negative gravity turns everything upside down.",
      keyPath: \.params.gravity,
      format: { String(format: "%.2f g", $0) }),
    KnobSpec(
      id: .balance, title: "Balance", symbol: "arrow.up.and.down", tint: Color(red: 1.0, green: 0.45, blue: 0.62),
      range: -1...1, defaultValue: 0.5, origin: 0,
      detents: [
        KnobDetent(value: -1, label: "Hanging"), KnobDetent(value: 0, label: "Balanced · free gyro"),
        KnobDetent(value: 1, label: "Top-heavy"),
      ], step: 0.01,
      hint: "Slides the rotor along its axle. Off-centre mass gives gravity a lever arm.",
      detail:
        "The distance between the pivot and the rotor's centre of mass. Balanced, gravity has no lever and the axis stays fixed in space however you turn the phone. Above the pivot, it's a spinning top; below it, a hanging gyroscope that precesses the other way.",
      keyPath: \.params.balance,
      format: { String(format: "%+.1f cm", $0 * 3.5) }),
    KnobSpec(
      id: .friction, title: "Friction", symbol: "flame.fill", tint: Color(red: 1.0, green: 0.50, blue: 0.30),
      range: 0...1, defaultValue: 0.25, step: 0.01,
      hint: "Pivot and bearing friction. It couples the rotor to the phone and damps the wobble.",
      detail:
        "Friction in the pivot is held by the phone, so it slowly drags the rotor along as you turn. It also damps nutation and bleeds spin from the bearing. At zero the rotor ignores the phone almost completely.",
      keyPath: \.params.friction,
      format: { "\(Int(($0 * 100).rounded()))%" }),
    KnobSpec(
      id: .air, title: "Air", symbol: "wind", tint: Color(red: 0.55, green: 0.75, blue: 1.0),
      range: 0...3, defaultValue: 1,
      detents: [KnobDetent(value: 0, label: "Vacuum"), KnobDetent(value: 1, label: "Sea level")], step: 0.01,
      hint: "Air density in the bubble: drag on the spin, the swing, and the dust.",
      detail:
        "Drag on the spinning rotor and on its swinging, and the medium the dust floats in. The air inside lags when you turn the phone, so dust swirls backwards. In a vacuum the rotor coasts for much longer and the dust falls freely. Turn on Live air pressure to scale it by your barometer.",
      keyPath: \.params.air,
      format: { $0 < 0.005 ? "Vacuum" : String(format: "×%.2f", $0) }),
    KnobSpec(
      id: .magnet, title: "Magnet", symbol: "location.north.line.fill", tint: Color(red: 0.55, green: 1.0, blue: 0.45),
      range: 0...1, defaultValue: 0, detents: [KnobDetent(value: 0, label: "Off")], step: 0.01,
      hint: "Magnetises the rotor and reveals the field lines around it. It precesses around the real field your phone measures.",
      detail:
        "Gives the rotor a magnetic moment along its axle. The magnetometer's field exerts a torque, and a spinning rotor answers by precessing around the field, the same Larmor precession behind MRI. Earth's field gives a slow drift around north. Bring a magnet near the phone and it whips around, and you'll feel the field crackle. The field lines around the bubble show that field: they brighten as you turn this up, bend around the magnetised rotor, crowd together where the field is stronger, and pulse in the direction the field points.",
      keyPath: \.params.magnet,
      format: { $0 < 0.005 ? "Off" : "\(Int(($0 * 100).rounded()))%" }),
    KnobSpec(
      id: .time, title: "Time", symbol: "hourglass", tint: Color(red: 0.72, green: 0.55, blue: 1.0),
      range: 0.05...2, defaultValue: 1, logarithmic: true,
      detents: [KnobDetent(value: 0.25, label: "Slow motion"), KnobDetent(value: 1, label: "Real time")],
      hint: "Simulation speed. Slow it down to see nutation, the nodding on top of precession.",
      detail:
        "Runs the bubble's clock slower or faster than yours. In slow motion a fast top's nutation becomes visible: the axle tip traces loops or cusps on top of its slow precession. The hum and the haptics slow down with it.",
      keyPath: \.params.timeScale,
      format: { String(format: "%.2f×", $0) }),
  ]
}

extension KnobSpec {
  private static func label(_ names: [String]) -> (Double) -> String {
    { names[Int(clamped($0.rounded(), 0, Double(names.count - 1)))] }
  }

  static let sound: [KnobSpec] = [
    KnobSpec(
      id: .listen, title: "Listen", symbol: "ear.fill", tint: Color(red: 0.35, green: 1.0, blue: 0.6),
      range: 0...1, defaultValue: 0.6, detents: [KnobDetent(value: 0, label: "Scope only")], step: 0.01,
      hint: "Modulation depth: how hard sound pushes on the bubble. At zero the scope only watches.",
      detail:
        "How strongly the microphone modulates the bubble. Gyre follows how loud the room is above its own background noise, so a steady hum fades out and only changes (voices, claps, music) push. At zero the oscilloscope still draws but nothing moves.",
      keyPath: \.sound.listen,
      format: { $0 < 0.005 ? "Off" : "\(Int(($0 * 100).rounded()))%" }),
    KnobSpec(
      id: .drives, title: "Drives", symbol: "slider.horizontal.3", tint: Color(red: 1.0, green: 0.62, blue: 0.85),
      range: 0...4, defaultValue: 0,
      detents: [
        KnobDetent(value: 0, label: "Gravity"), KnobDetent(value: 1, label: "Air"), KnobDetent(value: 2, label: "Spin"),
        KnobDetent(value: 3, label: "Kicks"), KnobDetent(value: 4, label: "Film"),
      ], step: 1,
      hint: "What sound modulates: gravity, air turbulence, spin, beat kicks, or the bubble's film.",
      detail:
        "A rotary switch choosing the modulation's destination. Gravity: loudness adds up to 2 g, so singing speeds the precession. Air: sound thickens the air and stirs it into gusts that buffet the rotor. Spin: sound pushes the rotor like wind on a pinwheel, so you can shout it up to speed. Kicks: claps and beats knock the rotor into a nod. Film: the bubble shivers and ripples with the sound.",
      keyPath: \.sound.target,
      format: label(["Gravity", "Air", "Spin", "Kicks", "Film"])),
    KnobSpec(
      id: .gain, title: "Gain", symbol: "mic.fill", tint: Color(red: 0.45, green: 0.85, blue: 1.0),
      range: 0.25...8, defaultValue: 1, logarithmic: true, detents: [KnobDetent(value: 1, label: "Unity")],
      hint: "Microphone sensitivity for the scope and the modulation.",
      detail: "Amplifies the microphone before the scope and the modulation see it. Turn it up for a quiet room, down for music.",
      keyPath: \.sound.gain,
      format: { String(format: "×%.2g", $0) }),
    KnobSpec(
      id: .scope, title: "Scope", symbol: "waveform.path.ecg", tint: Color(red: 0.4, green: 1.0, blue: 0.55),
      range: 0...3, defaultValue: 1,
      detents: [
        KnobDetent(value: 0, label: "Off"), KnobDetent(value: 1, label: "Ring"), KnobDetent(value: 2, label: "Trace"),
        KnobDetent(value: 3, label: "XY"),
      ], step: 1,
      hint: "Oscilloscope display: a ring around the horizon, a classic trace, or an XY figure.",
      detail:
        "How the microphone is drawn. Ring wraps the waveform around the world's horizon. Trace is a classic triggered oscilloscope, so steady tones stand still. XY plots the signal against itself a millisecond later, which turns tones into loops and Lissajous figures.",
      keyPath: \.sound.scope,
      format: label(["Off", "Ring", "Trace", "XY"])),
    KnobSpec(
      id: .visual, title: "Visual", symbol: "chart.bar.xaxis", tint: Color(red: 1.0, green: 0.55, blue: 0.4),
      range: 0...3, defaultValue: 1,
      detents: [
        KnobDetent(value: 0, label: "Off"), KnobDetent(value: 1, label: "Radial"),
        KnobDetent(value: 2, label: "Spectral"), KnobDetent(value: 3, label: "Music"),
      ], step: 1,
      hint: "Spectrum visualiser: a radial halo, a spectral waterfall, or music-reactive rings and beat shockwaves.",
      detail:
        "A rotary switch for the microphone's spectrum (a 2048-point FFT in 48 bands from 45 Hz to 15 kHz). Radial bursts the spectrum from the bubble's rim, low notes at the top. Spectral draws a waterfall of ridge lines across the bubble's floor, the newest at the front. Music rings the rotor with bass, mid and treble halos and sends a shockwave out from it on every beat.",
      keyPath: \.sound.visual,
      format: label(["Off", "Radial", "Spectral", "Music"])),
    KnobSpec(
      id: .radio, title: "Radio", symbol: "antenna.radiowaves.left.and.right", tint: Color(red: 0.45, green: 0.7, blue: 1.0),
      range: 0...1, defaultValue: 0, detents: [KnobDetent(value: 0, label: "Off")], step: 0.01,
      hint: "Shows the radio around you (Bluetooth, Wi-Fi, cellular, EMF) and lets its waves nudge the gyroscope.",
      detail:
        "Turns on Gyre's radio ears. Nearby Bluetooth LE radios become emitters around the bubble: closer for a stronger signal, white for Apple devices, amber for others. iOS doesn't say where a signal comes from, so their directions are symbolic. The Wi-Fi and cellular links the phone is using pulse steadily in blue and violet; apps can't scan Wi-Fi or read its strength. Each packet sends a wavefront in. When one reaches the gyroscope it nudges the rotor, flashes it in the emitter's colour, and wobbles the hum's pitch. The flicker in the magnetometer (EMF from chargers, laptops, wiring) shimmers around the rotor. Turn it up for more of everything.",
      keyPath: \.sound.radio,
      format: { $0 < 0.005 ? "Off" : "\(Int(($0 * 100).rounded()))%" }),
  ]
}

extension KnobSpec {
  static let glass: [KnobSpec] = [
    KnobSpec(
      id: .frost, title: "Frost", symbol: "snowflake", tint: Color(red: 0.8, green: 0.9, blue: 1.0),
      range: 0...1, defaultValue: 0.45, detents: [KnobDetent(value: 0, label: "Polished")], step: 0.01,
      hint: "The abraded layer on the orb: scratches and scuffs that scatter what's inside into frost.",
      detail:
        "How worn the orb's outer skin is. Fine frost, scuffed patches and curved scratches scatter the light passing through, blurring the gyroscope where they cross it. The marks are fixed to the orb, so you can watch them turn as the gyroscope precesses and nods.",
      keyPath: \.glass.frost,
      format: { "\(Int(($0 * 100).rounded()))%" }),
    KnobSpec(
      id: .dispersion, title: "Dispersion", symbol: "lightspectrum.horizontal",
      tint: Color(red: 1.0, green: 0.55, blue: 0.85),
      range: 0...1, defaultValue: 0.5, detents: [KnobDetent(value: 0, label: "None")], step: 0.01,
      hint: "Chromatic aberration: red, green and blue bend by different amounts and fringe apart.",
      detail:
        "Glass bends blue light more than red. Turn this up and everything seen through the orb, above all near its rim, splits into rainbow fringes that slide as the gyroscope moves inside.",
      keyPath: \.glass.dispersion,
      format: { "\(Int(($0 * 100).rounded()))%" }),
    KnobSpec(
      id: .refraction, title: "Refraction", symbol: "eyeglasses", tint: Color(red: 0.5, green: 0.85, blue: 1.0),
      range: 0...1, defaultValue: 0.5, detents: [KnobDetent(value: 0, label: "Thin glass")], step: 0.01,
      hint: "How thick the orb's shell is: how strongly it lenses the gyroscope behind it.",
      detail:
        "A thick glass shell bends light most near its rim, where you look through the most glass. At zero it's a thin bubble of glass that barely bends anything.",
      keyPath: \.glass.refraction,
      format: { "\(Int(($0 * 100).rounded()))%" }),
  ]
}

/// A preset tuning of the knobs that shows off one behaviour.
struct Experiment: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let symbol: String
  var params: GyroParams
  var tilt = 0.3

  static let all: [Experiment] = {
    var top = GyroParams()

    var free = GyroParams()
    free.balance = 0
    free.motorRPM = 6000
    free.friction = 0.05
    free.air = 0.5

    var moon = GyroParams()
    moon.gravity = 0.166
    moon.balance = 0.8
    moon.motorRPM = 2500

    var jupiter = GyroParams()
    jupiter.gravity = 2.53
    jupiter.balance = 0.6
    jupiter.motorRPM = 3500

    var hanging = GyroParams()
    hanging.balance = -0.7
    hanging.motorRPM = 3000

    var larmor = GyroParams()
    larmor.balance = 0
    larmor.magnet = 1
    larmor.friction = 0.03
    larmor.air = 0
    larmor.motorRPM = 1500

    var slow = GyroParams()
    slow.timeScale = 0.15
    slow.motorRPM = 1800
    slow.friction = 0.05
    slow.air = 0.3
    slow.balance = 0.7

    var windDown = GyroParams()
    windDown.motorRPM = 0
    windDown.air = 2
    windDown.friction = 0.4

    var zeroG = GyroParams()
    zeroG.gravity = 0
    zeroG.motorRPM = 3000

    return [
      Experiment(id: "top", title: "Spinning top", subtitle: "Precesses around real gravity", symbol: "rotate.3d", params: top),
      Experiment(id: "free", title: "Free gyroscope", subtitle: "Turn the phone; the axis stays put in space", symbol: "gyroscope", params: free, tilt: 0.8),
      Experiment(id: "moon", title: "On the Moon", subtitle: "One-sixth gravity, lazy precession", symbol: "moon.fill", params: moon),
      Experiment(id: "jupiter", title: "On Jupiter", subtitle: "2.5 g: fast precession, deep nods", symbol: "globe.americas.fill", params: jupiter, tilt: 0.6),
      Experiment(id: "hanging", title: "Hanging gyro", subtitle: "Below the pivot it precesses backwards", symbol: "arrow.down.circle", params: hanging, tilt: 2.4),
      Experiment(id: "larmor", title: "Magnetic compass", subtitle: "Precesses around Earth's field. Try a magnet", symbol: "location.north.line.fill", params: larmor, tilt: 1.0),
      Experiment(id: "slow", title: "Slow motion", subtitle: "Tap the bubble and watch it nod", symbol: "tortoise.fill", params: slow, tilt: 0.5),
      Experiment(id: "wind", title: "Wind-down", subtitle: "No motor: it slows, wobbles and falls", symbol: "wind", params: windDown),
      Experiment(id: "zero", title: "Zero-g", subtitle: "Dust floats; only inertia remains", symbol: "sparkles", params: zeroG, tilt: 0.7),
    ]
  }()
}
