import CoreMotion
import Foundation
import simd

/// One reading of the phone's motion sensors, fused by Core Motion.
struct MotionSample {
  /// Rotates phone-frame vectors into the world frame (Z up).
  var attitude: simd_quatd
  /// Gyroscope, bias-corrected, phone frame, rad/s.
  var rotationRate: V3
  /// Phone frame, g.
  var gravity: V3
  /// Accelerometer minus gravity, phone frame, g.
  var userAcceleration: V3
  /// Calibrated magnetometer, phone frame, µT.
  var magneticField: V3
  var fieldCalibrated: Bool

  static func pose(pitch: Double, yaw: Double = 0, roll: Double = 0) -> simd_quatd {
    simd_quatd(angle: yaw, axis: V3(0, 0, 1)) * simd_quatd(angle: pitch, axis: V3(1, 0, 0))
      * simd_quatd(angle: roll, axis: V3(0, 1, 0))
  }

  /// A magnetic field like the northern hemisphere's, for the simulated phone.
  static let simulatedField = V3(0, 22, -40)

  static func at(_ q: simd_quatd, rate: V3 = .zero) -> MotionSample {
    MotionSample(
      attitude: q, rotationRate: rate, gravity: q.inverse.act(V3(0, 0, -1)),
      userAcceleration: .zero, magneticField: q.inverse.act(simulatedField), fieldCalibrated: true)
  }

  /// Held upright, leaning back 30°, as you'd hold it to look at the screen.
  static let resting = at(pose(pitch: 60 * .pi / 180))
}

/// Gyroscope, accelerometer and magnetometer through Core Motion's sensor fusion, plus the
/// barometer on request. Without motion hardware (the Simulator) it simulates a phone that
/// you tilt by dragging, or that sways by itself with the `-simSway` launch argument.
final class MotionSource {
  private let manager = CMMotionManager()
  private let altimeter = CMAltimeter()
  private(set) var isLive = false
  private(set) var pressureKPa: Double?
  let barometerAvailable = CMAltimeter.isRelativeAltitudeAvailable()
  private var invertAttitude: Bool?
  /// The latest raw reading (before any AR reframing).
  private(set) var last = MotionSample.resting

  var simYaw = 0.0
  var simPitch = 60.0 * .pi / 180
  var simRoll = 0.0
  var simSway = ProcessInfo.processInfo.arguments.contains("-simSway")
  private var simTime = 0.0

  func start() {
    guard manager.isDeviceMotionAvailable else {
      isLive = false
      return
    }
    guard !manager.isDeviceMotionActive else { return }
    manager.deviceMotionUpdateInterval = 1.0 / 120.0
    manager.showsDeviceMovementDisplay = false
    let frames = CMMotionManager.availableAttitudeReferenceFrames()
    // Magnetometer-corrected yaw stops the world frame from slowly drifting.
    let frame: CMAttitudeReferenceFrame =
      frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
    manager.startDeviceMotionUpdates(using: frame)
    isLive = true
  }

  func stop() {
    manager.stopDeviceMotionUpdates()
    altimeter.stopRelativeAltitudeUpdates()
  }

  func startBarometer() {
    guard barometerAvailable else { return }
    altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
      if let data { self?.pressureKPa = data.pressure.doubleValue }
    }
  }

  func stopBarometer() {
    altimeter.stopRelativeAltitudeUpdates()
    pressureKPa = nil
  }

  func sample(dt: Double) -> MotionSample {
    if isLive {
      if let m = manager.deviceMotion { last = convert(m) }
      return last
    }
    last = simulate(dt: dt)
    return last
  }

  private func convert(_ m: CMDeviceMotion) -> MotionSample {
    let cq = m.attitude.quaternion
    var q = simd_quatd(ix: cq.x, iy: cq.y, iz: cq.z, r: cq.w).normalized
    let gravity = V3(m.gravity.x, m.gravity.y, m.gravity.z)
    // Confirm the quaternion's direction against measured gravity once the phone is tilted
    // enough for the two conventions to disagree.
    if invertAttitude == nil, simd_length(gravity) > 0.5 {
      let direct = simd_dot(q.inverse.act(V3(0, 0, -1)), gravity)
      let inverted = simd_dot(q.act(V3(0, 0, -1)), gravity)
      if abs(direct - inverted) > 0.3 { invertAttitude = inverted > direct }
    }
    if invertAttitude == true { q = q.inverse }
    let field = m.magneticField
    return MotionSample(
      attitude: q,
      rotationRate: V3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
      gravity: gravity,
      userAcceleration: V3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
      magneticField: V3(field.field.x, field.field.y, field.field.z),
      fieldCalibrated: field.accuracy != .uncalibrated)
  }

  private func simulate(dt: Double) -> MotionSample {
    simTime += dt
    var yaw = simYaw
    var pitch = simPitch
    var roll = simRoll
    if simSway {
      yaw += 0.9 * sin(simTime * 0.31)
      pitch += 0.3 * sin(simTime * 0.23 + 1)
      roll += 0.25 * sin(simTime * 0.17)
    }
    let q = MotionSample.pose(pitch: pitch, yaw: yaw, roll: roll)
    var rate = V3.zero
    if dt > 0 {
      var delta = q * last.attitude.inverse
      if delta.real < 0 { delta = simd_quatd(vector: -delta.vector) }
      let angle = delta.angle
      if angle.isFinite, angle > 1e-9 { rate = q.inverse.act(delta.axis * angle / dt) }
    }
    return .at(q, rate: rate)
  }
}
