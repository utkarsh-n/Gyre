// Checks GyroSim against textbook rigid-body results.
// Run: Tools/physcheck/run.sh
import Foundation
import simd

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
  print((ok ? "PASS  " : "FAIL  ") + name + " — " + detail)
  if !ok { failures += 1 }
}

func quiet(_ p: inout GyroParams) {
  p.friction = 0
  p.air = 0
}

let dt = 1.0 / 120.0

// 1. Steady precession of a heavy top matches the slow root of I₁cosθΩ² − L₃Ω + mgℓ = 0.
do {
  var p = GyroParams()
  quiet(&p)
  p.motorRPM = 3000
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.5)
  var env = GyroEnvironment()
  env.airDensity = 0
  var az0: Double?
  var turned = 0.0
  var last = atan2(sim.axis.y, sim.axis.x)
  for i in 0..<(120 * 12) {
    sim.step(dtReal: dt, env: env, params: p)
    let az = atan2(sim.axis.y, sim.axis.x)
    if i > 120 {
      if az0 == nil { az0 = az }
      turned += wrapAngle(az - last)
    }
    last = az
  }
  let measured = turned / (Double(120 * 12 - 122) * dt)
  let l3 = sim.I3 * sim.spinRate
  let mgl = GyroSim.mass * GyroSim.g0 * sim.offset
  let cosT = sim.axis.z
  let theory = (l3 - sqrt(l3 * l3 - 4 * sim.I1 * cosT * mgl)) / (2 * sim.I1 * cosT)
  let err = abs(measured - theory) / theory
  check(
    "steady precession", err < 0.02,
    String(format: "measured %.4f rad/s, theory %.4f (err %.2f%%), period %.2f s", measured, theory, err * 100, 2 * .pi / measured))
}

// 2. A balanced, frictionless gyro keeps its axis fixed in space while the phone tumbles.
do {
  var p = GyroParams()
  quiet(&p)
  p.balance = 0
  p.motorRPM = 0
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.7, rpm: 5000)
  let start = sim.axis
  var env = GyroEnvironment()
  env.airDensity = 0
  for i in 0..<(120 * 10) {
    let t = Double(i) * dt
    env.deviceRate = V3(2 * sin(t), 3 * cos(0.7 * t), 1.5)
    sim.step(dtReal: dt, env: env, params: p)
  }
  let drift = acos(clamped(simd_dot(start, sim.axis), -1, 1)) * 180 / .pi
  check("free gyro holds its axis", drift < 0.01, String(format: "drift %.5f° over 10 s of tumbling", drift))
}

// 3. Without motor, friction or air, total energy of a nutating top is conserved.
do {
  var p = GyroParams()
  quiet(&p)
  p.motorRPM = 0
  p.balance = 0.8
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.6, rpm: 1500)
  sim.applyImpulse(V3(0.002, -0.001, 0))  // knock it into nutation
  var env = GyroEnvironment()
  env.airDensity = 0
  sim.step(dtReal: 0, env: env, params: p)
  let e0 = sim.energy
  var worst = 0.0
  for _ in 0..<(120 * 20) {
    sim.step(dtReal: dt, env: env, params: p)
    worst = max(worst, abs(sim.energy - e0) / abs(e0))
  }
  check("energy conservation", worst < 1e-4, String(format: "max relative drift %.2e over 20 s", worst))
}

// 4. A vertical top sleeps above the critical spin and falls below it.
func sleeps(rpm: Double) -> Bool {
  var p = GyroParams()
  quiet(&p)
  p.motorRPM = rpm
  p.balance = 0.5
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.02, rpm: rpm)
  var env = GyroEnvironment()
  env.airDensity = 0
  var maxTilt = 0.0
  for _ in 0..<(120 * 8) {
    sim.step(dtReal: dt, env: env, params: p)
    maxTilt = max(maxTilt, sim.tilt)
  }
  return maxTilt < 0.2
}
do {
  let probe = GyroSim()
  var p = GyroParams()
  p.balance = 0.5
  probe.launch(params: p)
  let critical =
    sqrt(4 * GyroSim.mass * GyroSim.g0 * probe.offset * probe.I1) / probe.I3 * 60 / (2 * .pi)
  let above = sleeps(rpm: critical * 1.25)
  let below = sleeps(rpm: critical * 0.8)
  check(
    "sleeping-top threshold", above && !below,
    String(format: "critical %.0f rpm: sleeps at 1.25× = %@, at 0.8× = %@", critical, "\(above)", "\(below)"))
}

// 5. A magnetised, balanced rotor precesses about the field at μB/L (Larmor).
do {
  var p = GyroParams()
  quiet(&p)
  p.balance = 0
  p.magnet = 1
  p.motorRPM = 4000
  p.gravity = 0
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.8, rpm: 4000)
  var env = GyroEnvironment()
  env.airDensity = 0
  env.magneticField = V3(0, 0, 50e-6)
  var turned = 0.0
  var last = atan2(sim.axis.y, sim.axis.x)
  let steps = 120 * 10
  for _ in 0..<steps {
    sim.step(dtReal: dt, env: env, params: p)
    let az = atan2(sim.axis.y, sim.axis.x)
    turned += wrapAngle(az - last)
    last = az
  }
  let measured = turned / (Double(steps) * dt)
  let theory = -GyroSim.maxDipole * 50e-6 / (sim.I3 * sim.spinRate)
  let err = abs(measured - theory) / abs(theory)
  check("Larmor precession", err < 0.03, String(format: "measured %.4f rad/s, theory %.4f", measured, theory))
}

// 6. Doubling inertia with the motor off halves the spin (angular momentum conserved).
do {
  var p = GyroParams()
  quiet(&p)
  p.motorRPM = 0
  p.balance = 0
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.3, rpm: 4000)
  var env = GyroEnvironment()
  env.airDensity = 0
  p.inertia = 2
  for _ in 0..<(120 * 4) { sim.step(dtReal: dt, env: env, params: p) }
  check("skater effect", abs(sim.rpm - 2000) < 20, String(format: "spin %.0f rpm after doubling inertia from 4000", sim.rpm))
}

// 7. With air and friction and no motor, the top winds down and falls within a minute or two.
do {
  var p = GyroParams()
  p.motorRPM = 0
  p.air = 1
  p.friction = 0.25
  let sim = GyroSim()
  sim.launch(params: p, tilt: 0.3, rpm: 3000)
  var env = GyroEnvironment()
  env.airDensity = 1
  var fellAt: Double?
  for i in 0..<(120 * 240) {
    sim.step(dtReal: dt, env: env, params: p)
    if fellAt == nil, sim.tilt > .pi / 2 { fellAt = Double(i) * dt }
  }
  check("wind-down", (fellAt ?? 999) > 20 && (fellAt ?? 999) < 200, "fell after \(fellAt.map { String(format: "%.0f s", $0) } ?? "never")")
}

// 8. Cost: substeps for a fast spin.
do {
  var p = GyroParams()
  p.motorRPM = 12000
  p.inertia = 3
  p.balance = 0
  let sim = GyroSim()
  sim.launch(params: p, rpm: 12000)
  let t0 = Date()
  for _ in 0..<1200 { sim.step(dtReal: dt, env: GyroEnvironment(), params: p) }
  let ms = Date().timeIntervalSince(t0) * 1000 / 1200
  check("step cost", ms < 1.0, String(format: "%.3f ms per frame at 12000 rpm", ms))
}

print(failures == 0 ? "\nAll physics checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
