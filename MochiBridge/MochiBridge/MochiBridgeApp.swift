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
    @Published var battery = 0
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
    private var isConnecting = false
    private var shouldReconnect = true
    private var queue: [Data] = []
    private var writing = false
    private let calls = CXCallObserver()
    private var activeCalls = Set<UUID>()
    private let music = MPMusicPlayerController.systemMusicPlayer
    private let location = CLLocationManager()
    private var destinationText = ""
    private var route: MKRoute?
    private var navStep = 0
    private var lastNavSend = Date.distantPast
    private var navigating = false

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
        music.beginGeneratingPlaybackNotifications()
        MPMediaLibrary.requestAuthorization { _ in }
    }

    deinit {
        reconnectTimer?.invalidate(); syncTimer?.invalidate()
        music.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            connected = false; ready = false
            status = central.state == .poweredOff ? "Включи Bluetooth на iPhone" : "Bluetooth недоступен"
            return
        }
        scan()
    }

    func scan() {
        guard central.state == .poweredOn, !connected, !isConnecting else { return }
        reconnectTimer?.invalidate(); central.stopScan()
        status = "Ищу THE MOCHI…"
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if !self.connected && !self.isConnecting { self.scheduleReconnect(2) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) { connect(p) }

    func connect(_ p: CBPeripheral) {
        guard !connected, !isConnecting else { return }
        central.stopScan(); reconnectTimer?.invalidate()
        peripheral = p; p.delegate = self; isConnecting = true; ready = false
        deviceName = p.name ?? "THE MOCHI"; status = "Подключение…"
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false; connected = true; ready = false
        peripheral.delegate = self; status = "Подключено — ищу характеристики…"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false; connected = false; ready = false; scheduleReconnect(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false; ready = false; rx = nil; tx = nil; writing = false; queue.removeAll()
        syncTimer?.invalidate(); status = "Отключено — переподключение…"; scheduleReconnect(1)
    }

    private func scheduleReconnect(_ delay: TimeInterval) {
        guard shouldReconnect, central.state == .poweredOn, !connected, !isConnecting else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.scan() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { central.cancelPeripheralConnection(peripheral); return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxUUID { rx = c }
            if c.uuid == Self.txUUID { tx = c; peripheral.setNotifyValue(true, for: c) }
        }
        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else { status = "RX не поддерживает запись"; return }
        ready = true; status = "Подключено"
        addLog("BLE READY RX=\(r.properties.rawValue) TX=\(tx != nil ? "OK" : "нет")")
        syncAll(); startSyncTimer()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        addLog("RX: \(hex(data))"); handleRobotCommand(Array(data))
    }

    private func send(_ bytes: [UInt8], label: String) {
        guard ready, let p = peripheral, let c = rx else { addLog("TX SKIP \(label): BLE не готов"); return }
        queue.append(Data(bytes)); addLog("QUEUE \(label): \(hex(Data(bytes)))"); processQueue(p, c)
    }

    private func processQueue(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard !writing, !queue.isEmpty else { return }
        let data = queue.removeFirst(); writing = true; addLog("TX: \(hex(data))")
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: c, type: type)
        if type == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.writing = false
                if let self, let p = self.peripheral, let c = self.rx { self.processQueue(p, c) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        addLog(error == nil ? "TX OK" : "TX ERROR: \(error!.localizedDescription)")
        writing = false; processQueue(peripheral, characteristic)
    }

    func syncAll() { sendBattery(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.sendTime() } }
    @objc private func batteryChanged() { if ready { sendBattery() } }

    func sendBattery() {
        guard ready else { return }
        let level = max(0, min(100, Int(round(UIDevice.current.batteryLevel * 100))))
        battery = level
        let charging: UInt8 = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full) ? 1 : 0
        send([0xAB,0x00,0x05,0xFF,0x91,0x80,charging,UInt8(level)], label: "BATTERY")
    }

    func sendTime() {
        guard ready else { return }
        let d = Date(); let c = Calendar.current
        let y=c.component(.year,from:d), mo=c.component(.month,from:d), da=c.component(.day,from:d)
        let h=c.component(.hour,from:d), mi=c.component(.minute,from:d), s=c.component(.second,from:d)
        send([0xAB,0x00,0x0B,0xFE,0x93,0x80,0x00,UInt8(y>>8),UInt8(y&255),UInt8(mo),UInt8(da),UInt8(h),UInt8(mi),UInt8(s)], label: "TIME")
    }

    func sendTestNotification() { sendNotification(text: "TEST", icon: 0x0A) }
    func sendNotification(text: String, icon: UInt8 = 0xC0) {
        let msg = transliterate(text); let payload = Array(msg.utf8)
        guard payload.count + 5 <= 255 else { return }
        send([0xAB,0x00,UInt8(payload.count + 5),0xFF,0x72,0x80,icon,0x02] + payload, label: "NOTIFICATION")
    }

    private func sendIncomingCall(_ name: String = "Входящий звонок") {
        let msg = Array(transliterate(name).utf8)
        send([0xAB,0x00,UInt8(msg.count + 5),0xFF,0x72,0x80,0x01,0x01] + msg, label: "CALL IN")
    }
    private func endCall() { send([0xAB,0x00,0x05,0xFF,0x72,0x80,0x02,0x00], label: "CALL END") }

    private func handleRobotCommand(_ b: [UInt8]) {
        guard b.count >= 7, b[0] == 0xAB, b[3] == 0xFF else { return }
        if b[4] == 0x9D && b[5] == 0x80 {
            switch b[6] { case 0x00: musicPlay(); case 0x01: musicPause(); case 0x02: musicPrevious(); case 0x03: musicNext(); default: break }
        }
    }

    func musicPlay() { music.play(); musicState = "▶︎"; addLog("MUSIC PLAY") }
    func musicPause() { music.pause(); musicState = "⏸"; addLog("MUSIC PAUSE") }
    func musicToggle() { music.playbackState == .playing ? musicPause() : musicPlay() }
    func musicPrevious() { music.skipToPreviousItem(); addLog("MUSIC PREVIOUS") }
    func musicNext() { music.skipToNextItem(); addLog("MUSIC NEXT") }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasEnded && !call.isOutgoing && !call.hasConnected {
            if activeCalls.insert(call.uuid).inserted { callState = "Входящий"; sendIncomingCall() }
        } else if call.hasEnded && activeCalls.remove(call.uuid) != nil { callState = "Нет звонка"; endCall() }
    }

    func setDestination(_ text: String) { destinationText = text }

    func startNavigation(to text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { navigationState = "Укажи пункт назначения"; return }
        destinationText = query
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        guard let user = location.location else { location.requestLocation(); navigationState = "Определи местоположение и нажми ещё раз"; return }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center:user.coordinate, latitudinalMeters:10000, longitudinalMeters:10000)
        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self, let item = response?.mapItems.first, error == nil else { self?.navigationState = "Не найден пункт назначения"; return }
            let req = MKDirections.Request(); req.source = MKMapItem(placemark: MKPlacemark(coordinate: user.coordinate)); req.destination = item; req.transportType = .automobile
            MKDirections(request: req).calculate { [weak self] response, error in
                guard let self, let r = response?.routes.first, error == nil else { self?.navigationState = "Не удалось построить маршрут"; return }
                self.route = r; self.navStep = min(1, max(0, r.steps.count - 1)); self.navigating = true
                self.navigationState = "Маршрут: \(String(format: "%.1f", r.distance / 1000)) км"
                self.location.startUpdatingLocation(); self.sendNavigation()
            }
        }
    }

    func stopNavigation() {
        navigating = false; route = nil; location.stopUpdatingLocation(); navigationState = "Не запущена"; sendNavigationInactive()
    }

    func openMaps() {
        guard let encoded = destinationText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways, navigating { manager.startUpdatingLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard navigating, let loc = locations.last, let r = route else { return }
        if navStep < r.steps.count - 1 && loc.distance(from: r.steps[navStep].polyline.coordinate.clLocation) < 35 { navStep += 1 }
        if Date().timeIntervalSince(lastNavSend) > 3 { sendNavigation(); lastNavSend = Date() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { navigationState = "GPS: \(error.localizedDescription)" }

    private func sendNavigation() {
        guard let r = route, navStep < r.steps.count else { return }
        let step = r.steps[navStep]
        let direction = step.instructions.isEmpty ? "Продолжайте движение" : step.instructions
        let distance = step.distance >= 1000 ? String(format: "%.1f km", step.distance/1000) : String(format: "%.0f m", step.distance)
        let eta = Date().addingTimeInterval(r.expectedTravelTime).formatted(date: .omitted, time: .shortened)
        sendNavPacket(title:"Navigation", duration:formatDuration(r.expectedTravelTime), distance:distance, eta:eta, directions:direction)
    }
    private func sendNavigationInactive() { send([0xAB,0x00,0x03,0xFE,0xEF,0x80,0x00], label:"NAV STOP") }
    private func sendNavPacket(title:String,duration:String,distance:String,eta:String,directions:String) {
        var body:[UInt8] = [0xFE,0xEF,0x80,0x00,0x00,0x00,0x00]
        for s in [title,duration,distance,eta,directions] { body += Array(s.utf8) + [0] }
        guard body.count <= 255 else { return }; send([0xAB,0x00,UInt8(body.count)] + body, label:"NAV")
    }
    private func formatDuration(_ seconds:TimeInterval)->String { let m=max(0,Int(seconds/60)); return m >= 60 ? "\(m/60) h \(m%60) min" : "\(m) min" }

    private func startSyncTimer() {
        syncTimer?.invalidate(); syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.syncAll() }
    }

    private func transliterate(_ text:String)->String {
        let m:[Character:String] = ["А":"A","Б":"B","В":"V","Г":"G","Д":"D","Е":"E","Ё":"Yo","Ж":"Zh","З":"Z","И":"I","Й":"Y","К":"K","Л":"L","М":"M","Н":"N","О":"O","П":"P","Р":"R","С":"S","Т":"T","У":"U","Ф":"F","Х":"Kh","Ц":"Ts","Ч":"Ch","Ш":"Sh","Щ":"Sch","Ъ":"","Ы":"Y","Ь":"","Э":"E","Ю":"Yu","Я":"Ya","а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"yo","ж":"zh","з":"z","и":"i","й":"y","к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"kh","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya"]
        return text.map { m[$0] ?? String($0) }.joined()
    }
    private func hex(_ d:Data)->String { d.map { String(format:"%02X",$0) }.joined(separator:" ") }
    func addLog(_ s:String) { log.insert(s,at:0); if log.count > 80 { log.removeLast() } }
}

private extension CLLocationCoordinate2D { var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) } }

