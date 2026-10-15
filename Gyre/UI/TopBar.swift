import SwiftUI

/// Telemetry on the left (tap to unfold the sensor readings), and a glass toolbar group
/// on the right: AR, experiments, layers, and about.
struct TopBar: View {
  @Bindable var model: GyroModel
  @Binding var showInfo: Bool
  @State private var expanded = false

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        TelemetryCard(model: model, expanded: $expanded)
        Spacer(minLength: 0)
        HStack(spacing: 0) {
          Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { model.toggleLock() }
          } label: {
            Image(systemName: model.locked ? "lock.fill" : "lock.open")
              .font(.body.weight(.semibold))
              .foregroundStyle(model.locked ? Color(red: 1.0, green: 0.78, blue: 0.3) : .white)
              .frame(width: 38, height: 44)
              .contentTransition(.symbolEffect(.replace))
          }
          .accessibilityLabel(model.locked ? "Unlock gravity" : "Lock gravity here")
          .accessibilityHint("Freezes the bubble's orientation so you can hold the phone at any angle")
          Button {
            model.toggleAR()
          } label: {
            Image(systemName: model.ar.isActive ? "xmark" : "arkit")
              .font(.body.weight(.semibold))
              .frame(width: 38, height: 44)
              .contentTransition(.symbolEffect(.replace))
          }
          .accessibilityLabel(model.ar.isActive ? "Leave AR" : "Show in your room")
          experimentsMenu
          layersMenu
          Button {
            showInfo = true
          } label: {
            Image(systemName: "info")
              .font(.body.weight(.semibold))
              .frame(width: 38, height: 44)
          }
          .accessibilityLabel("About Gyre")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
    }
  }

  private var experimentsMenu: some View {
    Menu {
      Section("Experiments") {
        ForEach(Experiment.all) { exp in
          Button {
            model.apply(exp)
          } label: {
            Label(exp.title, systemImage: exp.symbol)
            Text(exp.subtitle)
          }
        }
      }
    } label: {
      Image(systemName: "flask.fill")
        .font(.body.weight(.semibold))
        .frame(width: 38, height: 44)
    }
    .accessibilityLabel("Experiments")
  }

  private var layersMenu: some View {
    Menu {
      Section("Gyroscope") {
        Toggle(isOn: $model.harmonicCenter.animation()) {
          Label("Harmonic center", systemImage: "scope")
          Text("Rotor at the bubble's centre instead of the pivot")
        }
      }
      Section("Show") {
        Toggle(isOn: $model.showVectors) { Label("Vectors L, τ, g", systemImage: "arrow.up.right") }
        Toggle(isOn: $model.showTrail) { Label("Axis trail", systemImage: "scribble") }
        Toggle(isOn: $model.showMotes) { Label("Dust", systemImage: "sparkles") }
        Toggle(isOn: $model.showFieldLines) {
          Label("Magnetic field lines", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
          Text("Shown when Magnet is up")
        }
      }
      Section("Feel") {
        Toggle(isOn: $model.soundOn) { Label("Rotor sound", systemImage: "speaker.wave.2.fill") }
        Toggle(isOn: $model.hapticsOn) { Label("Haptics", systemImage: "hand.tap.fill") }
      }
      Section("Sensors") {
        Toggle(isOn: $model.useBarometer) { Label("Live air pressure", systemImage: "barometer") }
          .disabled(!model.motion.barometerAvailable)
      }
    } label: {
      Image(systemName: "square.3.layers.3d")
        .font(.body.weight(.semibold))
        .frame(width: 38, height: 44)
    }
    .accessibilityLabel("Layers and feedback")
  }
}

struct TelemetryCard: View {
  @Bindable var model: GyroModel
  @Binding var expanded: Bool

  private var t: Telemetry { model.telemetry }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "fanblades.fill")
          .font(.title3)
          .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 1.0))
          .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: abs(t.rpm) > 30 && !model.paused)
        VStack(alignment: .leading, spacing: 1) {
          Text(rpmText)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .contentTransition(.numericText(value: t.rpm))
          HStack(spacing: 6) {
            Text(precessionText)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            if model.params.timeScale != 1 {
              Text(String(format: "%.2g×", model.params.timeScale))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color(red: 0.72, green: 0.55, blue: 1.0).opacity(0.35), in: .capsule)
            }
          }
        }
        .lineLimit(1)
      }
      if expanded {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
          row("Axis tilt", String(format: "%.0f° from up", t.tiltDegrees), "angle")
          row("Gyroscope", String(format: "%.0f°/s", t.deviceRateDegrees), "gyroscope")
          row("Accelerometer", String(format: "%.2f g shake", t.shakeG), "move.3d")
          row("Magnetometer", t.fieldCalibrated ? String(format: "%.0f µT", t.fieldMicroTesla) : "calibrating", "location.north.line.fill")
          row(
            "Barometer",
            t.pressureKPa.map { String(format: "%.2f kPa", $0) } ?? (model.motion.barometerAvailable ? "off" : "—"),
            "barometer")
          row(
            "Radio",
            t.radioState == .scanning ? "\(t.radios) BLE\(t.onWiFi ? " · Wi-Fi" : "")\(t.cellular.map { " · \($0)" } ?? "")" : "off",
            "antenna.radiowaves.left.and.right")
          row("EMF", String(format: "%.2f µT flicker", t.emf), "bolt.horizontal")
          if !t.liveSensors {
            Text("Simulated motion. Drag outside the bubble to tilt.")
              .font(.caption2)
              .foregroundStyle(.orange)
              .gridCellColumns(2)
          }
        }
        .font(.caption.monospacedDigit())
        .transition(.blurReplace)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    .contentShape(.rect(cornerRadius: 22))
    .onTapGesture {
      withAnimation(.spring(duration: 0.4, bounce: 0.25)) { expanded.toggle() }
      model.haptics.transient(intensity: 0.35, sharpness: 0.6)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(expanded ? "Hides sensor readings" : "Shows sensor readings")
  }

  private var rpmText: String { "\(Int(abs(t.rpm).rounded()).formatted()) rpm" }

  private var precessionText: String {
    let hz = t.precessionHz
    guard abs(hz) > 0.005 else { return "steady" }
    return String(format: "%@ %.2f Hz", hz >= 0 ? "↺" : "↻", abs(hz))
  }

  private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
    GridRow {
      Label(title, systemImage: symbol)
        .foregroundStyle(.secondary)
      Text(value)
        .contentTransition(.numericText())
    }
  }
}
