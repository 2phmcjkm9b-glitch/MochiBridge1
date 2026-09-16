import SwiftUI
import CoreBluetooth
import UIKit
import CallKit
import MediaPlayer
import MapKit
import CoreLocation

@main
struct MochiBridgeApp: App {
    @StateObject private var bridge = MochiBridge()
    var body: some Scene { WindowGroup { ContentView(bridge: bridge) } }
}

final class MochiBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CXCallObserverDelegate, CLLocationManagerDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published var status = "Запуск Bluetooth…"
    @Published var deviceName = "—"
    @Published var battery = -1
    @Published var connected = false
    @Published var ready = false
    @Published var log: [String] = []
    @Published var musicState = "—"
    @Published var navigationState = "Не запущена"
    @Published var callState = "Нет звонка"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var syncTimer: Timer?
    private var batteryRetryTimer: Timer?
    private var isConnecting = false
    private var shouldReconnect = true
    private var reconnectDelay: TimeInterval = 1
    private var queue: [Data] = []
    private var writing = false
    private var writeWithoutResponseScheduled = false
    private let maxQueueCount = 40

    private let calls = CXCallObserver()
    private var activeCalls = Set<UUID>()
    private let music = MPMusicPlayerController.systemMusicPlayer
    private let location = CLLocationManager()
    private var destinationText = ""
    private var route: MKRoute?
    private var navStep = 0
    private var lastNavSend = Date.distantPast
    private var navigating = false
    private var lastBatterySend = Date.distantPast

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        central = CBCentralManager(delegate: self, queue: .main)
        calls.setDelegate(self, queue: .main)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 10

        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: music)
        music.beginGeneratingPlaybackNotifications()

        DispatchQueue.main.async { [weak self] in
            self?.updateBatteryValue()
            self?.playbackChanged()
        }
    }

    deinit {
        reconnectTimer?.invalidate()
        syncTimer?.invalidate()
        batteryRetryTimer?.invalidate()
        music.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: BLE

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            connected = false
            ready = false
            status = central.state == .poweredOff ? "Включи Bluetooth на iPhone" : "Bluetooth недоступен"
            return
        }
        addLog("BLE POWERED ON")
        scan()
    }

    func scan() {
        guard central.state == .poweredOn, !connected, !isConnecting else { return }
        reconnectTimer?.invalidate()
        central.stopScan()
        status = "Ищу THE MOCHI…"

        let known = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let p = known.first {
            addLog("BLE: найдено ранее подключённое устройство")
            connect(p)
            return
        }

        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if !self.connected && !self.isConnecting {
                self.scheduleReconnect(self.reconnectDelay)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        addLog("BLE DISCOVERED: \(p.name ?? "THE MOCHI") RSSI \(RSSI)")
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        guard !connected, !isConnecting else { return }
        central.stopScan()
        reconnectTimer?.invalidate()
        peripheral = p
        p.delegate = self
        isConnecting = true
        ready = false
        rx = nil
        tx = nil
        writing = false
        writeWithoutResponseScheduled = false
        deviceName = p.name ?? "THE MOCHI"
        status = "Подключение…"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        connected = true
        ready = false
        reconnectDelay = 1
        peripheral.delegate = self
        status = "Подключено — ищу характеристики…"
        addLog("BLE CONNECTED")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        connected = false
        ready = false
        addLog("BLE CONNECT ERROR: \(error?.localizedDescription ?? "unknown")")
        scheduleReconnect(reconnectDelay)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connected = false
        ready = false
        rx = nil
        tx = nil
        writing = false
        writeWithoutResponseScheduled = false
        syncTimer?.invalidate()
        addLog("BLE DISCONNECTED: \(error?.localizedDescription ?? "без ошибки")")
        if !queue.isEmpty { addLog("BLE: очередь сохранена (\(queue.count))") }
        status = "Отключено — переподключение…"
        reconnectDelay = min(reconnectDelay * 1.5, 10)
        scheduleReconnect(reconnectDelay)
    }

    private func scheduleReconnect(_ delay: TimeInterval) {
        guard shouldReconnect, central.state == .poweredOn, !connected, !isConnecting else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            addLog("BLE SERVICE ERROR: \(error?.localizedDescription ?? "service not found")")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            addLog("BLE CHARACTERISTICS ERROR: \(error!.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        rx = nil
        tx = nil
        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID {
                tx = c
                peripheral.setNotifyValue(true, for: c)
            }
        }

        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else {
            status = "RX не поддерживает запись"
            addLog("BLE ERROR: RX write property отсутствует")
            return
        }

        ready = true
        status = "Подключено"
        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"
        addLog("BLE READY RX=\(r.properties.rawValue) MODE=\(mode) TX=\(tx != nil ? "OK" : "нет")")

        flushQueue()
        syncAll()
        startSyncTimer()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            addLog("NOTIFY ERROR: \(error.localizedDescription)")
        } else {
            addLog("NOTIFY \(characteristic.isNotifying ? "ON" : "OFF")")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            if let error { addLog("RX ERROR: \(error.localizedDescription)") }
            return
        }
        addLog("RX: \(hex(data))")
        handleRobotCommand(Array(data))
    }

    // MARK: BLE TX

    private func send(_ bytes: [UInt8], label: String) {
        let data = Data(bytes)
        if queue.count >= maxQueueCount {
            queue.removeFirst()
            addLog("QUEUE: удалён самый старый пакет")
        }
        queue.append(data)
        addLog("QUEUE \(label): \(hex(data))")
        flushQueue()
    }

    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected else { return }
        processQueue(p, c)
    }

    private func processQueue(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard p.state == .connected, !queue.isEmpty else { return }

        if c.properties.contains(.writeWithoutResponse) {
            guard !writeWithoutResponseScheduled else { return }
            guard p.canSendWriteWithoutResponse else { return }

            let data = queue.removeFirst()
            writeWithoutResponseScheduled = true
            addLog("TX: \(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)

            // Some BLE peripherals do not call peripheralIsReady when the queue never
            // becomes flow-controlled. This watchdog prevents the queue from getting stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                guard self.writeWithoutResponseScheduled else { return }
                self.writeWithoutResponseScheduled = false
                self.flushQueue()
            }
            return
        }

        guard !writing, c.properties.contains(.write) else { return }
        let data = queue.removeFirst()
        writing = true
        addLog("TX: \(hex(data))")
        p.writeValue(data, for: c, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            addLog("TX ERROR: \(error.localizedDescription)")
        } else {
            addLog("TX OK")
        }
        processQueue(peripheral, characteristic)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeWithoutResponseScheduled = false
        if let c = rx {
            addLog("BLE READY FOR TX")
            processQueue(peripheral, c)
        }
    }

    // MARK: Battery / time

    func syncAll() {
        sendBattery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.sendTime()
        }
    }

    @objc private func batteryChanged() {
        updateBatteryValue()
        if ready && Date().timeIntervalSince(lastBatterySend) > 1 {
            sendBattery()
        }
    }

    private func updateBatteryValue() {
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else {
            addLog("BATTERY: iOS пока не отдал уровень")
            batteryRetryTimer?.invalidate()
            batteryRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                self?.updateBatteryValue()
            }
            return
        }
        batteryRetryTimer?.invalidate()
        battery = max(0, min(100, Int(round(raw * 100))))
    }

    func sendBattery() {
        guard ready else { return }
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else {
            addLog("BATTERY SKIP: level unavailable")
            updateBatteryValue()
            return
        }

        let level = max(0, min(100, Int(round(raw * 100))))
        let charging: UInt8 = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full) ? 1 : 0
        battery = level
        lastBatterySend = Date()

        // Confirmed from LightBlue/Mochi traffic.
        send([0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, charging, UInt8(level)], label: "BATTERY \(level)%")
    }

    func sendTime() {
        guard ready else { return }
        let d = Date()
        let c = Calendar.current
        let y = c.component(.year, from: d)
        let mo = c.component(.month, from: d)
        let da = c.component(.day, from: d)
        let h = c.component(.hour, from: d)
        let mi = c.component(.minute, from: d)
        let s = c.component(.second, from: d)
        send([0xAB, 0x00, 0x0B, 0xFE, 0x93, 0x80, 0x00, UInt8(y >> 8), UInt8(y & 255), UInt8(mo), UInt8(da), UInt8(h), UInt8(mi), UInt8(s)], label: "TIME")
    }

    // MARK: Notifications / calls

    func sendTestNotification() {
        sendNotification(text: "TEST", icon: 0x0A)
    }

    func sendNotification(text: String, icon: UInt8 = 0xC0) {
        let payload = Array(transliterate(text).utf8)
        guard payload.count + 5 <= 255 else {
            addLog("NOTIFICATION SKIP: слишком длинный текст")
            return
        }
        // Known Mochi text frame: AB 00 <5+payload> FF 72 80 <icon> 02 <UTF-8/ASCII text>.
        send([0xAB, 0x00, UInt8(payload.count + 5), 0xFF, 0x72, 0x80, icon, 0x02] + payload, label: "NOTIFICATION")
    }

    private func sendIncomingCall(_ name: String = "Входящий звонок") {
        let msg = Array(transliterate(name).utf8)
        guard msg.count + 5 <= 255 else { return }
        send([0xAB, 0x00, UInt8(msg.count + 5), 0xFF, 0x72, 0x80, 0x01, 0x01] + msg, label: "CALL IN")
    }

    private func endCall() {
        send([0xAB, 0x00, 0x05, 0xFF, 0x72, 0x80, 0x02, 0x00], label: "CALL END")
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasEnded && !call.isOutgoing && !call.hasConnected {
            if activeCalls.insert(call.uuid).inserted {
                callState = "Входящий"
                sendIncomingCall()
            }
        } else if call.hasEnded && activeCalls.remove(call.uuid) != nil {
            callState = "Нет звонка"
            endCall()
        }
    }

    // MARK: Music

    private func handleRobotCommand(_ b: [UInt8]) {
        guard b.count >= 7, b[0] == 0xAB, b.count > 5, b[3] == 0xFF else { return }
        if b[4] == 0x9D && b[5] == 0x80 {
            switch b[6] {
            case 0x00: musicPlay()
            case 0x01: musicPause()
            case 0x02: musicPrevious()
            case 0x03: musicNext()
            default: break
            }
        }
    }

    @objc private func playbackChanged() {
        switch music.playbackState {
        case .playing: musicState = "▶︎"
        case .paused: musicState = "⏸"
        case .stopped: musicState = "■"
        default: musicState = "—"
        }
    }

    func musicPlay() {
        music.play()
        playbackChanged()
        addLog("MUSIC PLAY")
    }

    func musicPause() {
        music.pause()
        playbackChanged()
        addLog("MUSIC PAUSE")
    }

    func musicToggle() {
        music.playbackState == .playing ? musicPause() : musicPlay()
    }

    func musicPrevious() {
        music.skipToPreviousItem()
        addLog("MUSIC PREVIOUS")
    }

    func musicNext() {
        music.skipToNextItem()
        addLog("MUSIC NEXT")
    }

    // MARK: Navigation

    func setDestination(_ text: String) {
        destinationText = text
    }

    func startNavigation(to text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            navigationState = "Укажи пункт назначения"
            return
        }
        destinationText = query

        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
            navigationState = "Разреши геолокацию и нажми ещё раз"
            return
        }
        guard location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways else {
            navigationState = "Разреши геолокацию в Настройки → Mochi Bridge"
            return
        }
        guard let user = location.location else {
            location.requestLocation()
            navigationState = "Определяю местоположение…"
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: user.coordinate, latitudinalMeters: 10000, longitudinalMeters: 10000)
        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self, error == nil, let item = response?.mapItems.first else {
                self?.navigationState = "Не найден пункт назначения"
                return
            }

            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: user.coordinate))
            req.destination = item
            req.transportType = .automobile
            MKDirections(request: req).calculate { [weak self] response, error in
                guard let self, error == nil, let r = response?.routes.first else {
                    self?.navigationState = "Не удалось построить маршрут"
                    return
                }
                self.route = r
                self.navStep = self.firstUsefulNavigationStep(in: r)
                self.navigating = true
                self.lastNavSend = Date.distantPast
                self.navigationState = "Маршрут: \(String(format: "%.1f", r.distance / 1000)) км"
                self.location.startUpdatingLocation()
                self.sendNavigation(force: true)
            }
        }
    }

    private func firstUsefulNavigationStep(in route: MKRoute) -> Int {
        guard !route.steps.isEmpty else { return 0 }
        for i in 0..<route.steps.count where !route.steps[i].instructions.isEmpty {
            return i
        }
        return 0
    }

    func stopNavigation() {
        navigating = false
        route = nil
        location.stopUpdatingLocation()
        navigationState = "Не запущена"
    }

    func openMaps() {
        let text = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            if navigating { manager.startUpdatingLocation() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard navigating, let loc = locations.last, let r = route, !r.steps.isEmpty else { return }

        if navStep < r.steps.count - 1 {
            let target = r.steps[navStep].polyline.coordinate.clLocation
            if loc.distance(from: target) < 35 {
                navStep += 1
                sendNavigation(force: true)
                return
            }
        }

        if Date().timeIntervalSince(lastNavSend) > 5 {
            sendNavigation(force: false)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        navigationState = "GPS: \(error.localizedDescription)"
    }

    private func sendNavigation(force: Bool) {
        guard navigating, let r = route, !r.steps.isEmpty, navStep < r.steps.count else { return }
        guard force || Date().timeIntervalSince(lastNavSend) > 5 else { return }

        let step = r.steps[navStep]
        let direction = step.instructions.isEmpty ? "Продолжайте движение" : step.instructions
        let distance: String
        if step.distance >= 1000 {
            distance = String(format: "%.1f km", step.distance / 1000)
        } else {
            distance = String(format: "%.0f m", step.distance)
        }

        let message = "\(distance): \(direction)"
        navigationState = "Следующее: \(message)"
        // No undocumented navigation binary command is invented here. The confirmed
        // Mochi text frame is used so the current turn instruction is actually visible.
        sendNotification(text: message, icon: 0x0A)
        lastNavSend = Date()
    }

    // MARK: Helpers

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.syncAll()
        }
    }

    private func flushQueueAfterReconnect() {
        flushQueue()
    }

    private func transliterate(_ text: String) -> String {
        let m: [Character: String] = [
            "А":"A","Б":"B","В":"V","Г":"G","Д":"D","Е":"E","Ё":"Yo","Ж":"Zh","З":"Z","И":"I","Й":"Y","К":"K","Л":"L","М":"M","Н":"N","О":"O","П":"P","Р":"R","С":"S","Т":"T","У":"U","Ф":"F","Х":"Kh","Ц":"Ts","Ч":"Ch","Ш":"Sh","Щ":"Sch","Ъ":"","Ы":"Y","Ь":"","Э":"E","Ю":"Yu","Я":"Ya",
            "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"yo","ж":"zh","з":"z","и":"i","й":"y","к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"kh","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya"
        ]
        return text.map { m[$0] ?? String($0) }.joined()
    }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func addLog(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 100 { log.removeLast() }
    }
}

