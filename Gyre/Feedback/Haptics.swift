import CoreHaptics
import Foundation
import QuartzCore

/// Core Haptics for the toy: a continuous hum you feel in your palm whose strength and
/// sharpness follow the rotor, plus transients for knob detents, flicks and string pulls.
final class Haptics {
  private var engine: CHHapticEngine?
  private var hum: CHHapticAdvancedPatternPlayer?
  private var humRunning = false
  private var lastSend: CFTimeInterval = 0
  private var lastTransient: CFTimeInterval = 0
  let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
  var enabled = true {
    didSet { if !enabled { stopHum() } }
  }

  func start() {
    guard supported else { return }
    if engine == nil {
      guard let e = try? CHHapticEngine() else { return }
      e.playsHapticsOnly = true
      e.isAutoShutdownEnabled = false
      e.resetHandler = { [weak self] in
        DispatchQueue.main.async { self?.recover() }
      }
      e.stoppedHandler = { [weak self] _ in
        DispatchQueue.main.async {
          self?.hum = nil
          self?.humRunning = false
        }
      }
      engine = e
    }
    try? engine?.start()
  }

  func stop() {
    stopHum()
    engine?.stop()
  }

  private func recover() {
    hum = nil
    humRunning = false
    try? engine?.start()
  }

  private func stopHum() {
    if humRunning { try? hum?.stop(atTime: CHHapticTimeImmediate) }
    humRunning = false
  }

  /// Called every frame; parameters go out at most 40 times a second.
  func updateHum(intensity: Float, sharpness: Float) {
    guard enabled, supported, let engine else { return }
    let now = CACurrentMediaTime()
    if intensity < 0.02 {
      stopHum()
      return
    }
    if hum == nil {
      let event = CHHapticEvent(
        eventType: .hapticContinuous,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ], relativeTime: 0, duration: 30)
      guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
        let player = try? engine.makeAdvancedPlayer(with: pattern)
      else { return }
      player.loopEnabled = true
      hum = player
    }
    if !humRunning {
      do {
        try hum?.start(atTime: CHHapticTimeImmediate)
        humRunning = true
      } catch {
        hum = nil
        return
      }
    }
    guard now - lastSend > 1.0 / 40 else { return }
    lastSend = now
    try? hum?.sendParameters(
      [
        CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: clamped(intensity, 0, 1), relativeTime: 0),
        CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: clamped(sharpness, 0, 1) - 0.5, relativeTime: 0),
      ], atTime: CHHapticTimeImmediate)
  }

  /// A single tap. `minGap` throttles bursts (string pulls, field crackle).
  func transient(intensity: Float, sharpness: Float, minGap: CFTimeInterval = 0) {
    guard enabled, supported, let engine else { return }
    let now = CACurrentMediaTime()
    guard now - lastTransient >= minGap else { return }
    lastTransient = now
    let event = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: clamped(intensity, 0, 1)),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: clamped(sharpness, 0, 1)),
      ], relativeTime: 0)
    if let pattern = try? CHHapticPattern(events: [event], parameters: []),
      let player = try? engine.makePlayer(with: pattern)
    {
      try? player.start(atTime: CHHapticTimeImmediate)
    }
  }

  /// A rising buzz that ends in a click: the rotor being spun up.
  func spinUp() {
    guard enabled, supported, let engine else { return }
    let ramp = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
      ], relativeTime: 0, duration: 0.55)
    let click = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
      ], relativeTime: 0.56)
    let curve = CHHapticParameterCurve(
      parameterID: .hapticIntensityControl,
      controlPoints: [
        .init(relativeTime: 0, value: 0.1), .init(relativeTime: 0.5, value: 1),
      ], relativeTime: 0)
    let sharp = CHHapticParameterCurve(
      parameterID: .hapticSharpnessControl,
      controlPoints: [
        .init(relativeTime: 0, value: -0.3), .init(relativeTime: 0.5, value: 0.4),
      ], relativeTime: 0)
    if let pattern = try? CHHapticPattern(events: [ramp, click], parameterCurves: [curve, sharp]),
      let player = try? engine.makePlayer(with: pattern)
    {
      try? player.start(atTime: CHHapticTimeImmediate)
    }
  }
}
