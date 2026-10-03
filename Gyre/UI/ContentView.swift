import SwiftUI

struct ContentView: View {
  @State private var model = GyroModel()
  @State private var knobsOpen = true
  @State private var showInfo = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      HoloView(model: model)
        .ignoresSafeArea()

      if model.ar.isActive, !model.ar.simulated {
        CoachingOverlay(controller: model.ar)
          .ignoresSafeArea()
          .allowsHitTesting(model.ar.isCoaching)
      }

      VStack(spacing: 0) {
        TopBar(model: model, showInfo: $showInfo)
          .padding(.horizontal, 16)
          .padding(.top, 6)
          .layoutPriority(1)
          .zIndex(1)

        if model.ar.isActive {
          ARBanner(controller: model.ar)
            .padding(.top, 8)
            .transition(.blurReplace)
        }

        bubbleRegion

        KnobConsole(model: model, open: $knobsOpen)
          .padding(.horizontal, 12)
          .padding(.bottom, 4)
          .layoutPriority(1)
      }
    }
    .background(Color.black)
    .sheet(isPresented: $showInfo) { InfoSheet(model: model) }
    .onAppear {
      model.reduceMotion = reduceMotion
      model.start()
    }
    .onChange(of: reduceMotion) { _, value in model.reduceMotion = value }
    .onChange(of: model.ar.isActive) { _, on in
      // Clear the view for AR; the knobs are a tap away.
      withAnimation(.spring(duration: 0.45, bounce: 0.2)) { knobsOpen = !on }
    }
    .animation(.smooth, value: model.ar.isActive)
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: model.start()
      case .background: model.stop()
      default: break
      }
    }
    .persistentSystemOverlays(.hidden)
  }

  /// The space between the bars. Its frame places the bubble; touches in it pull the
  /// string, poke the rotor, or (with simulated motion) tilt the phone.
  private var bubbleRegion: some View {
    GeometryReader { geo in
      Color.clear
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { model.touchChanged(at: $0.location, in: geo.size) }
            .onEnded { model.touchEnded(at: $0.location, in: geo.size) }
        )
        .simultaneousGesture(
          MagnifyGesture()
            .onChanged { value in
              guard model.ar.isActive else { return }
              if !model.pinching {
                model.pinching = true
                model.ar.pinchBegan()
              }
              model.ar.pinch(value.magnification, ended: false)
            }
            .onEnded { value in
              model.ar.pinch(value.magnification, ended: true)
              model.pinching = false
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.bubbleRegion = $0 }
        .accessibilityElement()
        .accessibilityLabel("Gyroscope bubble")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Swipe to spin the rotor. Tap to nudge it.")
        .accessibilityAction(named: "Spin faster") { model.sim.addSpin(model.sim.I3 * 50) }
        .accessibilityAction(named: "Relaunch") { model.relaunch() }
    }
  }

  private var accessibilitySummary: String {
    let t = model.telemetry
    return String(format: "Spinning at %.0f rpm, axis %.0f degrees from vertical, precessing at %.2f hertz", abs(t.rpm), t.tiltDegrees, abs(t.precessionHz))
  }
}