private extension CLLocationCoordinate2D {
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

struct ContentView: View {
    @ObservedObject var bridge: MochiBridge
    @State private var text = "TEST"
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Mochi") {
                    HStack {
                        Text("Статус")
                        Spacer()
                        Text(bridge.status).foregroundStyle(bridge.connected ? .green : .secondary)
                    }
                    Text(bridge.deviceName)
                    Button("Поиск снова") { bridge.scan() }
                }

                Section("Телефон") {
                    Button(bridge.battery >= 0 ? "Заряд iPhone: \(bridge.battery)%" : "Заряд iPhone: —") {
                        bridge.sendBattery()
                    }
                    Button("Отправить время") { bridge.sendTime() }
                    Text("Звонки: \(bridge.callState)")
                }

                Section("Уведомления") {
                    TextField("Текст", text: $text)
                    Button("Отправить TEST") { bridge.sendTestNotification() }
                    Button("Отправить на Mochi") { bridge.sendNotification(text: text) }
                }

                Section("Музыка") {
                    Text("Плеер: \(bridge.musicState)")
                    Button("Play / Pause") { bridge.musicToggle() }
                    Button("Предыдущий") { bridge.musicPrevious() }
                    Button("Следующий") { bridge.musicNext() }
                }

                Section("Навигация") {
                    TextField("Куда ехать", text: $destination)
                    Button("Построить маршрут") {
                        bridge.startNavigation(to: destination)
                    }.disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Открыть Apple Maps") {
                        bridge.setDestination(destination)
                        bridge.openMaps()
                    }.disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Остановить") { bridge.stopNavigation() }
                    Text(bridge.navigationState).foregroundStyle(.secondary)
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
