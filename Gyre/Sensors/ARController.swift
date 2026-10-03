import ARKit
import AVFoundation
import CoreVideo
import Metal
import Observation
import QuartzCore
import simd

/// What the renderer and the physics need from AR for one frame.
struct ARFrameState {
  /// Portrait view axes (x right, y up, z toward you) and position, in the AR world (metres, Y up).
  var cameraToWorld: simd_float4x4
  var projection: simd_float4x4
  /// The unit-sphere bubble to the AR world, including its size.
  var bubbleToWorld: simd_float4x4
  var bubbleRotation: simd_quatf
  var carrying: Bool
  /// Where the bubble sits relative to the phone while carried, metres, phone frame.
  var carryOffset: SIMD3<Float>
  var luma: MTLTexture
  var chroma: MTLTexture
  /// Camera textures that must stay alive until the GPU has finished with them.
  var keepAlive: [AnyObject]
  /// Normalised view coordinates → normalised camera-image coordinates.
  var viewToImage: CGAffineTransform
}

/// World tracking for the AR mode. The bubble starts out carried, floating in front of
/// the phone so swinging the phone swings the gyroscope. Placing it anchors it on a
/// surface (or in mid-air if there's none); picking it up carries it again.
///
/// With `-fakeAR` on a device without world tracking (the Simulator), a synthetic camera
/// driven by the simulated phone stands in for ARKit so the projection can be tested.
@Observable
final class ARController: NSObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {
  enum Phase: Equatable {
    case off, starting, tracking, limited(String), denied, unsupported, failed(String)
  }

  private(set) var phase: Phase = .off
  private(set) var placed = false
  private(set) var isCoaching = false
  private(set) var sizeScale: Float = 1

  var isActive: Bool { phase != .off }

  /// A sentence for the status banner, or nil when tracking is fine.
  var message: String? {
    switch phase {
    case .off, .tracking: nil
    case .starting: "Move your iPhone slowly to start tracking."
    case .limited(let reason): reason
    case .denied: "Camera access is off. Enable it for Gyre in Settings to use AR."
    case .unsupported: "AR needs an iPhone with world tracking. The Simulator has none."
    case .failed(let reason): reason
    }
  }

  static let bubbleRadius: Float = 1 / Float(GyroModel.sceneScale)
  static let carryOffset = SIMD3<Float>(0, 0.035, -0.45)
  /// AR world (Y up) to the physics world (Z up).
  static let simFromAR = simd_quatd(angle: .pi / 2, axis: V3(1, 0, 0))

  @ObservationIgnored let session = ARSession()
  @ObservationIgnored let simulated =
    !ARWorldTrackingConfiguration.isSupported && ProcessInfo.processInfo.arguments.contains("-fakeAR")
  @ObservationIgnored private var cache: CVMetalTextureCache?
  @ObservationIgnored private var anchor: ARAnchor?
  /// Surface normal when resting on a surface; nil when floating in mid-air.
  @ObservationIgnored private var restNormal: SIMD3<Float>?
  @ObservationIgnored private var fakeAnchor: SIMD3<Float>?
  @ObservationIgnored private var pose: (p: SIMD3<Float>, q: simd_quatf)?
  @ObservationIgnored private var easeUntil: CFTimeInterval = 0
  @ObservationIgnored private var viewToImage = CGAffineTransform.identity
  @ObservationIgnored private var fakeLuma: MTLTexture?
  @ObservationIgnored private var fakeChroma: MTLTexture?
  @ObservationIgnored private var pinchStart: Float = 1
  /// ARKit's latest reflection map of the real room near the bubble, for the metal.
  @ObservationIgnored private(set) var environmentTexture: MTLTexture?

  // MARK: Session

