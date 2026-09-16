from pathlib import Path

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

def replace_once(old, new, name):
    global s
    if old not in s:
        raise SystemExit(f'v28b: block not found: {name}')
    s = s.replace(old, new, 1)

replace_once('''        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else {
            status = "RX не поддерживает запись"; addLog("BLE ERROR: RX write property отсутствует"); return
        }
        ready = true; status = "Подключено"
        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"
        addLog("BLE READY RX=\\(r.properties.rawValue) MODE=\\(mode) TX=\\(tx != nil ? "OK" : "нет")")
        sendTime()
        sendBatterySnapshot(reason: "CONNECT")
        startSyncTimers()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { addLog("NOTIFY ERROR: \\(error.localizedDescription)") }
        else { addLog("NOTIFY \\(characteristic.isNotifying ? "ON" : "OFF")") }
    }
''','''        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else {
            status = "RX не поддерживает запись"; addLog("BLE ERROR: RX write property отсутствует"); return
        }
        guard tx != nil else {
            status = "TX уведомления не найден"; addLog("BLE ERROR: TX notify characteristic missing"); return
        }
        ready = false
        status = "Подключено — включаю уведомления…"
        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"
        addLog("BLE CHARACTERISTICS RX=\\(r.properties.rawValue) MODE=\\(mode) TX=OK")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            ready = false
            addLog("NOTIFY ERROR: \\(error.localizedDescription)")
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
        startSyncTimers()
    }
''','BLE notify readiness')

replace_once('''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if c.properties.contains(.writeWithoutResponse) {
            guard !withoutResponseBusy, p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst(); withoutResponseBusy = true
            addLog("TX: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                guard let self, self.withoutResponseBusy else { return }
                self.withoutResponseBusy = false; self.flushQueue()
            }
        } else if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst(); writing = true
            addLog("TX: \\(hex(data))"); p.writeValue(data, for: c, type: .withResponse)
        }
    }
''','''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if c.properties.contains(.writeWithoutResponse) {
            guard !withoutResponseBusy, p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst()
            withoutResponseBusy = true
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            return
        }
        if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst()
            writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withResponse)
        }
    }
''','BLE queue')

replace_once('''    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        withoutResponseBusy = false; addLog("BLE READY FOR TX"); flushQueue()
    }
''','''    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        withoutResponseBusy = false
        addLog("BLE READY FOR TX")
        flushQueue()
    }
''','BLE flow control')

replace_once('''        if !queue.isEmpty { addLog("BLE: очередь сохранена (\\(queue.count))") }
        status = "Отключено — переподключение…"
''','''        if !queue.isEmpty { addLog("BLE: сброшена устаревшая очередь (\\(queue.count))") }
        queue.removeAll()
        status = "Отключено — переподключение…"
''','disconnect queue')

replace_once('addLog("RX: \\(hex(data))")','addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")','RX log')

replace_once('''        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }
''','''        guard b.count == 7,
              b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04,
              b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }
''','battery request')

replace_once('''        let level = UInt8(max(0, min(100, battery)))
        let state: UInt8 = charging ? 0x01 : 0x00
        let packet: [UInt8] = [0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, state, level]
''','''        let raw = UIDevice.current.batteryLevel
        if raw >= 0 {
            battery = max(0, min(100, Int(round(raw * 100))))
            charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        }
        let level = UInt8(max(0, min(100, battery)))
        let state: UInt8 = charging ? 0x01 : 0x00
        addLog("BATTERY RAW=\\(raw) LEVEL=\\(level)% STATE=\\(UIDevice.current.batteryState.rawValue)")
        let packet: [UInt8] = [0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, state, level]
''','battery encoding')

replace_once('''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''','''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''','battery timer')

replace_once('''    private func ensureMusicReady() -> Bool {
        let auth = MPMediaLibrary.authorizationStatus()
        guard auth == .authorized else { musicPermission = "Нет доступа"; addLog("MUSIC: нет разрешения Apple Music"); requestMusicPermission(); return false }
        return true
    }
''','''    private func ensureMusicReady() -> Bool {
        let auth = MPMediaLibrary.authorizationStatus()
        if music.nowPlayingItem != nil {
            musicPermission = auth == .authorized ? "Разрешено" : "Активная сессия"
            return true
        }
        if auth == .notDetermined {
            requestMusicPermission()
            addLog("MUSIC: запрос разрешения Apple Music")
            return false
        }
        guard auth == .authorized else {
            musicPermission = "Нет доступа"
            addLog("MUSIC: нет доступа к Apple Music")
            return false
        }
        let query = MPMediaQuery.songs()
        guard let items = query.items, !items.isEmpty else {
            musicPermission = "Нет треков в медиатеке"
            addLog("MUSIC: локальная медиатека Apple Music пуста")
            return false
        }
        music.setQueue(with: query)
        musicPermission = "Разрешено"
        addLog("MUSIC: очередь загружена (\\(items.count) треков)")
        return true
    }
''','music readiness')

replace_once('''    func musicPlay(source: String = "APP") {
        guard ensureMusicReady() else { return }
        music.prepareToPlay { [weak self] _ in
            DispatchQueue.main.async {
                self?.music.play(); self?.playbackChanged(); self?.addLog("MUSIC PLAY [\\(source)]")
            }
        }
    }
''','''    func musicPlay(source: String = "APP") {
        guard ensureMusicReady() else { return }
        music.prepareToPlay { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.addLog("MUSIC PREPARE ERROR: \\(error.localizedDescription)")
                    return
                }
                self?.music.play()
                self?.playbackChanged()
                self?.addLog("MUSIC PLAY [\\(source)]")
            }
        }
    }
''','music play')

replace_once('Text("Доступ: \\(bridge.musicPermission)")','Text("Apple Music: \\(bridge.musicPermission)")','music UI')

required = [
    'NOTIFY ON — BLE READY FOR TX/RX',
    'TX WITHOUT_RESPONSE:',
    'BATTERY RAW=',
    'b.count == 7',
    'Apple Music:',
    'MUSIC PREPARE ERROR:'
]
for marker in required:
    if marker not in s:
        raise SystemExit('V28B validation failed: ' + marker)

p.write_text(s, encoding='utf-8')
print('V28B PATCH OK')