struct ContentView: View {
    @ObservedObject var bridge:MochiBridge
    @State private var text = "TEST"
    @State private var destination = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Mochi") {
                    HStack { Text("Статус"); Spacer(); Text(bridge.status).foregroundStyle(bridge.connected ? .green : .secondary) }
                    Text(bridge.deviceName)
                    Button("Поиск снова") { bridge.scan() }
                }
                Section("Телефон") {
                    Button("Заряд iPhone: \(bridge.battery)%") { bridge.sendBattery() }
                    Button("Отправить время") { bridge.sendTime() }
                    Text("Звонки: \(bridge.callState)")
                }
                Section("Уведомления") {
                    TextField("Текст", text:$text)
                    Button("Отправить TEST") { bridge.sendTestNotification() }
                    Button("Отправить на Mochi") { bridge.sendNotification(text:text) }
                }
                Section("Музыка") {
                    Text("Apple Music: \(bridge.musicState)")
                    Button("Play / Pause") { bridge.musicToggle() }
                    Button("Предыдущий") { bridge.musicPrevious() }
                    Button("Следующий") { bridge.musicNext() }
                }
                Section("Навигация") {
                    TextField("Куда ехать", text:$destination)
                    Button("Начать навигацию") { bridge.startNavigation(to: destination) }.disabled(destination.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("Открыть Apple Maps") { bridge.setDestination(destination); bridge.openMaps() }.disabled(destination.isEmpty)
                    Button("Остановить") { bridge.stopNavigation() }
                    Text(bridge.navigationState).foregroundStyle(.secondary)
                }
                Section("BLE LOG") {
                    ForEach(Array(bridge.log.enumerated()), id:\.offset) { _, line in Text(line).font(.system(.caption,design:.monospaced)) }
                }
            }.navigationTitle("Mochi Bridge")
        }
    }
}
