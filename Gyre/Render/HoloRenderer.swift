import MetalKit
import QuartzCore
import SwiftUI
import simd

/// Draws the bubble each display frame:
/// 1. the world-anchored sky (or, in AR, nothing: the camera goes in at the end), rim
///    lensing, the holo-metal gyroscope, the bubble's far wall, the hologram lines, the
///    near wall (half-float scene texture with depth);
/// 2. bloom at half and quarter resolution;
/// 3. composite: camera feed under the scene in AR, a touch of chromatic aberration and
///    scanlines, soft-clipped into the display's EDR headroom so the hologram can glow
///    brighter than white.
final class HoloRenderer: NSObject, MTKViewDelegate {
  private struct Targets {
    var size: CGSize
    var scene: MTLTexture
    var depth: MTLTexture
    /// A mipmapped copy of everything inside the glass orb, for it to refract and frost.
    var behind: MTLTexture
    var halfA: MTLTexture
    var halfB: MTLTexture
    var quarterA: MTLTexture
    var quarterB: MTLTexture
  }

  /// Camera and projection for one frame.
  private struct Setup {
    var viewProj: simd_float4x4
    var eye: F4
    var centerPx: SIMD2<Float>
    var radiusPx: Float
    var focal: Float
    var basis: ViewBasis
    var reversedDepth: Bool
  }

  private struct DepthStates {
    let always: MTLDepthStencilState
    let write: MTLDepthStencilState
    let test: MTLDepthStencilState
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let background: MTLRenderPipelineState
  private let bubbleFilm: MTLRenderPipelineState
  private let bubbleLens: MTLRenderPipelineState
  private let lines: MTLRenderPipelineState
  private let metal: MTLRenderPipelineState
  private let planet: MTLRenderPipelineState
  private let glassFront: MTLRenderPipelineState
  private let glassBack: MTLRenderPipelineState
  private let prefilter: MTLRenderPipelineState
  private let copy: MTLRenderPipelineState
  private let blur: MTLRenderPipelineState
  private let composite: MTLRenderPipelineState
  private let depthStandard: DepthStates
  private let depthReversed: DepthStates
  private let sphereVertices: MTLBuffer
  private let sphereIndices: MTLBuffer
  private let sphereIndexCount: Int
  private let rotorMesh: GPUMesh
  private let boltMesh: GPUMesh
  private let ringMesh: GPUMesh
  private let rodMesh: GPUMesh
  private let ballMesh: GPUMesh
  private let globeMesh: GPUMesh
  private let topMesh: GPUMesh
  private let pointMesh: GPUMesh
  private let planetRingMesh: GPUMesh
  private let blankCube: MTLTexture
  private let blankLuma: MTLTexture
  private let blankChroma: MTLTexture
  private var lineBuffers: [MTLBuffer?] = [nil, nil, nil]
  private var frame = 0
  private let inflight = DispatchSemaphore(value: 3)
  private var targets: Targets?
  private var builder = HoloSceneBuilder()
  private weak var model: GyroModel?
  private var lastTime: CFTimeInterval = 0
  private let startTime = CACurrentMediaTime()
  private var center = CGPoint.zero
  private var radius: CGFloat = 0

  private static let sceneFormat: MTLPixelFormat = .rgba16Float
  private static let depthFormat: MTLPixelFormat = .depth32Float

  init?(view: MTKView, model: GyroModel) {
    guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let library = device.makeDefaultLibrary()
    else { return nil }
    self.device = device
    self.queue = queue
    self.model = model

    func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Blend, depth: Bool) -> MTLRenderPipelineState? {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = library.makeFunction(name: vertex)
      d.fragmentFunction = library.makeFunction(name: fragment)
      if depth { d.depthAttachmentPixelFormat = Self.depthFormat }
      let a = d.colorAttachments[0]!
      a.pixelFormat = format
      switch blend {
      case .none:
        a.isBlendingEnabled = false
      case .add:
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .zero
        a.destinationAlphaBlendFactor = .one
      case .alpha:
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .sourceAlpha
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.sourceAlphaBlendFactor = .one
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      }
      return try? device.makeRenderPipelineState(descriptor: d)
    }

