import SwiftUI

struct InfoSheet: View {
  @Bindable var model: GyroModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "A gyroscope on a ball pivot, floating in a soap bubble inside your phone. The bubble is attached to the phone; the rotor obeys real rigid-body physics in the room around you. Turn the phone and the spinning axis holds its direction in space while the bubble turns around it."
          )
          .font(.callout)
        }

        Section("Touch") {
          info("hand.draw.fill", "Swipe across the rotor", "Like pulling a string or flicking the rim: adds spin in the direction you drag.")
          info("hand.tap.fill", "Tap the bubble", "Pokes the rotor. A fast one shrugs it off with a nod (nutation); a slow one gets knocked over.")
          info("iphone.gen3.radiowaves.left.and.right", "Turn, tilt, shake", "Gravity's direction comes from the accelerometer, your turning from the gyroscope. Shakes jolt the rotor, slosh the dust and wobble the bubble.")
          info("hand.point.up.left.fill", "Double-tap a knob", "Returns it to its default.")
        }

        Section("What you're seeing") {
          legend(HoloPalette.momentum, "L", "Angular momentum. Torque swings it sideways, not down.")
          legend(HoloPalette.torque, "τ", "Torque, drawn at L's tip: the direction L is heading.")
          legend(HoloPalette.gravity, "g", "Local gravity on the rotor's centre of mass.")
          legend(HoloPalette.field, "B", "Magnetic field from your magnetometer (when Magnet is on).")
          legend(HoloPalette.fieldLine, "≋", "Field lines of that field, bent by the magnetised rotor; denser where it's stronger, pulsing along B.")
          legend(HoloPalette.trailHead, "∿", "Path of the axle tip: precession, with nutation loops on top.")
          legend(HoloPalette.horizon, "◯", "The world's horizon, fixed in space. Red tick: magnetic north.")
        }

        Section("In your room (AR)") {
          info("arkit", "Tap the AR button", "The bubble floats in front of your phone, so swinging the phone swings the gyroscope, lever arm and all. Place sets it on a surface (or leaves it hanging in mid-air); walk around it, pinch to resize, Pick up to carry it again.")
          info("cube.fill", "Objects", "The Object tab turns the spinning thing into a wireframe hologram, the holo-metal gyroscope, the gyroscope sealed in an abraded glass orb, a machined titanium top, or a ringed planet. The physics stays the gyroscope's. The metal reflects a holographic studio fixed in your room, or in AR your actual room, from ARKit's environment maps.")
          info("scope", "Harmonic center", "Puts the rotor's centre of mass at the bubble's centre and lets the pivot ride along instead. The physics doesn't change. It's how a free gyroscope would sit in zero-g.")
        }

        Section("Signals") {
          info("waveform.path.ecg", "Oscilloscope", "Turn on the mic on the Sound page and the bubble draws what it hears: a ring around the horizon, a triggered trace, or an XY figure. Nothing is recorded or kept.")
          info("chart.bar.xaxis", "Visual", "A spectrum visualiser for the mic: a radial halo around the bubble, a spectral waterfall across its floor, or music-reactive halos and beat shockwaves around the rotor.")
          info("antenna.radiowaves.left.and.right", "Radio", "Nearby Bluetooth radios, your Wi-Fi and cellular links, and the EMF flicker in the magnetometer, drawn around the bubble. Their waves roll in and nudge the gyroscope. iOS doesn't let apps scan Wi-Fi or read signal strengths, and it never says which direction a signal comes from, so directions are symbolic; distance follows Bluetooth signal strength.")
          info("ear.fill", "Listen and Drives", "Listen sets how hard sound pushes; Drives picks what it pushes: gravity, air turbulence, the rotor's spin, beat kicks, or the film itself. Only changes in sound count, so a steady hum fades out.")
        }

        Section("Knobs") {
          ForEach(KnobSpec.physics + KnobSpec.sound + KnobSpec.glass) { spec in
            VStack(alignment: .leading, spacing: 4) {
              Label(spec.title, systemImage: spec.symbol)
                .font(.headline)
                .foregroundStyle(spec.tint)
              Text(spec.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }

        Section("Sensors in play") {
          sensor("gyroscope", "Gyroscope", model.telemetry.liveSensors ? String(format: "%.0f°/s", model.telemetry.deviceRateDegrees) : "simulated")
          sensor("move.3d", "Accelerometer", model.telemetry.liveSensors ? String(format: "%.2f g", model.telemetry.shakeG) : "simulated")
          sensor("location.north.line.fill", "Magnetometer", model.telemetry.fieldCalibrated ? String(format: "%.0f µT", model.telemetry.fieldMicroTesla) : "calibrating")
          Toggle(isOn: $model.useBarometer) {
            Label {
              VStack(alignment: .leading) {
                Text("Barometer")
                Text(model.telemetry.pressureKPa.map { String(format: "%.2f kPa scales the air", $0) } ?? "Scale the bubble's air by real pressure")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "barometer")
            }
          }
          .disabled(!model.motion.barometerAvailable)
        }

        Section {
          Text("The physics is a symmetric heavy top integrated with fourth-order Runge–Kutta in the world frame, with enough substeps to resolve nutation. The bubble's colours are thin-film interference in a draining soap film.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Gyre")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
  }

  private func info(_ symbol: String, _ title: String, _ body: String) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(body).font(.callout).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: symbol).foregroundStyle(.tint)
    }
  }

  private func legend(_ color: F3, _ glyph: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(glyph)
        .font(.system(.headline, design: .serif).italic())
        .foregroundStyle(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
        .frame(width: 22)
      Text(text).font(.callout)
    }
  }

  private func sensor(_ symbol: String, _ name: String, _ value: String) -> some View {
    LabeledContent {
      Text(value).monospacedDigit()
    } label: {
      Label(name, systemImage: symbol)
    }
  }
}
