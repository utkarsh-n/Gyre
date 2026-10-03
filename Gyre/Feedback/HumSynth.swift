import AVFoundation

/// The rotor's sound, synthesised live: a blade-pass whine (six spokes per turn) over the
/// rotor's own fundamental, bearing rumble that grows with friction, air whoosh that grows
/// with density and speed, a wobble at the nutation, and stereo panning that follows the
/// rotor around the bubble. Shares `AudioRoute`'s session: ambient (the silent switch
/// mutes it) unless the microphone is listening.
final class HumSynth {
  /// Written on the main thread, read on the audio thread. Plain doubles: a torn read
  /// can't happen on arm64 and a stale one is inaudible after smoothing.
  final class Controls {
    var rotorHz = 0.0
    var level = 0.0
    var pan = 0.0
    var hiss = 0.0
    var whoosh = 0.0
    var wobble = 0.0
    var wobbleHz = 0.0
    /// Pitch wobble from incoming radio waves, as a fraction of the pitch.
    var vibrato = 0.0
  }

  private final class Voice {
    var phaseR = 0.0
    var phaseW = 0.0
    var rotorHz = 0.0
    var level = 0.0
    var pan = 0.0
    var hiss = 0.0
    var whoosh = 0.0
    var wobble = 0.0
    var vibrato = 0.0
    var phaseV = 0.0
    var low = 0.0
    var band1 = 0.0
    var band2 = 0.0
    var noise: UInt32 = 22222
  }

  let controls = Controls()
  private let engine = AVAudioEngine()
  private var node: AVAudioSourceNode?
  private(set) var running = false
  private var observer: NSObjectProtocol?

  func start() {
    guard !running else { return }
    AudioRoute.apply()
    if node == nil { build() }
    do {
      try engine.start()
      running = true
    } catch {
      running = false
    }
    if observer == nil {
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        guard let self, self.running else { return }
        self.running = false
        self.start()
      }
    }
  }

  func stop() {
    engine.pause()
    running = false
  }

  private func build() {
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let sampleRate = rate > 0 ? rate : 48_000
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
    let c = controls
    let v = Voice()
    let smooth = 1 - exp(-1 / (0.03 * sampleRate))
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
      guard buffers.count >= 2,
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
      else { return noErr }
      let twoPi = 2 * Double.pi
      let wobbleHz = c.wobbleHz
      for i in 0..<Int(frameCount) {
        v.rotorHz += (c.rotorHz - v.rotorHz) * smooth
        v.level += (c.level - v.level) * smooth
        v.pan += (c.pan - v.pan) * smooth
        v.hiss += (c.hiss - v.hiss) * smooth
        v.whoosh += (c.whoosh - v.whoosh) * smooth
        v.wobble += (c.wobble - v.wobble) * smooth
        v.vibrato += (c.vibrato - v.vibrato) * smooth
        v.phaseV += twoPi * 5.5 / sampleRate
        if v.phaseV > twoPi { v.phaseV -= twoPi }

        v.phaseR += twoPi * v.rotorHz * (1 + v.vibrato * sin(v.phaseV)) / sampleRate
        if v.phaseR > twoPi * 1000 { v.phaseR -= twoPi * 1000 }
        v.phaseW += twoPi * wobbleHz / sampleRate
        if v.phaseW > twoPi { v.phaseW -= twoPi }
        let blade = 6 * v.phaseR
        var tone = sin(blade) * 0.55 + sin(2 * blade + 0.3) * 0.17 + sin(3 * blade + 1.1) * 0.06
        tone += sin(v.phaseR) * 0.3 + sin(2 * v.phaseR) * 0.12
        let am = 1 + v.wobble * sin(v.phaseW)

        v.noise ^= v.noise << 13
        v.noise ^= v.noise >> 17
        v.noise ^= v.noise << 5
        let white = Double(v.noise) / Double(UInt32.max) * 2 - 1
        v.low += (white - v.low) * 0.02
        // A soft band of noise whose centre rises with spin: rushing air.
        let k = min(0.5, 0.01 + v.rotorHz * 0.0009)
        v.band1 += (white - v.band1) * k
        v.band2 += (v.band1 - v.band2) * k
        let air = v.band1 - v.band2

        let s = (tone * v.level * am + v.low * v.hiss * 2.5 + air * v.whoosh * 1.6) * 0.2
        let angle = (v.pan + 1) * Double.pi / 4
        left[i] = Float(s * cos(angle) * 1.414)
        right[i] = Float(s * sin(angle) * 1.414)
      }
      return noErr
    }
    engine.attach(source)
    do {
      try engine.connectNode(source, to: engine.mainMixerNode, format: format)
    } catch {
      engine.detach(source)
      return
    }
    engine.mainMixerNode.outputVolume = 0.9
    node = source
  }
}