    let f = Self.sceneFormat
    guard
      let background = pipeline("fullscreenVertex", "backgroundFragment", format: f, blend: .none, depth: true),
      let bubbleFilm = pipeline("bubbleVertex", "bubbleFilmFragment", format: f, blend: .add, depth: true),
      let bubbleLens = pipeline("bubbleVertex", "bubbleLensFragment", format: f, blend: .alpha, depth: true),
      let lines = pipeline("lineVertex", "lineFragment", format: f, blend: .add, depth: true),
      let metal = pipeline("meshVertex", "metalFragment", format: f, blend: .none, depth: true),
      let planet = pipeline("meshVertex", "planetFragment", format: f, blend: .none, depth: true),
      let glassFront = pipeline("meshVertex", "glassOrbFragment", format: f, blend: .none, depth: true),
      let glassBack = pipeline("meshVertex", "glassOrbBackFragment", format: f, blend: .add, depth: true),
      let prefilter = pipeline("fullscreenVertex", "prefilterFragment", format: f, blend: .none, depth: false),
      let copy = pipeline("fullscreenVertex", "copyFragment", format: f, blend: .none, depth: false),
      let blur = pipeline("fullscreenVertex", "blurFragment", format: f, blend: .none, depth: false),
      let composite = pipeline(
        "fullscreenVertex", "compositeFragment", format: view.colorPixelFormat, blend: .none, depth: false)
    else { return nil }
    self.background = background
    self.bubbleFilm = bubbleFilm
    self.bubbleLens = bubbleLens
    self.lines = lines
    self.metal = metal
    self.planet = planet
    self.glassFront = glassFront
    self.glassBack = glassBack
    self.prefilter = prefilter
    self.copy = copy
    self.blur = blur
    self.composite = composite

    func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
      let d = MTLDepthStencilDescriptor()
      d.depthCompareFunction = compare
      d.isDepthWriteEnabled = write
      return device.makeDepthStencilState(descriptor: d)
    }
    guard let always = depthState(.always, write: false),
      let writeLess = depthState(.lessEqual, write: true), let testLess = depthState(.lessEqual, write: false),
      let writeMore = depthState(.greaterEqual, write: true), let testMore = depthState(.greaterEqual, write: false)
    else { return nil }
    depthStandard = DepthStates(always: always, write: writeLess, test: testLess)
    depthReversed = DepthStates(always: always, write: writeMore, test: testMore)