  func start() {
    guard phase == .off else { return }
    placed = false
    anchor = nil
    fakeAnchor = nil
    restNormal = nil
    pose = nil
    sizeScale = 1
    if simulated {
      phase = .tracking
      return
    }
    guard ARWorldTrackingConfiguration.isSupported else {
      phase = .unsupported
      return
    }
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .denied || status == .restricted {
      phase = .denied
      return
    }
    session.delegate = self
    session.delegateQueue = .main
    session.run(configuration(), options: [.resetTracking, .removeExistingAnchors])
    phase = .starting
  }

  func stop() {
    if !simulated { session.pause() }
    phase = .off
    placed = false
    anchor = nil
    isCoaching = false
    environmentTexture = nil
  }

  /// The app went to the background: ARKit pauses itself; resume tracking on return.
  func resume() {
    guard isActive, !simulated, phase != .denied, phase != .unsupported else { return }
    session.run(configuration())
  }

  private func configuration() -> ARWorldTrackingConfiguration {
    let c = ARWorldTrackingConfiguration()
    c.planeDetection = [.horizontal, .vertical]
    c.worldAlignment = .gravity
    // ARKit builds reflection maps of the room so the holo-metal mirrors it.
    c.environmentTexturing = .automatic
    c.isLightEstimationEnabled = false
    return c
  }

  // MARK: Placement

