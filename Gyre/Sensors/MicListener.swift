import AVFoundation
import Foundation

/// The one audio session both the hum and the microphone share: ambient (the silent
/// switch mutes the hum) until the mic listens, then play-and-record in measurement mode
/// so the input arrives without voice processing or automatic gain.
enum AudioRoute {
  static var recording = false

  static func apply() {
    let session = AVAudioSession.sharedInstance()
    if recording {
      try? session.setCategory(
        .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
    } else {
      try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }
    try? session.setActive(true)
  }
}

struct MicSnapshot {
  /// The most recent samples, oldest first.
  var samples: [Float]
  /// RMS of the latest input buffer.
  var level: Float
  /// RMS below about 150 Hz.
  var bass: Float
  /// Strength of a transient (clap, beat, consonant) since the last snapshot; 0 if none.
  var onset: Float
}

/// Listens to the microphone for the oscilloscope and for sound modulation. Nothing is
/// recorded or kept: samples live in a 16k ring buffer that is constantly overwritten.
/// With the `-fakeMic` launch argument it synthesises a room instead (for the Simulator).
final class MicListener {
  enum State: Equatable { case off, starting, on, denied, failed }

  private(set) var state: State = .off
  let fake = ProcessInfo.processInfo.arguments.contains("-fakeMic")
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var ring = [Float](repeating: 0, count: 16384)
  private var head = 0
  private var level: Float = 0
  private var bass: Float = 0
  private var pendingOnset: Float = 0
  private var lowpass: Float = 0
  private var average: Float = 0
  private var clock = 0.0
  private var lastOnset = -1.0
  private var quietUntil = 0.0
  private var sampleRate = 48_000.0
  private var fakeTime = 0.0
  private var fakeNoise: UInt32 = 1

  func start(_ changed: @escaping (State) -> Void) {
    guard state != .on, state != .starting else { return }
    if fake {
      state = .on
      changed(.on)
      return
    }
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      begin(changed)
    case .denied:
      state = .denied
      changed(.denied)
    default:
      state = .starting
      changed(.starting)
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async {
          if granted {
            self.begin(changed)
          } else {
            self.state = .denied
            changed(.denied)
          }
        }
      }
    }
  }

  private func begin(_ changed: (State) -> Void) {
    AudioRoute.recording = true
    AudioRoute.apply()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      fail(changed)
      return
    }
    sampleRate = format.sampleRate
    input.removeTap(onBus: 0)
    // iOS 27 deprecates this for an error-reporting variant that the beta SDK doesn't yet
    // refine for Swift; this one still works.
    input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
      guard let self, let channel = buffer.floatChannelData?[0] else { return }
      let n = Int(buffer.frameLength)
      self.lock.lock()
      self.write(channel, count: n)
      self.lock.unlock()
    }
    do {
      try engine.start()
      state = .on
      changed(.on)
    } catch {
      input.removeTap(onBus: 0)
      fail(changed)
    }
  }

  private func fail(_ changed: (State) -> Void) {
    AudioRoute.recording = false
    AudioRoute.apply()
    state = .failed
    changed(.failed)
  }

  func stop() {
    if !fake, state == .on {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      AudioRoute.recording = false
      AudioRoute.apply()
    }
    state = .off
    lock.lock()
    for i in ring.indices { ring[i] = 0 }
    level = 0
    bass = 0
    pendingOnset = 0
    lock.unlock()
  }

  /// Ignore transients for a moment, e.g. while our own haptic click rings through the case.
  func ignoreOnsets(for seconds: Double) {
    lock.lock()
    quietUntil = clock + seconds
    lock.unlock()
  }

  /// Call with the lock held.
  private func write(_ x: UnsafePointer<Float>, count n: Int) {
    guard n > 0 else { return }
    let mask = ring.count - 1
    let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
    var sum: Float = 0
    var bassSum: Float = 0
    for i in 0..<n {
      let s = x[i]
      ring[head] = s
      head = (head + 1) & mask
      sum += s * s
      lowpass += (s - lowpass) * a
      bassSum += lowpass * lowpass
    }
    let rms = (sum / Float(n)).squareRoot()
    level = rms
    bass = (bassSum / Float(n)).squareRoot()
    let dt = Double(n) / sampleRate
    clock += dt
    if rms > average * 1.9 + 0.004, clock - lastOnset > 0.12, clock > quietUntil {
      pendingOnset = max(pendingOnset, min(rms / max(average, 0.002), 12))
      lastOnset = clock
    }
    average += (rms - average) * Float(min(1, dt / 0.25))
  }

  /// The latest `count` samples and features. Advances the fake room by `dt` when faking.
  func snapshot(count: Int, dt: Double) -> MicSnapshot {
    if fake, state == .on { synthesize(dt) }
    lock.lock()
    defer { lock.unlock() }
    let mask = ring.count - 1
    var out = [Float](repeating: 0, count: count)
    let start = (head - count) & mask
    for i in 0..<count { out[i] = ring[(start + i) & mask] }
    let onset = pendingOnset
    pendingOnset = 0
    return MicSnapshot(samples: out, level: level, bass: bass, onset: onset)
  }

  /// A hummed chord that swells and fades, with a clap every 1.6 s.
  private func synthesize(_ dt: Double) {
    let rate = 48_000.0
    let n = min(Int(dt * rate), 4096)
    guard n > 0 else { return }
    var buffer = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let t = fakeTime + Double(i) / rate
      let swell = 0.5 + 0.5 * sin(2 * .pi * 0.18 * t)
      var s = 0.22 * swell * (sin(2 * .pi * 196 * t) + 0.6 * sin(2 * .pi * 294 * t + 0.4) + 0.25 * sin(2 * .pi * 392 * t))
      let beat = t.truncatingRemainder(dividingBy: 1.6)
      if beat < 0.05 {
        fakeNoise ^= fakeNoise << 13
        fakeNoise ^= fakeNoise >> 17
        fakeNoise ^= fakeNoise << 5
        s += (Double(fakeNoise) / Double(UInt32.max) * 2 - 1) * 0.7 * exp(-beat * 70)
      }
      buffer[i] = Float(s)
    }
    fakeTime += Double(n) / rate
    sampleRate = rate
    lock.lock()
    buffer.withUnsafeBufferPointer { write($0.baseAddress!, count: n) }
    lock.unlock()
  }
}