    let (vertices, indices) = Self.sphere(stacks: 48, slices: 96)
    guard
      let vb = device.makeBuffer(bytes: vertices, length: MemoryLayout<F4>.stride * vertices.count),
      let ib = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count),
      let rotor = GyroMeshes.rotor(device), let bolts = GyroMeshes.bolts(device),
      let ring = GyroMeshes.ring(device), let rod = GyroMeshes.rod(device), let ball = GyroMeshes.ball(device),
      let globe = GyroMeshes.globe(device), let top = GyroMeshes.topUpper(device), let point = GyroMeshes.topPoint(device),
      let planetRing = GyroMeshes.planetRing(inner: 1.3, outer: 1.9, device)
    else { return nil }
    sphereVertices = vb
    sphereIndices = ib
    sphereIndexCount = indices.count
    rotorMesh = rotor
    boltMesh = bolts
    ringMesh = ring
    rodMesh = rod
    ballMesh = ball
    globeMesh = globe
    topMesh = top
    pointMesh = point
    planetRingMesh = planetRing

    let cube = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm, size: 1, mipmapped: false)
    let luma = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
    let chroma = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
    guard let bc = device.makeTexture(descriptor: cube), let bl = device.makeTexture(descriptor: luma),
      let bch = device.makeTexture(descriptor: chroma)
    else { return nil }
    blankCube = bc
    blankLuma = bl
    blankChroma = bch
    super.init()
  }

  private enum Blend { case none, add, alpha }

  /// A UV sphere wound counter-clockwise as seen from outside.
  private static func sphere(stacks: Int, slices: Int) -> ([F4], [UInt32]) {
    var verts: [F4] = []
    for i in 0...stacks {
      let theta = Float(i) / Float(stacks) * .pi
      for j in 0...slices {
        let phi = Float(j) / Float(slices) * 2 * .pi
        verts.append(F4(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi), 0))
      }
    }
    var idx: [UInt32] = []
    let row = UInt32(slices + 1)
    for i in 0..<UInt32(stacks) {
      for j in 0..<UInt32(slices) {
        let a = i * row + j
        let b = a + row
        idx += [a, b, a + 1, a + 1, b, b + 1]
      }
    }
    // Check one mid-latitude triangle's winding and flip all if it faces inward.
    let probe = (stacks / 2) * 6 * slices
    let p0 = verts[Int(idx[probe])], p1 = verts[Int(idx[probe + 1])], p2 = verts[Int(idx[probe + 2])]
    let a = F3(p0.x, p0.y, p0.z), b = F3(p1.x, p1.y, p1.z), c = F3(p2.x, p2.y, p2.z)
    if simd_dot(simd_cross(b - a, c - a), a) < 0 {
      for t in stride(from: 0, to: idx.count, by: 3) { idx.swapAt(t + 1, t + 2) }
    }
    return (verts, idx)
  }

  private func makeTargets(_ size: CGSize) -> Targets? {
    func tex(_ w: Int, _ h: Int, _ format: MTLPixelFormat = Self.sceneFormat) -> MTLTexture? {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
      d.usage = format == Self.depthFormat ? [.renderTarget] : [.renderTarget, .shaderRead]
      d.storageMode = .private
      return device.makeTexture(descriptor: d)
    }
    let w = Int(size.width), h = Int(size.height)
    let mips = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: Self.sceneFormat, width: max(w, 1), height: max(h, 1), mipmapped: true)
    mips.usage = [.shaderRead]
    mips.storageMode = .private
    guard let s = tex(w, h), let z = tex(w, h, Self.depthFormat), let behind = device.makeTexture(descriptor: mips),
      let ha = tex(w / 2, h / 2), let hb = tex(w / 2, h / 2), let qa = tex(w / 4, h / 4), let qb = tex(w / 4, h / 4)
    else { return nil }
    return Targets(
      size: size, scene: s, depth: z, behind: behind, halfA: ha, halfB: hb, quarterA: qa, quarterB: qb)
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    targets = nil
  }

  // MARK: Frame

  func draw(in view: MTKView) {
    guard let model else { return }
    let now = CACurrentMediaTime()
    let dt = lastTime == 0 ? 1.0 / 120 : min(now - lastTime, 1.0 / 15)
    lastTime = now
    let viewSize = view.bounds.size
    model.windowSize = viewSize
    let ar =
      model.ar.isActive
      ? model.ar.frameState(viewSize: viewSize, device: device, dt: dt, simulatedAttitude: model.motion.last.attitude)
      : nil
    model.advance(dt: dt, ar: ar)

    let size = view.drawableSize
    guard size.width > 8, size.height > 8 else { return }
    if targets?.size != size { targets = makeTargets(size) }
    guard let targets, let drawable = view.currentDrawable else { return }

    let scale = Float(view.contentScaleFactor)
    let time = Float(now - startTime)
    let reduceMotion = model.reduceMotion
    let setup =
      ar.flatMap { arSetup($0, size: size, scale: scale, model: model) }
      ?? phoneSetup(view: view, model: model, size: size, scale: scale, dt: dt)
    if ar == nil { model.arScreen = nil }
    builder.pxScale = scale
    builder.build(model: model, time: time, reduceMotion: reduceMotion, view: setup.basis)
    var uniforms = makeUniforms(
      model: model, view: view, size: size, time: time, reduceMotion: reduceMotion, setup: setup, ar: ar)
    let depth = setup.reversedDepth ? depthReversed : depthStandard
    let probe = ar.flatMap { _ in model.ar.environmentTexture } ?? blankCube
    let luma = ar?.luma ?? blankLuma
    let chroma = ar?.chroma ?? blankChroma

    inflight.wait()
    frame = (frame + 1) % 3
    let count = builder.lines.count
    let needed = max(count, 1) * MemoryLayout<LineInstance>.stride
    if (lineBuffers[frame]?.length ?? 0) < needed {
      lineBuffers[frame] = device.makeBuffer(length: needed * 2, options: .storageModeShared)
    }
    guard let lineBuffer = lineBuffers[frame], let cmd = queue.makeCommandBuffer() else {
      inflight.signal()
      return
    }
    builder.lines.withUnsafeBytes { raw in
      if let base = raw.baseAddress { lineBuffer.contents().copyMemory(from: base, byteCount: raw.count) }
    }
    let semaphore = inflight
    let keepAlive = ar?.keepAlive ?? []
    cmd.addCompletedHandler { _ in
      _ = keepAlive
      semaphore.signal()
    }

    let uSize = MemoryLayout<HoloUniforms>.stride

    // 1. Scene. With the glass orb it takes two passes: everything inside the orb, then a
    // mipmapped copy for the orb to refract, then the orb and everything in front of it.
    let orb = model.object == .glassOrb
    let inner = orb ? builder.objectLineCount : count
    let scenePass = pass(targets.scene, clear: true, alpha: ar == nil ? 1 : 0)
    scenePass.depthAttachment.texture = targets.depth
    scenePass.depthAttachment.loadAction = .clear
    scenePass.depthAttachment.clearDepth = setup.reversedDepth ? 0 : 1
    scenePass.depthAttachment.storeAction = orb ? .store : .dontCare
    if let enc = cmd.makeRenderCommandEncoder(descriptor: scenePass) {
      enc.setFrontFacing(.counterClockwise)
      bindScene(enc, &uniforms, probe: probe, luma: luma, chroma: chroma)
      if ar == nil {
        enc.setDepthStencilState(depth.always)
        enc.setRenderPipelineState(background)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }

      enc.setDepthStencilState(depth.test)
      enc.setVertexBuffer(sphereVertices, offset: 0, index: 0)
      enc.setRenderPipelineState(bubbleLens)
      enc.setCullMode(.back)
      drawSphere(enc)

      if model.metalGyro {
        enc.setDepthStencilState(depth.write)
        drawObject(enc, model.object, pose: builder.pose, glass: model.glass, uniforms: &uniforms)
      }

      enc.setDepthStencilState(depth.test)
      enc.setRenderPipelineState(bubbleFilm)
      enc.setVertexBuffer(sphereVertices, offset: 0, index: 0)
      enc.setCullMode(.front)
      drawSphere(enc)

      if orb {
        enc.setRenderPipelineState(glassBack)
        enc.setCullMode(.front)
        drawOrb(enc, pose: builder.pose, glass: model.glass, uniforms: &uniforms)
      }

      drawLines(enc, lineBuffer, from: 0, to: inner, uniforms: &uniforms)
      if !orb {
        enc.setRenderPipelineState(bubbleFilm)
        enc.setVertexBuffer(sphereVertices, offset: 0, index: 0)
        enc.setCullMode(.back)
        drawSphere(enc)
      }
      enc.endEncoding()
    }

    if orb {
      if let blit = cmd.makeBlitCommandEncoder() {
        blit.copy(
          from: targets.scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
          sourceSize: MTLSize(width: targets.scene.width, height: targets.scene.height, depth: 1),
          to: targets.behind, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: targets.behind)
        blit.endEncoding()
      }
      let front = MTLRenderPassDescriptor()
      front.colorAttachments[0].texture = targets.scene
      front.colorAttachments[0].loadAction = .load
      front.colorAttachments[0].storeAction = .store
      front.depthAttachment.texture = targets.depth
      front.depthAttachment.loadAction = .load
      front.depthAttachment.storeAction = .dontCare
      if let enc = cmd.makeRenderCommandEncoder(descriptor: front) {
        enc.setFrontFacing(.counterClockwise)
        bindScene(enc, &uniforms, probe: probe, luma: luma, chroma: chroma)
        enc.setFragmentTexture(targets.behind, index: 3)
        enc.setDepthStencilState(depth.test)
        enc.setRenderPipelineState(glassFront)
        enc.setCullMode(.back)
        drawOrb(enc, pose: builder.pose, glass: model.glass, uniforms: &uniforms)
        drawLines(enc, lineBuffer, from: inner, to: count, uniforms: &uniforms)
        enc.setRenderPipelineState(bubbleFilm)
        enc.setVertexBuffer(sphereVertices, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<HoloUniforms>.stride, index: 1)
        enc.setCullMode(.back)
        drawSphere(enc)
        enc.endEncoding()
      }
    }

    // 2. Bloom.
    fullscreen(cmd, prefilter, from: targets.scene, to: targets.halfA)
    blurPass(cmd, from: targets.halfA, to: targets.halfB, step: SIMD2(1.4 / Float(targets.halfA.width), 0))
    blurPass(cmd, from: targets.halfB, to: targets.halfA, step: SIMD2(0, 1.4 / Float(targets.halfA.height)))
    fullscreen(cmd, copy, from: targets.halfA, to: targets.quarterA)
    blurPass(cmd, from: targets.quarterA, to: targets.quarterB, step: SIMD2(2.2 / Float(targets.quarterA.width), 0))
    blurPass(cmd, from: targets.quarterB, to: targets.quarterA, step: SIMD2(0, 2.2 / Float(targets.quarterA.height)))

    // 3. Composite to the screen.
    if let enc = cmd.makeRenderCommandEncoder(descriptor: pass(drawable.texture, clear: false)) {
      enc.setRenderPipelineState(composite)
      enc.setFragmentTexture(targets.scene, index: 0)
      enc.setFragmentTexture(targets.halfA, index: 1)
      enc.setFragmentTexture(targets.quarterA, index: 2)
      enc.setFragmentTexture(luma, index: 3)
      enc.setFragmentTexture(chroma, index: 4)
      enc.setFragmentBytes(&uniforms, length: uSize, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.endEncoding()
    }
    cmd.present(drawable)
    cmd.commit()
  }

  // MARK: Cameras

  /// The phone as a window: a fixed camera in front of the screen, the bubble eased toward
  /// its place in the layout.
  private func phoneSetup(view: MTKView, model: GyroModel, size: CGSize, scale: Float, dt: Double) -> Setup {
    let layout = model.bubbleLayout
    let target =
      layout.radius > 1 ? layout : (CGPoint(x: view.bounds.midX, y: view.bounds.midY * 0.8), view.bounds.width * 0.42)
    if radius == 0 {
      center = target.0
      radius = target.1
    } else {
      let k = CGFloat(1 - exp(-dt / 0.12))
      center.x += (target.0.x - center.x) * k
      center.y += (target.0.y - center.y) * k
      radius += (target.1 - radius) * k
    }
    let w = Float(size.width), h = Float(size.height)
    let cx = Float(center.x) * scale, cy = Float(center.y) * scale
    let rPx = Float(radius) * scale
    let d = Float(GyroModel.cameraDistance)
    let f = rPx * (d * d - 1).squareRoot()
    // Perspective about the bubble's centre on screen; depth 0…1 between 0.5 and 10.
    let near: Float = 0.5, far: Float = 10
    let a = far / (far - near), b = far * near / (far - near)
    let ox = 2 * cx / w - 1, oy = 1 - 2 * cy / h
    let viewProj = simd_float4x4(
      F4(2 * f / w, 0, 0, 0),
      F4(0, 2 * f / h, 0, 0),
      F4(-ox, -oy, -a, -1),
      F4(ox * d, oy * d, a * d - b, d))
    return Setup(
      viewProj: viewProj, eye: F4(0, 0, d, 0), centerPx: SIMD2(cx, cy), radiusPx: rPx, focal: f,
      basis: ViewBasis(eye: F3(0, 0, d), widthScale: clamped(Float(radius) / 170, 0.7, 1.5)), reversedDepth: false)
  }

  /// ARKit's camera looking at the anchored (or carried) bubble.
  private func arSetup(_ ar: ARFrameState, size: CGSize, scale: Float, model: GyroModel) -> Setup? {
    let viewProj = ar.projection * simd_inverse(ar.cameraToWorld) * ar.bubbleToWorld
    let toBubble = simd_inverse(ar.bubbleToWorld)
    let eye4 = toBubble * ar.cameraToWorld.columns.3
    let eye = F3(eye4.x, eye4.y, eye4.z)
    let up4 = toBubble * ar.cameraToWorld.columns.1
    let toEye = eye.unit
    let right = simd_cross(F3(up4.x, up4.y, up4.z).unit, toEye).unit
    let up = simd_cross(toEye, right)
    let w = Float(size.width), h = Float(size.height)
    func px(_ p: F3) -> SIMD2<Float>? {
      let c = viewProj * F4(p, 1)
      guard c.w > 1e-4 else { return nil }
      return SIMD2((c.x / c.w + 1) * 0.5 * w, (1 - c.y / c.w) * 0.5 * h)
    }
    let centerPx = px(.zero) ?? SIMD2(-9999, -9999)
    let edgePx = px(right) ?? centerPx
    let rPx = simd_distance(centerPx, edgePx)
    let nearZ = ar.projection * F4(0, 0, -0.3, 1)
    let farZ = ar.projection * F4(0, 0, -3, 1)
    let reversed = farZ.z / farZ.w < nearZ.z / nearZ.w
    model.arScreen = (CGPoint(x: CGFloat(centerPx.x / scale), y: CGFloat(centerPx.y / scale)), CGFloat(rPx / scale))
    return Setup(
      viewProj: viewProj, eye: F4(eye, 1), centerPx: centerPx, radiusPx: rPx, focal: 1,
      basis: ViewBasis(eye: eye, toEye: toEye, right: right, up: up, widthScale: clamped(rPx / (170 * scale), 0.3, 2.5)),
      reversedDepth: reversed)
  }

  // MARK: Objects

  private func bindScene(
    _ enc: MTLRenderCommandEncoder, _ uniforms: inout HoloUniforms, probe: MTLTexture, luma: MTLTexture,
    chroma: MTLTexture
  ) {
    enc.setVertexBytes(&uniforms, length: MemoryLayout<HoloUniforms>.stride, index: 1)
    enc.setFragmentBytes(&uniforms, length: MemoryLayout<HoloUniforms>.stride, index: 0)
    enc.setFragmentTexture(probe, index: 0)
    enc.setFragmentTexture(luma, index: 1)
    enc.setFragmentTexture(chroma, index: 2)
  }

  private func drawLines(
    _ enc: MTLRenderCommandEncoder, _ buffer: MTLBuffer, from: Int, to: Int, uniforms: inout HoloUniforms
  ) {
    guard to > from else { return }
    enc.setCullMode(.none)
    enc.setRenderPipelineState(lines)
    enc.setVertexBuffer(buffer, offset: 0, index: 0)
    enc.setVertexBytes(&uniforms, length: MemoryLayout<HoloUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: to - from, baseInstance: from)
  }

  private func draw(
    _ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, _ m: MeshUniforms, uniforms: inout HoloUniforms
  ) {
    var m = m
    m.normalModel = simd_transpose(simd_inverse(m.model))
    let size = MemoryLayout<MeshUniforms>.stride
    enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
    enc.setVertexBytes(&uniforms, length: MemoryLayout<HoloUniforms>.stride, index: 1)
    enc.setVertexBytes(&m, length: size, index: 2)
    enc.setFragmentBytes(&m, length: size, index: 1)
    enc.drawIndexedPrimitives(
      type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
  }

  /// The object's frame: cage axes and spin axis at the rotor's centre of mass.
  private func frame(_ p: GyroPose) -> simd_float4x4 {
    simd_float4x4(basis: p.u, p.v, p.e, origin: p.center)
  }

  /// The reference direction that turns with the spin.
  private func spun(_ p: GyroPose) -> F4 {
    F4(cos(p.spinAngle) * p.u + sin(p.spinAngle) * p.v, p.sweep)
  }

  private func drawObject(
    _ enc: MTLRenderCommandEncoder, _ object: GyroObject, pose p: GyroPose, glass: GlassParams,
    uniforms: inout HoloUniforms
  ) {
    enc.setCullMode(.back)
    switch object {
    case .wireframe:
      break
    case .gyroscope, .glassOrb:
      enc.setRenderPipelineState(metal)
      drawGyroscope(enc, pose: p, uniforms: &uniforms)
    case .top:
      enc.setRenderPipelineState(metal)
      drawTop(enc, pose: p, uniforms: &uniforms)
    case .planet:
      enc.setRenderPipelineState(planet)
      drawPlanet(enc, pose: p, uniforms: &uniforms)
    }
  }

  /// The holo-metal gyroscope: a turned rotor (spinning, circularly brushed), its bolts
  /// until they blur away, three cage rings, the axle and its end knobs.
  private func drawGyroscope(_ enc: MTLRenderCommandEncoder, pose p: GyroPose, uniforms: inout HoloUniforms) {
    let f = frame(p)
    let r = p.rotorRadius
    let spin = simd_float4x4(simd_quatf(angle: p.spinAngle, axis: F3(0, 0, 1)))
    func part(_ model: simd_float4x4, _ material: F4, _ base: F4, brushed: Bool = false) -> MeshUniforms {
      MeshUniforms(
        model: model, material: material, base: base, spinCenter: F4(p.center, brushed ? 1 : 0),
        spinAxis: F4(p.e, 0), spinU: spun(p), extra: F4(r, 0, 0, 0))
    }

    let rotor = f * spin * simd_float4x4(scale: F3(repeating: r))
    draw(enc, rotorMesh, part(rotor, F4(0.24, 0.8, 0.55, 0.5), F4(0.96, 0.95, 0.93, 0), brushed: true), uniforms: &uniforms)
    if abs(p.sweep) < 0.6 {
      draw(enc, boltMesh, part(rotor, F4(0.14, 0, 0.35, 0.35), F4(1.0, 0.84, 0.58, 0)), uniforms: &uniforms)
    }

    let cage = simd_float4x4(scale: F3(repeating: p.cageRadius))
    let quarterX = simd_float4x4(simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0)))
    let quarterY = simd_float4x4(simd_quatf(angle: .pi / 2, axis: F3(0, 1, 0)))
    let cageMaterial = F4(0.3, 0, 0.95, 0.85)
    let cageBase = F4(0.82, 0.78, 0.96, 0)
    for turn in [matrix_identity_float4x4, quarterX, quarterY] {
      draw(enc, ringMesh, part(f * turn * cage, cageMaterial, cageBase), uniforms: &uniforms)
    }

    let z0 = min(-p.ell, -p.axleHalf)
    let z1 = max(-p.ell, p.axleHalf)
    let axle = f * simd_float4x4(translation: F3(0, 0, z0)) * simd_float4x4(scale: F3(0.045 * r, 0.045 * r, z1 - z0))
    draw(enc, rodMesh, part(axle, F4(0.1, 0, 0.25, 0.5), F4(0.9, 0.92, 0.96, 0)), uniforms: &uniforms)
    for end: Float in [p.axleHalf, -p.axleHalf] {
      let knob = f * simd_float4x4(translation: F3(0, 0, end)) * simd_float4x4(scale: F3(repeating: 0.1 * r))
      draw(enc, ballMesh, part(knob, F4(0.07, 0, 0.6, 0.6), F4(0.95, 0.93, 0.98, 0)), uniforms: &uniforms)
    }
  }

  /// A machined titanium top, Inception-style: one turned piece, brushed around its axis
  /// so highlights streak radially, its point stretched to reach the pivot.
  private func drawTop(_ enc: MTLRenderCommandEncoder, pose p: GyroPose, uniforms: inout HoloUniforms) {
    let f = frame(p)
    let r = p.rotorRadius
    let spin = simd_float4x4(simd_quatf(angle: p.spinAngle, axis: F3(0, 0, 1)))
    // Titanium's reflectance, untinted: no anodising, a faint holographic rim.
    let titanium = F4(0.542, 0.497, 0.449, 0)
    let finish = F4(0.3, 0.85, 0, 0.08)
    func part(_ model: simd_float4x4) -> MeshUniforms {
      MeshUniforms(
        model: model, material: finish, base: titanium, spinCenter: F4(p.center, 1), spinAxis: F4(p.e, 1),
        spinU: spun(p), extra: F4(r, 1.8, 0, 0))
    }
    draw(enc, topMesh, part(f * spin * simd_float4x4(scale: F3(repeating: r))), uniforms: &uniforms)
    let junction = GyroMeshes.topJunction * r
    let natural = (0.78 + GyroMeshes.topJunction) * r
    let length = p.ell > 0.3 * r ? p.ell + junction : natural
    let point = f * spin * simd_float4x4(translation: F3(0, 0, junction)) * simd_float4x4(scale: F3(r, r, max(length, 0.2 * r)))
    draw(enc, pointMesh, part(point), uniforms: &uniforms)
  }

  /// A ringed gas giant spinning about the axis.
  private func drawPlanet(_ enc: MTLRenderCommandEncoder, pose p: GyroPose, uniforms: inout HoloUniforms) {
    let f = frame(p)
    let radius = p.rotorRadius * 0.95
    let spin = simd_float4x4(simd_quatf(angle: p.spinAngle, axis: F3(0, 0, 1)))
    let body = f * spin * simd_float4x4(scale: F3(repeating: radius))
    let info = { (model: simd_float4x4, mode: Float) in
      MeshUniforms(
        model: model, material: .zero, base: .zero, spinCenter: F4(p.center, 0), spinAxis: F4(p.e, mode),
        spinU: self.spun(p), extra: F4(radius, 0, 0, 0))
    }
    draw(enc, globeMesh, info(body, 2), uniforms: &uniforms)
    enc.setCullMode(.none)
    draw(enc, planetRingMesh, info(f * simd_float4x4(scale: F3(repeating: radius)), 3), uniforms: &uniforms)
    enc.setCullMode(.back)
  }

  /// The glass orb around the gyroscope, fixed to its cage so its scratches turn with it.
  private func drawOrb(_ enc: MTLRenderCommandEncoder, pose p: GyroPose, glass: GlassParams, uniforms: inout HoloUniforms) {
    let radius = max(p.cageRadius, p.axleHalf) * 1.1
    let model = frame(p) * simd_float4x4(scale: F3(repeating: radius))
    let m = MeshUniforms(
      model: model, material: .zero, base: .zero, spinCenter: F4(p.center, 0), spinAxis: F4(p.e, 0),
      spinU: F4(p.u, 0), extra: F4(radius, Float(glass.refraction), Float(glass.frost), Float(glass.dispersion)))
    draw(enc, globeMesh, m, uniforms: &uniforms)
  }

  // MARK: Passes

  private func drawSphere(_ enc: MTLRenderCommandEncoder) {
    enc.drawIndexedPrimitives(
      type: .triangle, indexCount: sphereIndexCount, indexType: .uint32, indexBuffer: sphereIndices, indexBufferOffset: 0)
  }

  private func pass(_ texture: MTLTexture, clear: Bool, alpha: Double = 1) -> MTLRenderPassDescriptor {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = texture
    d.colorAttachments[0].loadAction = clear ? .clear : .dontCare
    d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: alpha)
    d.colorAttachments[0].storeAction = .store
    return d
  }

  private func fullscreen(_ cmd: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, from: MTLTexture, to: MTLTexture) {
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass(to, clear: false)) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(from, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func blurPass(_ cmd: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, step: SIMD2<Float>) {
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass(to, clear: false)) else { return }
    var s = step
    enc.setRenderPipelineState(blur)
    enc.setFragmentTexture(from, index: 0)
    enc.setFragmentBytes(&s, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func makeUniforms(
    model m: GyroModel, view: MTKView, size: CGSize, time: Float, reduceMotion: Bool, setup: Setup,
    ar: ARFrameState?
  ) -> HoloUniforms {
    let attitude = m.sample.attitude
    let inverse = attitude.inverse
    var u = HoloUniforms()
    u.attitude = simd_float4x4(attitude.float)
    u.viewProj = setup.viewProj
    u.viewport = F4(Float(size.width), Float(size.height), setup.centerPx.x, setup.centerPx.y)
    let headroom = Float(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
    u.camera = F4(setup.focal, Float(GyroModel.cameraDistance), time, headroom)
    let fall = inverse.act(m.sim.effectiveGravity.unit).f
    u.gravity = F4(fall, Float(m.sim.effectiveGravity.length / GyroSim.g0))
    u.jiggle = F4(m.jiggle.d, reduceMotion ? 0 : 0.004 * sin(time * 0.9))
    let field = attitude.act(m.sample.magneticField)
    let hasNorth: Float = hypot(field.x, field.y) > 5 ? 1 : 0
    u.film = F4(1, reduceMotion ? 0.3 : 0.6 + Float(min(m.params.air, 2)) * 0.4, Float(atan2(field.y, field.x)), hasNorth)
    u.post = F4(0.6, reduceMotion ? 0 : 0.04, 0.0022, reduceMotion ? 1 : 0)
    u.lightA = F4(inverse.act(V3(0.25, -0.45, 0.86).unit).f, 1.1)
    u.lightB = F4(inverse.act(V3(-0.7, 0.5, 0.2).unit).f, 0.45)
    let hasProbe: Float = ar != nil && m.ar.environmentTexture != nil ? 1 : 0
    u.misc = F4(setup.radiusPx, builder.bandY, builder.flicker, hasProbe)
    u.eye = setup.eye
    let t = ar?.viewToImage ?? .identity
    u.camA = F4(Float(t.a), Float(t.b), Float(t.c), Float(t.d))
    u.camB = F4(Float(t.tx), Float(t.ty), reduceMotion ? 0 : Float(m.filmDrive), 0)
    var r = [F4](repeating: F4(0, 0, 0, -1), count: 4)
    if !reduceMotion {
      for (i, ripple) in m.ripples.suffix(4).enumerated() {
        r[i] = F4(ripple.direction, Float(m.clock - ripple.start))
      }
    }
    u.ripples = (r[0], r[1], r[2], r[3])
    return u
  }
}

/// The Metal hologram, edge to edge behind the interface.
struct HoloView: UIViewRepresentable {
  let model: GyroModel

  final class Coordinator {
    var renderer: HoloRenderer?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .rgba16Float
    view.framebufferOnly = true
    view.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
    view.isOpaque = true
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    if let layer = view.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }
    context.coordinator.renderer = HoloRenderer(view: view, model: model)
    view.delegate = context.coordinator.renderer
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    view.isPaused = !model.isRunning
    // ARKit delivers camera frames at 60 Hz.
    view.preferredFramesPerSecond = model.ar.isActive || ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
  }
}
