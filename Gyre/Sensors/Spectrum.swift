import Accelerate

/// The microphone's spectrum in log-spaced bands (45 Hz to 15 kHz), smoothed for display:
/// a Hann-windowed 2048-point FFT, levels in decibels mapped to 0…1, a quick attack and
/// slower release, and peak holds that fall slower still.
final class Spectrum {
  static let size = 2048
  static let bandCount = 48

  private let setup: FFTSetup
  private var window = [Float](repeating: 0, count: size)
  private var windowed = [Float](repeating: 0, count: size)
  private var real = [Float](repeating: 0, count: size / 2)
  private var imag = [Float](repeating: 0, count: size / 2)
  private var power = [Float](repeating: 0, count: size / 2)
  private var edges: [Int] = []
  private(set) var bands = [Float](repeating: 0, count: bandCount)
  private(set) var peaks = [Float](repeating: 0, count: bandCount)

  init(sampleRate: Double = 48_000) {
    setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    let lo = 45.0, hi = 15_000.0
    for i in 0...Self.bandCount {
      let f = lo * pow(hi / lo, Double(i) / Double(Self.bandCount))
      edges.append(min(max(Int(f / sampleRate * Double(Self.size)), 1), Self.size / 2 - 1))
    }
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  func reset() {
    for i in 0..<Self.bandCount {
      bands[i] = 0
      peaks[i] = 0
    }
  }

  func update(_ samples: [Float], gain: Float, dt: Float) {
    let n = Self.size
    guard samples.count >= n else { return }
    samples.withUnsafeBufferPointer { s in
      vDSP_vmul(s.baseAddress! + (samples.count - n), 1, window, 1, &windowed, 1, vDSP_Length(n))
    }
    real.withUnsafeMutableBufferPointer { rp in
      imag.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        windowed.withUnsafeBufferPointer { w in
          w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
        power.withUnsafeMutableBufferPointer { pp in
          vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n / 2))
        }
      }
    }
    let release = exp(-dt / 0.22)
    let peakRelease = exp(-dt / 0.9)
    let g2 = gain * gain
    for b in 0..<Self.bandCount {
      let a = edges[b]
      let c = max(edges[b + 1], a + 1)
      var sum: Float = 0
      for k in a..<c { sum += power[k] }
      let p = sum / Float(c - a) * g2
      let level = min(max((10 * log10(p + 1e-9) - 8) / 46, 0), 1)
      bands[b] = max(level, bands[b] * release)
      peaks[b] = max(bands[b], peaks[b] * peakRelease)
    }
  }
}
