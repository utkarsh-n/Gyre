import ARKit
import SwiftUI

/// Apple's coaching overlay: it appears by itself while tracking is getting started and
/// gets out of the way once it's good.
struct CoachingOverlay: UIViewRepresentable {
  let controller: ARController

  func makeUIView(context: Context) -> ARCoachingOverlayView {
    let view = ARCoachingOverlayView()
    view.session = controller.session
    view.goal = .tracking
    view.activatesAutomatically = true
    view.delegate = controller
    return view
  }

  func updateUIView(_ view: ARCoachingOverlayView, context: Context) {}
}

/// A glass banner with what AR needs from you right now, or how to use it.
struct ARBanner: View {
  let controller: ARController

  var body: some View {
    let text = controller.message ?? (controller.placed
      ? "Walk around it. Pinch to resize; tap or swipe the bubble as before."
      : "It's in your hand: swing the phone. Tap a surface or Place to set it down.")
    Label(text, systemImage: controller.message == nil ? "arkit" : "exclamationmark.triangle.fill")
      .font(.footnote.weight(.medium))
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .glassEffect(.regular, in: .capsule)
      .padding(.horizontal, 16)
      .contentTransition(.opacity)
      .animation(.smooth, value: text)
      .allowsHitTesting(false)
  }
}
