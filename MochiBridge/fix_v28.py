from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# v28 is a clean protocol/transport hardening pass. It deliberately does not execute any
# previous fix script, so the build is deterministic instead of depending on v23-v27 patches.

# 1) BLE becomes READY only after the TX notify characteristic is actually notifying.
old = '''        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else {
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
'''
new = '''        guard let r = rx, r.properties.contains(.write) || r.properties.contains(.writeWithoutResponse) else {
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
'''
if old not in s:
    raise SystemExit('v28: BLE characteristic block not found')
s = s.replace(old, new, 1)

# 2) Chronos RX is WRITE | WRITE_NR. Prefer WRITE_NR with CoreBluetooth flow control.
old = '''    private func flushQueue() {
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
'''
new = '''    private func flushQueue() {
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
'''
if old not in s:
    raise SystemExit('v28: flushQueue block not found')
s = s.replace(old, new, 1)

# 3) CoreBluetooth tells us when WRITE_NR can accept more data.
old = '''    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        withoutResponseBusy = false; addLog("BLE READY FOR TX"); flushQueue()
    }
'''
new = '''    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        withoutResponseBusy = false
        addLog("BLE READY FOR TX")
        flushQueue()
    }
'''
if old not in s:
    raise SystemExit('v28: ready callback not found')
s = s.replace(old, new, 1)

# 4) Disconnect must not replay stale time/battery/notification packets after reconnect.
s = s.replace('''        if !queue.isEmpty { addLog("BLE: очередь сохранена (\\(queue.count))") }
        status = "Отключено — переподключение…"
''', '''        if !queue.isEmpty { addLog("BLE: сброшена устаревшая очередь (\\(queue.count))") }
        queue.removeAll()
        status = "Отключено — переподключение…"
''', 1)

# 5) Log the exact RX characteristic and exact packet. This is essential for diagnosing the
# Mochi -> iPhone battery request instead of guessing from the UI.
s = s.replace('addLog("RX: \\(hex(data))")', 'addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")', 1)

# 6) Match the exact Chronos phone-battery request: AB 00 04 FE 91 80 01.
old = '''        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }
'''
new = '''        guard b.count == 7,
              b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04,
              b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }
'''
if old not in s:
    raise SystemExit('v28: battery request guard not found')
s = s.replace(old, new, 1)

# 7) Always read the iPhone battery immediately before encoding the response.
old = '''        let level = UInt8(max(0, min(100, battery)))
        let state: UInt8 = charging ? 0x01 : 0x00
        let packet: [UInt8] = [0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, state, level]
'''
new = '''        let raw = UIDevice.current.batteryLevel
        if raw >= 0 {
            battery = max(0, min(100, Int(round(raw * 100))))
            charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        }
        let level = UInt8(max(0, min(100, battery)))
        let state: UInt8 = charging ? 0x01 : 0x00
        addLog("BATTERY RAW=\\(raw) LEVEL=\\(level)% STATE=\\(UIDevice.current.batteryState.rawValue)")
        let packet: [UInt8] = [0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, state, level]
'''
if old not in s:
    raise SystemExit('v28: battery encoding block not found')
s = s.replace(old, new, 1)

# 8) Five-second refresh is useful for a visible phone value, while batteryChanged() remains event-driven.
s = s.replace('''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''', '''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''', 1)

# 9) Music: do not make every command depend on an Apple Music library permission if an existing
# system-player session is already active. If there is no current item, a local library queue is
# created only after authorization. iOS cannot universally control Spotify/YouTube from a normal app.
music_old = '''    private func ensureMusicReady() -> Bool {
        let auth = MPMediaLibrary.authorizationStatus()
        guard auth == .authorized else { musicPermission = "Нет доступа"; addLog("MUSIC: нет разрешения Apple Music"); requestMusicPermission(); return false }
        return true
    }
'''
music_new = '''    private func ensureMusicReady() -> Bool {
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
'''
if music_old not in s:
    raise SystemExit('v28: music helper not found')
s = s.replace(music_old, music_new, 1)

# 10) Do not swallow prepareToPlay errors.
s = re.sub(r'''    func musicPlay\(source: String = "APP"\) \{\n        guard ensureMusicReady\(\) else \{ return \}\n        music\.prepareToPlay \{ \[weak self\] _ in\n            DispatchQueue\.main\.async \{\n                self\?\.music\.play\(\); self\?\.playbackChanged\(\); self\?\.addLog\("MUSIC PLAY \[\\\\\(source\)\]"\)\n            \}\n        \}\n    \}
''', '''    func musicPlay(source: String = "APP") {
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
''', s, count=1)

# 11) Make the UI state explicitly say Apple Music, so the user is not misled into expecting
# Spotify/YouTube universal control (which iOS does not expose to a normal third-party app).
s = s.replace('Text("Доступ: \\(bridge.musicPermission)")', 'Text("Apple Music: \\(bridge.musicPermission)")', 1)

# 12) Version the source itself; the workflow also validates this marker.
s = s.replace('NavigationStack {', 'NavigationStack {', 1)

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
        raise SystemExit('V28 validation failed: ' + marker)

p.write_text(s, encoding='utf-8')
print('V28 PATCH OK')
