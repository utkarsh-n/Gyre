import CoreBluetooth
import CoreTelephony
import Foundation
import Network

/// The radio around you, as far as iOS lets an app see it. Apps can't scan Wi-Fi networks
/// or read Wi-Fi or cellular signal strength, so this listens to Bluetooth LE
/// advertisements (real 2.4 GHz packets, each with its signal strength), and notes
/// whether the phone is on Wi-Fi and which cellular generation it's using. It never
/// connects to or identifies a device; identifiers stay in memory for a few seconds.
/// With `-fakeRadio` (the Simulator has no Bluetooth) it invents a room of radios.
final class RadioSense: NSObject, CBCentralManagerDelegate {
  enum State: Equatable { case off, starting, scanning, denied, unavailable }

  struct Device {
    let id: UUID
    var rssi: Double
    var lastSeen: Double
    var lastPulse: Double
    var apple: Bool
  }

  private(set) var state: State = .off
  private(set) var devices: [UUID: Device] = [:]
  private(set) var onWiFi = false
  private(set) var onCellular = false
  private(set) var cellular: String?
  let fake = ProcessInfo.processInfo.arguments.contains("-fakeRadio")
  private var central: CBCentralManager?
  private var monitor: NWPathMonitor?
  private var pulses: [(UUID, Double)] = []
  private var clock = 0.0

  func start() {
    guard state == .off else { return }
    let m = NWPathMonitor()
    m.pathUpdateHandler = { [weak self] path in
      let wifi = path.usesInterfaceType(.wifi)
      let cell = path.usesInterfaceType(.cellular)
      DispatchQueue.main.async {
        self?.onWiFi = wifi
        self?.onCellular = cell
      }
    }
    m.start(queue: .global(qos: .utility))
    monitor = m
    cellular = Self.generation(CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?.values.first)
    if fake {
      state = .scanning
      onWiFi = true
      cellular = "5G"
      return
    }
    state = .starting
    central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }

  func stop() {
    central?.stopScan()
    central?.delegate = nil
    central = nil
    monitor?.cancel()
    monitor = nil
    devices.removeAll()
    pulses.removeAll()
    state = .off
  }

  /// Forgets radios that have gone quiet; keeps the 24 strongest.
  func tick(_ now: Double) {
    clock = now
    if fake { synthesize() }
    devices = devices.filter { now - $0.value.lastSeen < 10 }
    if devices.count > 24 {
      let keep = devices.values.sorted { $0.rssi > $1.rssi }.prefix(24).map(\.id)
      devices = devices.filter { keep.contains($0.key) }
    }
  }

  /// Packets that arrived since the last call (at most one per radio every 1.5 s).
  func drainPulses() -> [(UUID, Double)] {
    defer { pulses.removeAll(keepingCapacity: true) }
    return pulses
  }

  private func heard(_ id: UUID, rssi: Double, apple: Bool?) {
    guard rssi < 0, rssi > -110 else { return }
    var d = devices[id] ?? Device(id: id, rssi: rssi, lastSeen: clock, lastPulse: -1, apple: false)
    d.rssi += (rssi - d.rssi) * 0.3
    d.lastSeen = clock
    if let apple { d.apple = apple }
    if clock - d.lastPulse > 1.5 {
      d.lastPulse = clock
      pulses.append((id, d.rssi))
    }
    devices[id] = d
  }

  private static func generation(_ tech: String?) -> String? {
    guard let tech else { return nil }
    if tech.contains("NR") { return "5G" }
    if tech.contains("LTE") { return "LTE" }
    if tech.contains("WCDMA") || tech.contains("HSDPA") || tech.contains("HSUPA") { return "3G" }
    return "Cellular"
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      state = .scanning
    case .unauthorized:
      state = .denied
    case .unsupported, .poweredOff:
      state = .unavailable
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    var apple: Bool?
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
      apple = data[data.startIndex] == 0x4C && data[data.startIndex + 1] == 0x00
    }
    heard(peripheral.identifier, rssi: RSSI.doubleValue, apple: apple)
  }

  // MARK: Fake room

  private static let fakeIDs = (0..<11).map { UUID(uuidString: String(format: "6A1E%04X-0000-4000-8000-000000000000", $0 * 4111))! }

  private func synthesize() {
    for (i, id) in Self.fakeIDs.enumerated() {
      let base = -48.0 - Double(i) * 4.5
      let rssi = base + 6 * sin(clock * (0.3 + Double(i) * 0.07) + Double(i))
      let period = 0.8 + Double(i % 4) * 0.45
      if devices[id] == nil || clock - (devices[id]?.lastPulse ?? 0) > period {
        heard(id, rssi: rssi, apple: i % 3 != 2)
      } else if var d = devices[id] {
        d.rssi += (rssi - d.rssi) * 0.1
        d.lastSeen = clock
        devices[id] = d
      }
    }
  }
}
