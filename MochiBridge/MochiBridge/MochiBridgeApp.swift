import SwiftUI
import CoreBluetooth
import UIKit
import CallKit
import MediaPlayer
import MapKit

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
    @Published var battery = -1
    @Published var charging = false
    @Published var connected = false
    @Published var ready = false
    @Published var musicState = "—"
    @Published var musicPermission = "—"
    @Published var callState = "Нет звонка"
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var timeTimer: Timer?
    private var batteryTimer: Timer?
    private var batteryRetryTimer: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var connecting = false
    private var queue: [Data] = []
    private var writing = false
    private var lastBatteryReply = Date.distantPast
    private let calls = CXCallObserver()
    private var activeCalls = Set<UUID>()
    private let music = MPMusicPlayerController.systemMusicPlayer

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        central = CBCentralManager(delegate: self, queue: .main)
        calls.setDelegate(self, queue: .main)
        NotificationCenter.default.addObserver(self, selector: #selector(phoneBatteryChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(phoneBatteryChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: music)
        music.beginGeneratingPlaybackNotifications()
        requestMusicPermission()
        updatePhoneBattery()
        playbackChanged()
    }

    deinit {
        reconnectTimer?.invalidate()
        timeTimer?.invalidate()
        batteryTimer?.invalidate()
        batteryRetryTimer?.invalidate()
        music.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: BLE lifecycle
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            connected = false; ready = false
            status = central.state == .poweredOff ? "Включи Bluetooth на iPhone" : "Bluetooth недоступен"
            return
        }
        addLog("BLE POWERED ON")
        scan()
    }

    func scan() {
        guard central.state == .poweredOn, !connected, !connecting else { return }
        reconnectTimer?.invalidate()
        central.stopScan()
        status = "Ищу THE MOCHI…"
        if let old = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            addLog("BLE: найдено сохранённое устройство")
            connect(old)
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if !self.connected && !self.connecting { self.scheduleReconnect() }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        addLog("DISCOVERED \(peripheral.name ?? "THE MOCHI") RSSI=\(RSSI)")
        connect(peripheral)
    }

    private func connect(_ p: CBPeripheral) {
        guard !connected, !connecting else { return }
        central.stopScan(); reconnectTimer?.invalidate()
        peripheral = p
        p.delegate = self
        connecting = true
        ready = false
        rx = nil; tx = nil
        queue.removeAll()
        writing = false
        deviceName = p.name ?? "THE MOCHI"
        status = "Подключение…"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting = false; connected = true; ready = false; reconnectDelay = 1
        addLog("CONNECTED")
        status = "Подключено — ищу сервис…"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting = false; connected = false; ready = false
        addLog("CONNECT ERROR: \(error?.localizedDescription ?? "unknown")")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connected = false; ready = false; connecting = false
        rx = nil; tx = nil; writing = false
        queue.removeAll()
        timeTimer?.invalidate(); batteryTimer?.invalidate()
        addLog("DISCONNECTED: \(error?.localizedDescription ?? "без ошибки")")
        status = "Отключено — переподключение…"
        reconnectDelay = min(reconnectDelay * 1.5, 10)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard central.state == .poweredOn, !connected, !connecting else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in self?.scan() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            addLog("SERVICE ERROR: \(error?.localizedDescription ?? "Nordic UART service not found")")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        addLog("SERVICE OK: \(service.uuid.uuidString)")
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            addLog("CHAR ERROR: \(error!.localizedDescription)")
            central.cancelPeripheralConnection(peripheral); return
        }
        rx = service.characteristics?.first(where: { $0.uuid == Self.rxUUID })
        tx = service.characteristics?.first(where: { $0.uuid == Self.txUUID })
        guard let r = rx else {
            addLog("RX MISSING"); return
        }
        guard r.properties.contains(.writeWithoutResponse) || r.properties.contains(.write) else {
            addLog("RX HAS NO WRITE PROPERTY"); return
        }
        guard let t = tx else {
            addLog("TX MISSING"); return
        }
        addLog("RX props=\(r.properties.rawValue) TX props=\(t.properties.rawValue)")
        // Chronos requires TX notifications. Do not declare the link ready before iOS confirms them.
        peripheral.setNotifyValue(true, for: t)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            ready = false
            addLog("NOTIFY ERROR: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            ready = false
            addLog("NOTIFY OFF")
            return
        }
        ready = true
        status = "Подключено"
        addLog("NOTIFY ON — BLE READY FOR TX/RX")
        sendTime()
        sendBatterySnapshot(reason: "CONNECT")
        startTimers()
    }

    // MARK: RX
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        guard error == nil, let data = characteristic.value else {
            if let error { addLog("RX ERROR: \(error.localizedDescription)") }
            return
        }
        let b = Array(data)
        addLog("RX [\(characteristic.uuid.uuidString)]: \(hex(data))")
        handleIncoming(b)
    }

    private func handleIncoming(_ b: [UInt8]) {
        guard b.count >= 6, b[0] == 0xAB else { return }

        // ChronosESP32: AB 00 04 FE 91 80 01 = request phone battery.
        if b.count == 7 && b == [0xAB,0x00,0x04,0xFE,0x91,0x80,0x01] {
            addLog("BATTERY REQUEST FROM MOCHI")
            sendBatterySnapshot(reason: "REQUEST")
            return
        }

        // ChronosESP32: AB 00 04 FF 9D 80 <command> = music control.
        if b.count >= 7 && b[3] == 0xFF && b[4] == 0x9D && b[5] == 0x80 {
            switch b[6] {
            case 0x00: musicPlay(source: "MOCHI")
            case 0x01: musicPause(source: "MOCHI")
            case 0x02: musicPrevious(source: "MOCHI")
            case 0x03: musicNext(source: "MOCHI")
            default: addLog("MUSIC UNKNOWN=\(String(format: "%02X", b[6]))")
            }
        }
    }

    // MARK: TX — Chronos RX is WRITE | WRITE_NR
    private func enqueue(_ bytes: [UInt8], label: String) {
        guard ready, let p = peripheral, let c = rx, p.state == .connected else {
            addLog("TX BLOCKED [not ready]: \(label)")
            return
        }
        guard bytes.count <= 244 else { addLog("TX TOO LONG: \(label)"); return }
        queue.append(Data(bytes))
        addLog("QUEUE \(label): \(hex(Data(bytes)))")
        flushQueue(p, c)
    }

    private func flushQueue(_ p: CBPeripheral? = nil, _ c: CBCharacteristic? = nil) {
        guard ready, let peripheral = p ?? self.peripheral, let characteristic = c ?? rx,
              peripheral.state == .connected, !queue.isEmpty else { return }

        if characteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else { return }
            // Drain everything CoreBluetooth currently accepts. There is no didWrite callback for WRITE_NR.
            while !queue.isEmpty && peripheral.canSendWriteWithoutResponse {
                let data = queue.removeFirst()
                addLog("TX WITHOUT_RESPONSE: \(hex(data))")
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
            return
        }

        guard !writing else { return }
        let data = queue.removeFirst()
        writing = true
        addLog("TX WITH_RESPONSE: \(hex(data))")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxUUID else { return }
        writing = false
        addLog(error == nil ? "TX OK" : "TX ERROR: \(error!.localizedDescription)")
        flushQueue()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        addLog("BLE READY FOR TX")
        flushQueue()
    }

    // MARK: Battery
    private func updatePhoneBattery() {
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else {
            batteryRetryTimer?.invalidate()
            batteryRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.updatePhoneBattery() }
            return
        }
        batteryRetryTimer?.invalidate()
        battery = max(0, min(100, Int(round(raw * 100))))
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    @objc private func phoneBatteryChanged() {
        updatePhoneBattery()
        addLog("PHONE BATTERY CHANGED: \(battery)%")
        if ready { sendBatterySnapshot(reason: "CHANGE") }
    }

    private func sendBatterySnapshot(reason: String) {
        guard ready else { return }
        updatePhoneBattery()
        guard battery >= 0 else { addLog("BATTERY UNKNOWN"); return }
        if Date().timeIntervalSince(lastBatteryReply) < 0.30 { return }
        lastBatteryReply = Date()
        let state: UInt8 = charging ? 0x01 : 0x00
        let level = UInt8(max(0, min(100, battery)))
        // Exact ChronosESP32 phone-battery response: AB 00 05 FF 91 80 charging level
        let packet: [UInt8] = [0xAB,0x00,0x05,0xFF,0x91,0x80,state,level]
        addLog("BATTERY \(reason): \(level)% state=\(state)")
        enqueue(packet, label: "BATTERY")
    }

    func sendBattery() { sendBatterySnapshot(reason: "MANUAL") }

    // MARK: Time
    func sendTime() {
        guard ready else { return }
        let d = Date(); let cal = Calendar.current
        let y = cal.component(.year, from: d)
        let packet: [UInt8] = [
            0xAB,0x00,0x0B,0xFE,0x93,0x80,0x00,
            UInt8((y >> 8) & 0xFF), UInt8(y & 0xFF),
            UInt8(cal.component(.month, from: d)), UInt8(cal.component(.day, from: d)),
            UInt8(cal.component(.hour, from: d)), UInt8(cal.component(.minute, from: d)), UInt8(cal.component(.second, from: d))
        ]
        enqueue(packet, label: "TIME")
    }

    private func startTimers() {
        timeTimer?.invalidate(); batteryTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendTime() }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
    }

    // MARK: Music
    private func requestMusicPermission() {
        if #available(iOS 9.3, *) {
            MPMediaLibrary.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.musicPermission = status == .authorized ? "Разрешено" : "Нет доступа"
                    self?.addLog("APPLE MUSIC AUTH: \(status.rawValue)")
                }
            }
        }
    }

    @objc private func playbackChanged() {
        switch music.playbackState {
        case .playing: musicState = "Играет"
        case .paused: musicState = "Пауза"
        case .stopped: musicState = "Стоп"
        default: musicState = "—"
        }
    }

    func musicPlay(source: String = "APP") {
        music.play()
        playbackChanged()
        addLog("MUSIC PLAY [\(source)]")
    }
    func musicPause(source: String = "APP") {
        music.pause()
        playbackChanged()
        addLog("MUSIC PAUSE [\(source)]")
    }
    func musicToggle() { music.playbackState == .playing ? musicPause() : musicPlay() }
    func musicPrevious(source: String = "APP") { music.skipToPreviousItem(); addLog("MUSIC PREVIOUS [\(source)]") }
    func musicNext(source: String = "APP") { music.skipToNextItem(); addLog("MUSIC NEXT [\(source)]") }

    // MARK: Manual notification packet
    func sendTestNotification() { sendNotification(text: "TEST") }
    func sendNotification(text: String) {
        let bytes = Array(text.data(using: .utf8) ?? Data())
        guard bytes.count <= 250 else { addLog("NOTIFICATION TOO LONG"); return }
        let len = UInt8(bytes.count + 5)
        let packet: [UInt8] = [0xAB,0x00,len,0xFF,0x72,0x80,0x0A,0x02] + bytes
        enqueue(packet, label: "NOTIFICATION")
    }

    // MARK: Calls
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded { activeCalls.remove(call.uuid) }
        else if !call.hasConnected || !call.isOnHold { activeCalls.insert(call.uuid) }
        callState = activeCalls.isEmpty ? "Нет звонка" : (activeCalls.contains(where: { _ in true }) ? "Звонок" : "Нет звонка")
        addLog("CALL STATE: \(callState)")
    }

    // MARK: Navigation
    func openMaps(destination: String) {
        let q = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? destination
        guard let url = URL(string: "http://maps.apple.com/?daddr=\(q)") else { return }
        UIApplication.shared.open(url)
        addLog("MAPS: \(destination)")
    }

    // MARK: Helpers
    private func addLog(_ text: String) {
        DispatchQueue.main.async {
            self.log.append(text)
            if self.log.count > 120 { self.log.removeFirst(self.log.count - 120) }
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

struct ContentView: View {
    @ObservedObject var bridge: MochiBridge
    @State private var notificationText = "TEST"
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Mochi") {
                    HStack { Text("Статус"); Spacer(); Text(bridge.status) }
                    Text(bridge.deviceName)
                    Button("Поиск THE MOCHI") { bridge.scan() }
                }
                Section("Телефон") {
                    Button("Отправить заряд: \(bridge.battery >= 0 ? "\(bridge.battery)%" : "—")") { bridge.sendBattery() }
                    Button("Отправить время") { bridge.sendTime() }
                    Text("Звонки: \(bridge.callState)")
                }
                Section("Уведомления") {
                    TextField("Текст", text: $notificationText)
                    Button("Отправить TEST") { bridge.sendTestNotification() }
                    Button("Отправить на Mochi") { bridge.sendNotification(text: notificationText) }
                }
                Section("Музыка Apple Music") {
                    Text("Состояние: \(bridge.musicState)")
                    Text("Доступ: \(bridge.musicPermission)")
                    Button("Play / Pause") { bridge.musicToggle() }
                    Button("Предыдущий") { bridge.musicPrevious() }
                    Button("Следующий") { bridge.musicNext() }
                }
                Section("Навигация") {
                    TextField("Куда ехать", text: $destination)
                    Button("Открыть Apple Maps") { bridge.openMaps(destination: destination) }.disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("BLE LOG") {
                    ForEach(Array(bridge.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Mochi Bridge")
        }
    }
}
