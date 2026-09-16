from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# Keep BLE ready state tied to successful TX notification subscription.
s = s.replace('''        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"\n        addLog("BLE READY RX=\\(r.properties.rawValue) MODE=\\(mode) TX=\\(tx != nil ? "OK" : "нет")")\n        sendTime()\n        sendBatterySnapshot(reason: "CONNECT")\n        startSyncTimers()\n''', '''        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"\n        addLog("BLE CHARACTERISTICS RX=\\(r.properties.rawValue) MODE=\\(mode) TX=\\(tx != nil ? "OK" : "нет")")\n        if tx == nil { addLog("BLE ERROR: TX notify characteristic missing") }\n''')

# Prefer the actual Chronos RX write-without-response capability; this characteristic is WRITE | WRITE_NR.
# Use CoreBluetooth flow control rather than an arbitrary delay.
new_flush = '''    private func flushQueue() {\n        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }\n        if c.properties.contains(.writeWithoutResponse) {\n            guard p.canSendWriteWithoutResponse else { return }\n            let data = queue.removeFirst()\n            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withoutResponse)\n            return\n        }\n        if !writing && c.properties.contains(.write) {\n            let data = queue.removeFirst()\n            writing = true\n            addLog("TX WITH_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withResponse)\n        }\n    }\n'''
s = re.sub(r'    private func flushQueue\(\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didWriteValueFor', new_flush + '\n    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor', s, count=1, flags=re.S)

# Notification callback is the point where the bridge becomes operational.
s = re.sub(r'    func peripheral\(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error\?\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didUpdateValueFor', '''    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {\n        guard characteristic.uuid == Self.txUUID else { return }\n        if let error {\n            ready = false\n            addLog("NOTIFY ERROR: \\(error.localizedDescription)")\n            return\n        }\n        if characteristic.isNotifying {\n            ready = true\n            status = "Подключено"\n            addLog("NOTIFY ON — BLE READY FOR TX/RX")\n            sendTime()\n            sendBatterySnapshot(reason: "CONNECT")\n            startSyncTimers()\n        } else {\n            ready = false\n            addLog("NOTIFY OFF")\n        }\n    }\n\n    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor''', s, count=1, flags=re.S)

# Make RX logging explicit about the characteristic UUID.
s = s.replace('addLog("RX: \\(hex(data))")', 'addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")', 1)

# Battery request: exact Chronos request is AB 00 04 FE 91 80 01.
s = re.sub(r'guard b\.count >= 7, b\[3\] == 0xFE, b\[4\] == 0x91, b\[5\] == 0x80, b\[6\] == 0x01 else \{ return \}',
            'guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }', s, count=1)

# Music commands: ChronosESP32 sends FF 9D 80 command. Keep FE as a diagnostic compatibility variant.
s = s.replace('if b.count >= 7, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 'if b.count >= 7, (b[3] == 0xFF || b[3] == 0xFE), b[4] == 0x9D, b[5] == 0x80 {', 1)

# Fresh battery diagnostics: log the raw public iOS value that is actually encoded.
s = s.replace('''        let level = UInt8(max(0, min(100, battery)))\n        let state: UInt8 = charging ? 0x01 : 0x00\n''', '''        let raw = UIDevice.current.batteryLevel\n        let fresh = raw >= 0 ? max(0, min(100, Int(round(raw * 100)))) : battery\n        battery = fresh\n        let level = UInt8(max(0, min(100, fresh)))\n        let state: UInt8 = charging ? 0x01 : 0x00\n        addLog("BATTERY RAW=\\(raw) LEVEL=\\(level)% STATE=\\(UIDevice.current.batteryState.rawValue)")\n''', 1)

# Improve Apple Music control. MPRemoteCommandCenter is a receiver of remote events, not a sender.
# systemMusicPlayer can control the Music app, but play/next/previous need a usable queue.
music_helper = '''    private func ensureMusicReady() -> Bool {\n        let auth = MPMediaLibrary.authorizationStatus()\n        guard auth == .authorized else {\n            musicPermission = "Нет доступа"\n            addLog("MUSIC: нет разрешения Apple Music")\n            requestMusicPermission()\n            return false\n        }\n        if music.nowPlayingItem == nil {\n            let query = MPMediaQuery.songs()\n            guard let items = query.items, !items.isEmpty else {\n                addLog("MUSIC: локальная медиатека Apple Music пуста")\n                musicPermission = "Нет треков в медиатеке"\n                return false\n            }\n            music.setQueue(with: query)\n            addLog("MUSIC: очередь загружена (\\(items.count) треков)")\n        }\n        return true\n    }\n'''
s = re.sub(r'    private func ensureMusicReady\(\) -> Bool \{.*?\n    \}\n\n    func musicPlay', music_helper + '\n    func musicPlay', s, count=1, flags=re.S)

s = re.sub(r'''    func musicPlay\(source: String = "APP"\) \{.*?\n    \}\n    func musicPause''', '''    func musicPlay(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.prepareToPlay { [weak self] error in\n            DispatchQueue.main.async {\n                if let error {\n                    self?.addLog("MUSIC PREPARE ERROR: \\(error.localizedDescription)")\n                    return\n                }\n                self?.music.play()\n                self?.playbackChanged()\n                self?.addLog("MUSIC PLAY [\\(source)]")\n            }\n        }\n    }\n    func musicPause''', s, count=1, flags=re.S)

s = re.sub(r'''    func musicPrevious\(source: String = "APP"\) \{.*?\n    \}\n    func musicNext\(source: String = "APP"\) \{.*?\n    \}\n''', '''    func musicPrevious(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.skipToPreviousItem()\n        addLog("MUSIC PREVIOUS [\\(source)]")\n        playbackChanged()\n    }\n    func musicNext(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.skipToNextItem()\n        addLog("MUSIC NEXT [\\(source)]")\n        playbackChanged()\n    }\n''', s, count=1, flags=re.S)

# Avoid stale packets surviving a disconnect/reconnect; the next connection regenerates time/battery.
s = s.replace('''        if !queue.isEmpty { addLog("BLE: очередь сохранена (\\(queue.count))") }\n''', '''        if !queue.isEmpty { addLog("BLE: сброшена устаревшая очередь (\\(queue.count))") }\n        queue.removeAll()\n''', 1)

# Make the UI explicit: music controls target the Apple Music library, not Spotify/YouTube.
s = s.replace('Text("Доступ: \\(bridge.musicPermission)")', 'Text("Apple Music: \\(bridge.musicPermission)")', 1)

required = [
    'BATTERY RAW=',
    'NOTIFY ON — BLE READY FOR TX/RX',
    'TX WITHOUT_RESPONSE:',
    'MUSIC: локальная медиатека Apple Music пуста',
    'music.setQueue(with: query)'
]
for x in required:
    if x not in s:
        raise SystemExit('V26 patch validation failed: ' + x)

p.write_text(s, encoding='utf-8')
print('V26 PATCH OK')
