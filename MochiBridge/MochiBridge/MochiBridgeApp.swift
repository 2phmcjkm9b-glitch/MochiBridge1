import SwiftUI
import CoreBluetooth
import UIKit
import CallKit
import MediaPlayer

@main
struct MochiBridgeApp: App {
    @StateObject private var bridge = MochiBridge()

    var body: some Scene {
        WindowGroup {
            ContentView(bridge: bridge)
        }
    }
}

final class MochiBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CXCallObserverDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify: Mochi -> iPhone
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write: iPhone -> Mochi

    @Published var status = "Запуск Bluetooth…"
    @Published var deviceName = "—"
    @Published var battery = 0
    @Published var log: [String] = []
    @Published var connected = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var timer: Timer?
    private let calls = CXCallObserver()
    private var knownCalls: Set<UUID> = []

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        central = CBCentralManager(delegate: self, queue: .main)
        calls.setDelegate(self, queue: .main)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Ищу THE MOCHI…"
            scan()
        case .poweredOff: status = "Включи Bluetooth на iPhone"
        case .unauthorized: status = "Разреши Bluetooth для Mochi Bridge"
        case .unsupported: status = "BLE не поддерживается"
        default: status = "Bluetooth: \(central.state.rawValue)"
        }
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if !self.connected { self.status = "Mochi не найден — нажми «Поиск снова»" }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name, name.uppercased().contains("MOCHI") || name == "THE MOCHI" {
            connect(peripheral)
        } else {
            connect(peripheral) // service UUID already identifies Mochi protocol
        }
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "THE MOCHI"
        status = "Подключение…"
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        status = "Подключено"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        startPeriodicSync()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        rx = nil; tx = nil
        status = "Отключено — ищу снова…"
        startScanAfterDisconnect()
    }

    private func startScanAfterDisconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID {
                tx = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if rx != nil {
            status = "Подключено — синхронизация"
            syncAll()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        addLog("RX: \(hex(data))")
    }

    private func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = rx else { addLog("Нет RX-характеристики"); return }
        let data = Data(bytes)
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: c, type: type)
        addLog("TX: \(hex(data))")
    }

    func syncAll() {
        sendBattery()
        sendTime()
    }

    @objc private func batteryChanged() { if connected { sendBattery() } }

    func sendBattery() {
        let level = max(0, min(100, Int(round(UIDevice.current.batteryLevel * 100))))
        battery = level
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        write([0xAB, 0x00, 0x05, 0xFE, 0x91, 0x80, charging ? 0x01 : 0x00, UInt8(level)])
    }

    func sendTime() {
        let d = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: d)
        let month = cal.component(.month, from: d)
        let day = cal.component(.day, from: d)
        let hour = cal.component(.hour, from: d)
        let minute = cal.component(.minute, from: d)
        let second = cal.component(.second, from: d)
        write([0xAB, 0x00, 0x0B, 0xFE, 0x93, 0x80, 0x00,
               UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second)])
    }

    // Chronos notification format: icon, state=2, UTF-8 message.
    func sendNotification(text: String, icon: UInt8 = 0x03) {
        let payload = Array(text.utf8)
        let length = 5 + payload.count
        guard length <= 0xFF else { return }
        write([0xAB, 0x00, UInt8(length), 0xFF, 0x72, icon, 0x02] + payload)
    }

    func sendIncomingCall(name: String) {
        let p = Array(name.utf8)
        write([0xAB, 0x00, UInt8(5 + p.count), 0xFF, 0x72, 0x01, 0x01] + p)
    }

    func endCall(name: String = "") {
        let p = Array(name.utf8)
        write([0xAB, 0x00, UInt8(5 + p.count), 0xFF, 0x72, 0x02, 0x00] + p)
    }

    // Phone-side media controls. iOS does not expose arbitrary apps' track metadata;
    // transport controls can be sent through the system media player.
    func musicPlayPause() { MPMusicPlayerController.systemMusicPlayer.playbackState == .playing ? MPMusicPlayerController.systemMusicPlayer.pause() : MPMusicPlayerController.systemMusicPlayer.play() }
    func musicNext() { MPMusicPlayerController.systemMusicPlayer.skipToNextItem() }
    func musicPrevious() { MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem() }

    func startPeriodicSync() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.syncAll() }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded {
            if knownCalls.remove(call.uuid) != nil { endCall() }
        } else if !call.hasConnected && !call.isOutgoing {
            if knownCalls.insert(call.uuid).inserted { sendIncomingCall(name: "Входящий звонок") }
        }
    }

    func addLog(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 40 { log.removeLast() }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct ContentView: View {
    @ObservedObject var bridge: MochiBridge
    @State private var notification = "Hello from iPhone!"

    var body: some View {
        NavigationStack {
            List {
                Section("Mochi") {
                    HStack { Text("Статус"); Spacer(); Text(bridge.status).foregroundStyle(bridge.connected ? .green : .secondary) }
                    Text(bridge.deviceName)
                    Button("Поиск снова") { bridge.scan() }
                }
                Section("Синхронизация") {
                    Button("Отправить заряд iPhone: \(bridge.battery)%") { bridge.sendBattery() }
                    Button("Отправить время") { bridge.sendTime() }
                    TextField("Текст уведомления", text: $notification)
                    Button("Тестовое уведомление") { bridge.sendNotification(text: notification) }
                }
                Section("Музыка") {
                    Button("Play / Pause") { bridge.musicPlayPause() }
                    Button("Предыдущий") { bridge.musicPrevious() }
                    Button("Следующий") { bridge.musicNext() }
                    Text("Название трека/исполнитель автоматически получать от других iOS-приложений нельзя через публичный API iOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("BLE лог") {
                    ForEach(Array(bridge.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Mochi Bridge")
        }
    }
}
