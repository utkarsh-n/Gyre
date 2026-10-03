import SwiftUI

/// A rotary knob: a Liquid Glass puck with a pointer, a lit value arc, and detent dots.
/// Drag up or right to turn it up. Detents pull the value in with a heavier click; there
/// are light ticks along the way. Double-tap returns it to its default.
struct GlassKnob: View {
  let spec: KnobSpec
  @Binding var value: Double
  var haptics: Haptics
  var onActive: (Bool) -> Void

  @GestureState private var dragging = false
  @State private var startPosition: Double?
  @State private var lastTick = 0
  @State private var lastDetent: String?
  @State private var bump = 0

  private let sweep = 270.0
  private var position: Double { spec.position(of: value) }

  var body: some View {
    VStack(spacing: 4) {
      dial
      Text(spec.title)
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.62))
      Text(spec.format(value))
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(.white)
        .contentTransition(.numericText(value: value))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spec.title)
    .accessibilityValue(spec.format(value))
    .accessibilityHint(spec.hint)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: nudge(1)
      case .decrement: nudge(-1)
      @unknown default: break
      }
    }
  }

  private var dial: some View {
    let lo = min(spec.originPosition, position)
    let hi = max(spec.originPosition, position)
    return ZStack {
      KnobArc(from: 0, to: 1, sweep: sweep)
        .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
      KnobArc(from: lo, to: hi, sweep: sweep)
        .stroke(spec.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .shadow(color: spec.tint.opacity(0.8), radius: 4)
      ForEach(spec.detents, id: \.self) { d in
        Circle()
          .fill(.white.opacity(lastDetent == d.label ? 1 : 0.45))
          .frame(width: 3, height: 3)
          .offset(y: -41)
          .rotationEffect(.degrees(-sweep / 2 + sweep * spec.position(of: d.value)))
      }
      ZStack {
        Image(systemName: spec.symbol)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .symbolEffect(.bounce, value: bump)
        Capsule()
          .fill(spec.tint)
          .frame(width: 3.5, height: 10)
          .shadow(color: spec.tint, radius: 3)
          .offset(y: -22)
          .rotationEffect(.degrees(-sweep / 2 + sweep * position))
      }
      .frame(width: 60, height: 60)
      .glassEffect(.regular.tint(spec.tint.opacity(startPosition == nil ? 0.1 : 0.32)).interactive(), in: .circle)
      .scaleEffect(startPosition == nil ? 1 : 1.07)
      .animation(.spring(duration: 0.25, bounce: 0.4), value: startPosition == nil)
    }
    .frame(width: 84, height: 84)
    .contentShape(Circle())
    .gesture(turn)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        withAnimation(.smooth) { value = spec.defaultValue }
        haptics.transient(intensity: 0.7, sharpness: 0.4)
        bump += 1
      })
    .onChange(of: dragging) { _, isDragging in
      if !isDragging { finish() }
    }
  }

  private var turn: some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($dragging) { _, state, _ in state = true }
      .onChanged { g in
        if startPosition == nil {
          startPosition = position
          lastTick = tick(position)
          lastDetent = spec.detent(at: value)?.label
          onActive(true)
          haptics.transient(intensity: 0.45, sharpness: 0.7)
        }
        var p = clamped((startPosition ?? position) + Double(g.translation.width - g.translation.height) / 230, 0, 1)
        if spec.isSwitch {
          // A rotary switch clicks firmly into each position.
          let next = spec.value(at: p)
          if next != value {
            value = next
            haptics.transient(intensity: 0.9, sharpness: 0.35)
            bump += 1
          }
          return
        }
        var next = spec.value(at: p)
        if let d = spec.detents.first(where: { abs(spec.position(of: $0.value) - p) < 0.02 }) {
          p = spec.position(of: d.value)
          next = d.value
          if lastDetent != d.label {
            lastDetent = d.label
            haptics.transient(intensity: 0.9, sharpness: 0.3)
            bump += 1
          }
        } else {
          lastDetent = nil
          let t = tick(p)
          if t != lastTick {
            lastTick = t
            haptics.transient(intensity: 0.32, sharpness: 0.9)
          }
        }
        if next != value { value = next }
      }
  }

  private func finish() {
    guard startPosition != nil else { return }
    startPosition = nil
    onActive(false)
  }

  private func tick(_ p: Double) -> Int { Int((p * 24).rounded(.down)) }

  private func nudge(_ direction: Double) {
    if spec.isSwitch {
      value = clamped(value + direction, spec.range.lowerBound, spec.range.upperBound)
      haptics.transient(intensity: 0.7, sharpness: 0.4)
      return
    }
    value = spec.value(at: clamped(position + direction / 20, 0, 1))
    haptics.transient(intensity: 0.4, sharpness: 0.8)
  }
}

/// An arc clockwise from the knob's lowest point, by fractions of its sweep.
struct KnobArc: Shape {
  var from: Double
  var to: Double
  var sweep: Double

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(from, to) }
    set {
      from = newValue.first
      to = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let r = min(rect.width, rect.height) / 2 - 2
    let start = -sweep / 2 + sweep * from
    let end = -sweep / 2 + sweep * to
    let n = max(2, Int(abs(end - start) / 4))
    for i in 0...n {
      let deg = start + (end - start) * Double(i) / Double(n)
      let a = deg * .pi / 180
      let p = CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    return path
  }
}
