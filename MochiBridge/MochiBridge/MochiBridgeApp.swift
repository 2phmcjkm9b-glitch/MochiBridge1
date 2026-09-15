import SwiftUI
import CoreBluetooth
import UIKit
import CallKit

@main
struct MochiBridgeApp: App {
    @StateObject private var bridge = MochiBridge()
    var body: some Scene { WindowGroup { ContentView(bridge: bridge) } }
}

final class MochiBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CXCallObserverDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

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
    private var reconnectTimer: Timer?
    private var isConnecting = false
    private var reconnectTimer: Timer?
    private var scanning = false
    private var shouldReconnect = true
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

    deinit {
        timer?.invalidate()
        reconnectTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            connected = false
            switch central.state {
            case .poweredOff: status = "Включи Bluetooth на iPhone"
            case .unauthorized: status = "Разреши Bluetooth для Mochi Bridge"
            case .unsupported: status = "BLE не поддерживается"
            default: status = "Bluetooth: \(central.state.rawValue)"
            }
            return
        }
        status = "Ищу THE MOCHI…"
        scan()
    }

    func scan() {
        guard central.state == .poweredOn, !connected else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        central.stopScan()
        scanning = true
        status = "Ищу THE MOCHI…"
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.scanning = false
            if !self.connected {
                self.status = "Mochi не найден — повторяю поиск…"
                self.scheduleReconnect(delay: 2)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        connect(peripheral)
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        scanning = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "THE MOCHI"
        status = "Подключение…"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        connected = true
        status = "Подключено — ищу характеристики…"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        startPeriodicSync()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connected = false
        rx = nil; tx = nil
        status = "Не удалось подключиться — повторяю…"
        scheduleReconnect(delay: 1.5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral || self.peripheral?.identifier == peripheral.identifier else { return }
        connected = false
        rx = nil; tx = nil
        timer?.invalidate()
        status = "Отключено — переподключение…"
        scheduleReconnect(delay: 1)
    }

    private func scheduleReconnect(delay: TimeInterval) {
        guard shouldReconnect, central.state == .poweredOn, !connected else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            status = "Ошибка BLE — повторяю подключение…"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID {
                tx = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if rx != nil {
            status = "Подключено"
            syncAll()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        addLog("RX: \(hex(data))")
    }

    private func write(_ bytes: [UInt8]) {
        guard connected, let p = peripheral, let c = rx else {
            addLog("TX пропущен: Mochi не подключён")
            return
        }
        let data = Data(bytes)
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: c, type: type)
        addLog("TX: \(hex(data))")
    }

    func syncAll() { sendBattery(); sendTime() }
    @objc private func batteryChanged() { if connected { sendBattery() } }

    func sendBattery() {
        let level = max(0, min(100, Int(round(UIDevice.current.batteryLevel * 100))))
        battery = level
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        write([0xAB, 0x00, 0x05, 0xFE, 0x91, 0x80, charging ? 0x01 : 0x00, UInt8(level)])
    }

    func sendTime() {
        let d = Date(); let cal = Calendar.current
        let year = cal.component(.year, from: d), month = cal.component(.month, from: d), day = cal.component(.day, from: d)
        let hour = cal.component(.hour, from: d), minute = cal.component(.minute, from: d), second = cal.component(.second, from: d)
        write([0xAB, 0x00, 0x0B, 0xFE, 0x93, 0x80, 0x00,
               UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second)])
    }

    // Verified Chronos/Mochi format:
    // AB 00 LEN FF 72 80 0A 02 UTF8_TEXT
    func sendNotification(text: String) {
        let payload = Array(text.utf8)
        let length = 5 + payload.count
        guard length <= 0xFF else { return }
        write([0xAB, 0x00, UInt8(length), 0xFF, 0x72, 0x80, 0x0A, 0x02] + payload)
    }

    // Verified Chronos/Mochi media commands.
    private func musicCommand(_ lowByte: UInt8) {
        write([0xAB, 0x00, 0x04, 0xFF, 0x9D, 0x80, lowByte])
    }
    func musicPlayPause() { musicCommand(0x00) }
    func musicPrevious() { musicCommand(0x02) }
    func musicNext() { musicCommand(0x03) }

    func sendIncomingCall() {
        write([0xAB, 0x00, 0x09, 0xFF, 0x72, 0x80, 0x01, 0x01] + Array("Входящий".utf8))
    }
    func endCall() {
        write([0xAB, 0x00, 0x05, 0xFF, 0x72, 0x80, 0x02, 0x00])
    }

    func startPeriodicSync() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            self.syncAll()
        }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded {
            if knownCalls.remove(call.uuid) != nil { endCall() }
        } else if !call.hasConnected && !call.isOutgoing {
            if knownCalls.insert(call.uuid).inserted { sendIncomingCall() }
        }
    }

    func addLog(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 60 { log.removeLast() }
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct ContentView: View {
    @ObservedObject var bridge: MochiBridge
    @State private var notification = "TEST"
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
