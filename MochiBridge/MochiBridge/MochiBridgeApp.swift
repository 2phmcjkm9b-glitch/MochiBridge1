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
    @Published var ready = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var timer: Timer?
    private var reconnectTimer: Timer?
    private var isConnecting = false
    private var scanning = false
    private var shouldReconnect = true
    private let calls = CXCallObserver()
    private var knownCalls: Set<UUID> = []
    private var writeQueue: [[UInt8]] = []
    private var writeInProgress = false

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
            ready = false
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
        guard central.state == .poweredOn, !connected, !isConnecting else { return }
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
            if !self.connected && !self.isConnecting {
                self.status = "Mochi не найден — повторяю поиск…"
                self.scheduleReconnect(delay: 2)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard !connected, !isConnecting else { return }
        connect(peripheral)
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        scanning = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isConnecting = true
        ready = false
        writeQueue.removeAll()
        writeInProgress = false
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "THE MOCHI"
        status = "Подключение…"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        connected = true
        ready = false
        writeQueue.removeAll()
        writeInProgress = false
        status = "Подключено — ищу характеристики…"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        connected = false
        ready = false
        rx = nil
        tx = nil
        writeQueue.removeAll()
        writeInProgress = false
        status = "Не удалось подключиться — повторяю…"
        scheduleReconnect(delay: 1.5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral || self.peripheral?.identifier == peripheral.identifier else { return }
        isConnecting = false
        connected = false
        ready = false
        rx = nil
        tx = nil
        writeQueue.removeAll()
        writeInProgress = false
        timer?.invalidate()
        status = "Отключено — переподключение…"
        scheduleReconnect(delay: 1)
    }

    private func scheduleReconnect(delay: TimeInterval) {
        guard shouldReconnect, central.state == .poweredOn, !connected, !isConnecting else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            status = "Ошибка BLE — переподключение…"
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            status = "Ошибка характеристик — переподключение…"
            central.cancelPeripheralConnection(peripheral)
            return
        }

        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID {
                tx = c
                peripheral.setNotifyValue(true, for: c)
            }
        }

        guard let writeCharacteristic = rx else {
            status = "RX характеристика не найдена"
            return
        }

        let canWrite = writeCharacteristic.properties.contains(.write) || writeCharacteristic.properties.contains(.writeWithoutResponse)
        guard canWrite else {
            status = "RX не поддерживает запись"
            return
        }

        ready = true
        status = "Подключено"
        addLog("BLE READY: RX=\(writeCharacteristic.properties.rawValue) TX=\(tx != nil ? "OK" : "нет")")
        syncAll()
        startPeriodicSync()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { addLog("RX ERROR: \(error.localizedDescription)") ; return }
        guard let data = characteristic.value else { return }
        addLog("RX: \(hex(data))")
    }

    private func write(_ bytes: [UInt8], label: String = "") {
        guard !bytes.isEmpty else { return }
        guard connected, ready, peripheral != nil, rx != nil else {
            addLog("TX SKIP \(label): BLE не готов")
            return
        }
        writeQueue.append(bytes)
        if !label.isEmpty { addLog("QUEUE \(label): \(hex(Data(bytes)))") }
        processWriteQueue()
    }

    private func processWriteQueue() {
        guard !writeInProgress, connected, ready,
              let p = peripheral, let c = rx,
              !writeQueue.isEmpty else { return }

        let bytes = writeQueue.removeFirst()
        let data = Data(bytes)
        let canWithoutResponse = c.properties.contains(.writeWithoutResponse)
        let canWithResponse = c.properties.contains(.write)
        guard canWithoutResponse || canWithResponse else {
            addLog("TX ERROR: RX cannot write")
            return
        }

        let type: CBCharacteristicWriteType = canWithoutResponse ? .withoutResponse : .withResponse
        writeInProgress = true
        addLog("TX: \(hex(data))")
        p.writeValue(data, for: c, type: type)

        if type == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.writeInProgress = false
                self.processWriteQueue()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            addLog("TX ERROR: \(error.localizedDescription)")
        } else {
            addLog("TX OK")
        }
        writeInProgress = false
        processWriteQueue()
    }

    func syncAll() {
        guard ready else { return }
        sendBattery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sendTime() }
    }

    @objc private func batteryChanged() { if ready { sendBattery() } }

    func sendBattery() {
        guard ready else { return }
        let level = max(0, min(100, Int(round(UIDevice.current.batteryLevel * 100))))
        battery = level
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        write([0xAB, 0x00, 0x05, 0xFE, 0x91, 0x80, charging ? 0x01 : 0x00, UInt8(level)], label: "BATTERY")
    }

    func sendTime() {
        guard ready else { return }
        let d = Date(); let cal = Calendar.current
        let year = cal.component(.year, from: d), month = cal.component(.month, from: d), day = cal.component(.day, from: d)
        let hour = cal.component(.hour, from: d), minute = cal.component(.minute, from: d), second = cal.component(.second, from: d)
        write([0xAB, 0x00, 0x0B, 0xFE, 0x93, 0x80, 0x00,
               UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second)], label: "TIME")
    }

    // Verified working Mochi/Chronos packet for TEST:
    // AB 00 09 FF 72 80 0A 02 54 45 53 54
    func sendTestNotification() {
        write([0xAB, 0x00, 0x09, 0xFF, 0x72, 0x80, 0x0A, 0x02, 0x54, 0x45, 0x53, 0x54], label: "TEST NOTIFICATION")
    }

    func sendNotification(text: String) {
        let converted = transliterateRussian(text)
        let payload = Array(converted.utf8)
        let length = 5 + payload.count
        guard length <= 0xFF else { addLog("NOTIFY SKIP: текст слишком длинный"); return }
        addLog("NOTIFY TEXT: \(converted)")
        write([0xAB, 0x00, UInt8(length), 0xFF, 0x72, 0x80, 0x0A, 0x02] + payload, label: "NOTIFICATION")
    }

    private func transliterateRussian(_ text: String) -> String {
        let map: [Character: String] = [
            "А":"A","Б":"B","В":"V","Г":"G","Д":"D","Е":"E","Ё":"Yo","Ж":"Zh","З":"Z","И":"I","Й":"Y","К":"K","Л":"L","М":"M","Н":"N","О":"O","П":"P","Р":"R","С":"S","Т":"T","У":"U","Ф":"F","Х":"Kh","Ц":"Ts","Ч":"Ch","Ш":"Sh","Щ":"Sch","Ъ":"","Ы":"Y","Ь":"","Э":"E","Ю":"Yu","Я":"Ya",
            "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"yo","ж":"zh","з":"z","и":"i","й":"y","к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"kh","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya"
        ]
        return text.map { map[$0] ?? String($0) }.joined()
    }

    // MARK: - Music

    // Confirmed from ChronosESP32 source:
    // FF/9D/80..03 are ESP32 -> phone music-control commands.
    // FE/9D/80..82 are phone -> ESP32 music state/title/artist packets.
    private var musicPlaying = false
    private let musicAppName = "MochiBridge"
    private let musicPackageName = "com.vitaliy.MochiBridge"
    private let musicTitle = "Mochi Music"
    private let musicArtist = "iPhone"

    func musicPlayPause() {
        guard ready else { addLog("MUSIC SKIP: BLE не готов"); return }
        musicPlaying.toggle()
        addLog("MUSIC STATE: \(musicPlaying ? "PLAY" : "PAUSE")")
        sendMusicInfo()
    }

    func musicPrevious() {
        guard ready else { addLog("MUSIC SKIP PREVIOUS: BLE не готов"); return }
        addLog("MUSIC BUTTON: PREVIOUS")
        sendMusicInfo()
    }

    func musicNext() {
        guard ready else { addLog("MUSIC SKIP NEXT: BLE не готов"); return }
        addLog("MUSIC BUTTON: NEXT")
        sendMusicInfo()
    }

    private func sendMusicInfo() {
        sendMusicState()
        sendMusicTitle()
        sendMusicArtist()
    }

    private func sendMusicState() {
        let app = Array(musicAppName.utf8) + [0x00]
        let package = Array(musicPackageName.utf8) + [0x00]
        let body: [UInt8] = [
            0xFE, 0x9D, 0x80,
            musicPlaying ? 0x01 : 0x00,
            0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF
        ] + app + package
        sendChronosPacket(body, label: "MUSIC STATE")
    }

    private func sendMusicTitle() {
        let body: [UInt8] = [0xFE, 0x9D, 0x81] + Array(musicTitle.utf8) + [0x00]
        sendChronosPacket(body, label: "MUSIC TITLE")
    }

    private func sendMusicArtist() {
        let body: [UInt8] = [0xFE, 0x9D, 0x82] + Array(musicArtist.utf8) + [0x00]
        sendChronosPacket(body, label: "MUSIC ARTIST")
    }

    private func sendChronosPacket(_ body: [UInt8], label: String) {
        guard body.count <= 0xFF else {
            addLog("\(label) SKIP: пакет слишком длинный")
            return
        }
        write([0xAB, 0x00, UInt8(body.count)] + body, label: label)
    }

    func sendIncomingCall() {
        let payload = Array(transliterateRussian("Входящий").utf8)
        let length = UInt8(5 + payload.count)
        write([0xAB, 0x00, length, 0xFF, 0x72, 0x80, 0x01, 0x01] + payload, label: "CALL IN")
    }

    func endCall() {
        write([0xAB, 0x00, 0x05, 0xFF, 0x72, 0x80, 0x02, 0x00], label: "CALL END")
    }

    func startPeriodicSync() {
        timer?.invalidate()
        guard ready else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.ready else { return }
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

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
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
                    Button("Тестовое TEST") { bridge.sendTestNotification() }
                    Button("Отправить уведомление") { bridge.sendNotification(text: notification) }
                }

                Section("Музыка") {
                    Button("Play / Pause") { bridge.musicPlayPause() }
                        .disabled(!bridge.ready)
                    Button("Предыдущий") { bridge.musicPrevious() }
                        .disabled(!bridge.ready)
                    Button("Следующий") { bridge.musicNext() }
                        .disabled(!bridge.ready)
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