  /// Anchors the bubble where `viewPoint` (or the bubble itself) meets a surface, sitting
  /// on it; with no surface there, it stays floating where it is.
  func place(at viewPoint: CGPoint?, viewSize: CGSize, bubbleCenter: CGPoint?) {
    guard isActive, let current = pose else { return }
    easeUntil = CACurrentMediaTime() + 0.6
    placed = true
    if simulated {
      fakeAnchor = current.p
      return
    }
    var position = current.p
    restNormal = nil
    if let frame = session.currentFrame, viewSize.width > 0, viewSize.height > 0 {
      let point = viewPoint ?? bubbleCenter ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
      let normalized = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height).applying(viewToImage)
      let query = frame.raycastQuery(from: normalized, allowing: .estimatedPlane, alignment: .any)
      if let hit = session.raycast(query).first {
        let hitPoint = hit.worldTransform.columns.3
        let camera = frame.camera.transform.columns.3
        let surface = SIMD3(hitPoint.x, hitPoint.y, hitPoint.z)
        if simd_distance(surface, SIMD3(camera.x, camera.y, camera.z)) < 4 {
          let n = hit.worldTransform.columns.1
          position = surface
          restNormal = simd_normalize(SIMD3(n.x, n.y, n.z))
        }
      }
    }
    if let old = anchor { session.remove(anchor: old) }
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4(position, 1)
    let a = ARAnchor(name: "Gyre bubble", transform: t)
    session.add(anchor: a)
    anchor = a
  }

  func pickUp() {
    guard placed else { return }
    if let old = anchor, !simulated { session.remove(anchor: old) }
    anchor = nil
    fakeAnchor = nil
    restNormal = nil
    placed = false
    sizeScale = 1
    easeUntil = CACurrentMediaTime() + 0.6
  }

  func pinch(_ factor: CGFloat, ended: Bool) {
    guard placed else { return }
    sizeScale = clamped(pinchStart * Float(factor), 0.4, 8)
    if ended { pinchStart = sizeScale }
  }

  func pinchBegan() { pinchStart = sizeScale }

  // MARK: Frames

  /// - Parameter simulatedAttitude: the simulated phone (phone → physics world), used only
  ///   by the synthetic camera.
  func frameState(viewSize: CGSize, device: MTLDevice, dt: Double, simulatedAttitude: simd_quatd) -> ARFrameState? {
    guard isActive, viewSize.width > 1, viewSize.height > 1 else { return nil }
    if simulated { return fakeFrame(viewSize: viewSize, device: device, dt: dt, attitude: simulatedAttitude) }
    guard phase != .denied, phase != .unsupported, let frame = session.currentFrame else { return nil }
    let camera = frame.camera
    let cameraToWorld = simd_inverse(camera.viewMatrix(for: .portrait))
    let projection = camera.projectionMatrix(for: .portrait, viewportSize: viewSize, zNear: 0.005, zFar: 100)
    viewToImage = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
    if let a = anchor, let updated = frame.anchors.first(where: { $0.identifier == a.identifier }) {
      anchor = updated
    }
    var anchorPoint: SIMD3<Float>?
    if let a = anchor {
      let c = a.transform.columns.3
      anchorPoint = SIMD3(c.x, c.y, c.z)
    }
    let (p, q) = ease(target: targetPose(cameraToWorld, anchorPoint: anchorPoint), dt: dt)
    // The probe nearest the bubble that has a texture yet.
    environmentTexture =
      frame.anchors.compactMap { $0 as? AREnvironmentProbeAnchor }
      .filter { $0.environmentTexture != nil }
      .min { a, b in
        simd_distance(SIMD3(a.transform.columns.3.x, a.transform.columns.3.y, a.transform.columns.3.z), p)
          < simd_distance(SIMD3(b.transform.columns.3.x, b.transform.columns.3.y, b.transform.columns.3.z), p)
      }?.environmentTexture ?? environmentTexture
    guard let (luma, chroma, refs) = textures(frame.capturedImage, device) else { return nil }
    return ARFrameState(
      cameraToWorld: cameraToWorld, projection: projection, bubbleToWorld: bubbleMatrix(p, q), bubbleRotation: q,
      carrying: !placed, carryOffset: Self.carryOffset, luma: luma, chroma: chroma, keepAlive: refs,
      viewToImage: viewToImage)
  }

  private func targetPose(_ camera: simd_float4x4, anchorPoint: SIMD3<Float>?) -> (SIMD3<Float>, simd_quatf) {
    if placed, let anchorPoint {
      let lift = (restNormal ?? .zero) * Self.bubbleRadius * sizeScale * 1.12
      return (anchorPoint + lift, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }
    let p = camera * SIMD4(Self.carryOffset, 1)
    let r = simd_float3x3(
      SIMD3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z),
      SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z),
      SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
    return (SIMD3(p.x, p.y, p.z), simd_quatf(r).normalized)
  }

  /// Glides between carried and placed poses; otherwise follows exactly.
  private func ease(target: (SIMD3<Float>, simd_quatf), dt: Double) -> (SIMD3<Float>, simd_quatf) {
    guard let current = pose, CACurrentMediaTime() < easeUntil else {
      pose = (target.0, target.1)
      return target
    }
    let k = Float(1 - exp(-dt / 0.09))
    var q = target.1
    if simd_dot(current.q.vector, q.vector) < 0 { q = simd_quatf(vector: -q.vector) }
    let next = (simd_mix(current.p, target.0, SIMD3(repeating: k)), simd_slerp(current.q, q, k).normalized)
    pose = next
    return next
  }

  private func bubbleMatrix(_ p: SIMD3<Float>, _ q: simd_quatf) -> simd_float4x4 {
    let s = Self.bubbleRadius * sizeScale
    var m = simd_float4x4(q)
    m.columns.0 *= s
    m.columns.1 *= s
    m.columns.2 *= s
    m.columns.3 = SIMD4(p, 1)
    return m
  }

  private func textures(_ buffer: CVPixelBuffer, _ device: MTLDevice) -> (MTLTexture, MTLTexture, [AnyObject])? {
    if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
    guard let cache, CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
    func plane(_ index: Int, _ format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
      let w = CVPixelBufferGetWidthOfPlane(buffer, index)
      let h = CVPixelBufferGetHeightOfPlane(buffer, index)
      var texture: CVMetalTexture?
      guard
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, index, &texture)
          == kCVReturnSuccess,
        let texture, let metal = CVMetalTextureGetTexture(texture)
      else { return nil }
      return (metal, texture)
    }
    guard let y = plane(0, .r8Unorm), let c = plane(1, .rg8Unorm) else { return nil }
    return (y.0, c.0, [y.1, c.1])
  }

  // MARK: Synthetic camera (Simulator)

  private func fakeFrame(viewSize: CGSize, device: MTLDevice, dt: Double, attitude: simd_quatd) -> ARFrameState? {
    let qPhone = (Self.simFromAR.inverse * attitude).float
    var position = SIMD3<Float>(0, 0, 0)
    if placed, let a = fakeAnchor {
      // Orbit the anchored bubble: the phone looks at it from 55 cm along its view direction.
      position = a - qPhone.act(SIMD3(0, 0, -1)) * 0.55
    }
    var cameraToWorld = simd_float4x4(qPhone)
    cameraToWorld.columns.3 = SIMD4(position, 1)
    let aspect = Float(viewSize.width / viewSize.height)
    let ys = 1 / tan(Float(62.0 * .pi / 180) / 2)
    let near: Float = 0.005, far: Float = 100
    let zs = far / (near - far)
    let projection = simd_float4x4(
      SIMD4(ys / aspect, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0))
    let (p, q) = ease(target: targetPose(cameraToWorld, anchorPoint: fakeAnchor), dt: dt)
    if fakeLuma == nil { makeFakeImage(device) }
    guard let luma = fakeLuma, let chroma = fakeChroma else { return nil }
    return ARFrameState(
      cameraToWorld: cameraToWorld, projection: projection, bubbleToWorld: bubbleMatrix(p, q), bubbleRotation: q,
      carrying: !placed, carryOffset: Self.carryOffset, luma: luma, chroma: chroma, keepAlive: [],
      viewToImage: .identity)
  }

  /// A stand-in "room": a soft gradient with a tiled floor, in camera YCbCr planes.
  private func makeFakeImage(_ device: MTLDevice) {
    let w = 256, h = 512
    var y = [UInt8](repeating: 0, count: w * h)
    for j in 0..<h {
      for i in 0..<w {
        let v = Double(j) / Double(h)
        var l = 0.55 - 0.25 * v
        if v > 0.6, ((i / 32) + (j / 32)) % 2 == 0 { l -= 0.12 }
        y[j * w + i] = UInt8(clamped(l, 0, 1) * 255)
      }
    }
    var c = [UInt8](repeating: 128, count: (w / 2) * (h / 2) * 2)
    for j in 0..<(h / 2) {
      for i in 0..<(w / 2) {
        let k = (j * (w / 2) + i) * 2
        c[k] = UInt8(140 - j / 8)
        c[k + 1] = UInt8(120 + j / 10)
      }
    }
    let ly = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
    let lc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: w / 2, height: h / 2, mipmapped: false)
    guard let ty = device.makeTexture(descriptor: ly), let tc = device.makeTexture(descriptor: lc) else { return }
    ty.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: y, bytesPerRow: w)
    tc.replace(region: MTLRegionMake2D(0, 0, w / 2, h / 2), mipmapLevel: 0, withBytes: c, bytesPerRow: w)
    fakeLuma = ty
    fakeChroma = tc
  }

  // MARK: ARSessionDelegate

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let next: Phase
    switch camera.trackingState {
    case .normal: next = .tracking
    case .notAvailable: next = .limited("Tracking isn't available right now.")
    case .limited(let reason):
      switch reason {
      case .initializing: next = .starting
      case .excessiveMotion: next = .limited("Slow down a little so tracking can keep up.")
      case .insufficientFeatures: next = .limited("Point at something with more texture or light.")
      case .relocalizing: next = .limited("Finding your place again…")
      @unknown default: next = .limited("Tracking is limited.")
      }
    }
    if phase != next, phase != .off { phase = next }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    guard phase != .off else { return }
    if let e = error as? ARError, e.code == .cameraUnauthorized {
      phase = .denied
    } else {
      phase = .failed(error.localizedDescription)
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    if phase != .off { phase = .limited("The camera was interrupted.") }
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    if phase != .off { phase = .starting }
  }

  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

  // MARK: ARCoachingOverlayViewDelegate

  func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) { isCoaching = true }
  func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) { isCoaching = false }
}
