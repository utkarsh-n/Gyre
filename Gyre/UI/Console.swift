import SwiftUI

enum ConsolePage: String, CaseIterable, Identifiable {
  case physics = "Physics"
  case signals = "Signals"
  case object = "Object"
  var id: String { rawValue }
}

/// The bottom console: pages of glass knobs (physics; sound with the microphone; the
/// object and its glass), the relaunch and AR placement controls, and a fold button that melts the knobs away so
/// the bubble can swell to fill the screen.
struct KnobConsole: View {
  @Bindable var model: GyroModel
  @Binding var open: Bool
  @State private var page: ConsolePage = .physics
  @Namespace private var glass

  var body: some View {
    GlassEffectContainer(spacing: 18) {
      VStack(spacing: 12) {
        if open {
          VStack(spacing: 10) {
            Picker("Knobs", selection: $page.animation(.spring(duration: 0.35, bounce: 0.2))) {
              ForEach(ConsolePage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.tabs)
            .frame(maxWidth: 320)
            switch page {
            case .physics:
              Grid(horizontalSpacing: 2, verticalSpacing: 10) {
                GridRow { ForEach(KnobSpec.physics.prefix(4)) { knob($0) } }
                GridRow { ForEach(KnobSpec.physics.suffix(4)) { knob($0) } }
              }
              .transition(.blurReplace)
            case .signals:
              signalsPage
                .transition(.blurReplace)
            case .object:
              objectPage
                .transition(.blurReplace)
            }
          }
          .transition(.blurReplace.combined(with: .scale(0.9, anchor: .bottom)))
        }
        controls
      }
    }
    .overlay(alignment: .top) {
      if let id = model.activeKnob {
        let spec = KnobSpec.spec(id)
        KnobReadout(spec: spec, value: model[keyPath: spec.keyPath])
          .offset(y: -78)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
      }
    }
    .animation(.spring(duration: 0.3, bounce: 0.25), value: model.activeKnob)
  }

  private func knob(_ spec: KnobSpec) -> some View {
    GlassKnob(
      spec: spec,
      value: Binding(
        get: { model[keyPath: spec.keyPath] },
        set: { model[keyPath: spec.keyPath] = $0 }),
      haptics: model.haptics,
      onActive: { active in
        if active {
          model.activeKnob = spec.id
        } else if model.activeKnob == spec.id {
          model.activeKnob = nil
        }
      })
  }

  // MARK: Object page

  private var objectPage: some View {
    VStack(spacing: 12) {
      GlassEffectContainer(spacing: 4) {
        HStack(spacing: 8) {
          ForEach(GyroObject.allCases) { object in
            ObjectTile(object: object, selected: model.object == object) {
              withAnimation(.spring(duration: 0.35, bounce: 0.25)) { model.select(object) }
            }
          }
        }
      }
      if model.object == .glassOrb {
        Grid(horizontalSpacing: 2, verticalSpacing: 10) {
          GridRow { ForEach(KnobSpec.glass) { knob($0) } }
        }
        .transition(.blurReplace)
      } else {
        Text(model.object.subtitle)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 44)
          .padding(.horizontal, 12)
          .contentTransition(.opacity)
          .transition(.blurReplace)
      }
    }
  }

  // MARK: Signals page

  /// The microphone's knobs dim while it's off; Radio works on its own.
  private var signalsPage: some View {
    let mic = model.micState == .on
    let specs = KnobSpec.sound
    return Grid(horizontalSpacing: 2, verticalSpacing: 10) {
      GridRow { ForEach(specs.prefix(4)) { knob($0).opacity(mic ? 1 : 0.55) } }
      GridRow {
        knob(KnobSpec.spec(.visual)).opacity(mic ? 1 : 0.55)
        knob(KnobSpec.spec(.radio))
        VStack(alignment: .leading, spacing: 8) {
          Button {
            model.toggleMic()
          } label: {
            Label(micTitle, systemImage: mic ? "mic.fill" : "mic.slash.fill")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.75)
              .frame(maxWidth: .infinity, minHeight: 34)
              .contentTransition(.symbolEffect(.replace))
          }
          .buttonStyle(.glass(mic ? .regular.tint(Color(red: 0.2, green: 0.75, blue: 0.45).opacity(0.6)) : .regular))
          .disabled(model.micState == .denied)
          LevelMeter(level: model.telemetry.soundLevel, active: mic)
          Text(radioStatus)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
        }
        .gridCellColumns(2)
        .padding(.horizontal, 6)
      }
    }
  }

  private var radioStatus: String {
    let t = model.telemetry
    switch t.radioState {
    case .off: return "Radio off · turn up Radio to listen"
    case .starting: return "Radio starting…"
    case .denied: return "Bluetooth access is off in Settings"
    case .unavailable: return "Bluetooth unavailable"
    case .scanning:
      var parts = ["\(t.radios) Bluetooth"]
      if t.onWiFi { parts.append("Wi-Fi") }
      if let c = t.cellular { parts.append(c) }
      parts.append(String(format: "EMF %.2f µT %.0f Hz", t.emf, t.emfHz))
      return parts.joined(separator: " · ")
    }
  }

  private var micTitle: String {
    switch model.micState {
    case .on: "Listening"
    case .starting: "Asking…"
    case .denied: "Mic access is off in Settings"
    case .failed: "Mic unavailable"
    case .off: "Turn on mic"
    }
  }

  // MARK: Controls

  private var controls: some View {
    HStack(spacing: 10) {
      if model.ar.isActive {
        Button {
          model.placeOrPickUp()
        } label: {
          Label(model.ar.placed ? "Pick up" : "Place", systemImage: model.ar.placed ? "hand.raised.fill" : "arrow.down.to.line.compact")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minHeight: 36)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .tint(Color(red: 0.2, green: 0.62, blue: 0.85))
        .glassEffectID("place", in: glass)
        .accessibilityHint(model.ar.placed ? "Carries the bubble in front of you again" : "Sets the bubble down where you're pointing")

        Button {
          model.relaunch()
        } label: {
          Image(systemName: "hurricane")
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .glassEffectID("relaunch", in: glass)
        .accessibilityLabel("Relaunch")
      } else {
        Button {
          model.relaunch()
        } label: {
          Label("Relaunch", systemImage: "hurricane")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .tint(Color(red: 0.2, green: 0.62, blue: 0.85))
        .glassEffectID("relaunch", in: glass)
        .accessibilityHint("Stands the rotor up and spins it to the motor speed")
      }

      Button {
        model.paused.toggle()
        model.haptics.transient(intensity: 0.5, sharpness: 0.6)
      } label: {
        Image(systemName: model.paused ? "play.fill" : "pause.fill")
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .glassEffectID("pause", in: glass)
      .accessibilityLabel(model.paused ? "Resume" : "Freeze time")

      Spacer(minLength: 0)

      if open {
        Button {
          model.resetKnobs(on: page)
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .glassEffectID("reset", in: glass)
        .accessibilityLabel("Reset \(page.rawValue.lowercased()) knobs")
      }

      Button {
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) { open.toggle() }
        model.haptics.transient(intensity: 0.4, sharpness: 0.5)
      } label: {
        Label("Knobs", systemImage: open ? "chevron.down" : "dial.medium.fill")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .fixedSize()
          .frame(minHeight: 36)
      }
      .buttonStyle(.glass)
      .glassEffectID("fold", in: glass)
    }
  }
}

/// A glass tile on the object shelf.
struct ObjectTile: View {
  let object: GyroObject
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        Image(systemName: object.symbol)
          .font(.title3)
          .symbolEffect(.bounce, value: selected)
          .frame(height: 26)
        Text(object.title)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .foregroundStyle(selected ? .white : .white.opacity(0.75))
      .frame(maxWidth: .infinity, minHeight: 62)
      .contentShape(.rect(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .glassEffect(
      selected ? .regular.tint(Color(red: 0.25, green: 0.7, blue: 1.0).opacity(0.45)).interactive() : .regular.interactive(),
      in: .rect(cornerRadius: 18))
    .accessibilityLabel(object.title)
    .accessibilityHint(object.subtitle)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A slim phosphor bar showing how loud the room is above its own background.
struct LevelMeter: View {
  let level: Double
  let active: Bool

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.1))
        Capsule()
          .fill(Color(red: 0.35, green: 1.0, blue: 0.55).gradient)
          .frame(width: max(6, geo.size.width * level))
          .shadow(color: Color(red: 0.35, green: 1.0, blue: 0.55).opacity(0.8), radius: 4)
          .opacity(active ? 1 : 0)
      }
    }
    .frame(height: 6)
    .animation(.linear(duration: 0.1), value: level)
    .accessibilityElement()
    .accessibilityLabel("Sound level")
    .accessibilityValue(active ? "\(Int(level * 100)) percent" : "Microphone off")
  }
}

/// Floating glass card that names what you're turning and what it does physically.
struct KnobReadout: View {
  let spec: KnobSpec
  let value: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: spec.symbol).foregroundStyle(spec.tint)
        Text(spec.title).font(.headline)
        Spacer(minLength: 8)
        if !spec.isSwitch, let d = spec.detent(at: value) {
          Text(d.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(spec.tint)
            .transition(.opacity)
        }
        Text(spec.format(value))
          .font(.headline.monospacedDigit())
          .contentTransition(.numericText(value: value))
      }
      Text(spec.hint)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 420)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
    .padding(.horizontal, 4)
    .allowsHitTesting(false)
    .animation(.smooth(duration: 0.15), value: value)
  }
}
