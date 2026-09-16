from pathlib import Path
import re

# First apply the known-good v26 protocol fixes, then apply the v27 transport/music hardening.
exec(Path('MochiBridge/fix_v26.py').read_text(encoding='utf-8'), {'__name__': '__main__'})

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# The ESP32 Chronos server exposes RX as WRITE | WRITE_NR. Prefer WRITE with response on iOS:
# it is slower but gives an explicit acknowledgement and avoids CoreBluetooth flow-control
# edge cases seen with WRITE_NR on some iPhone/ESP32 combinations.
old_flush = '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if c.properties.contains(.writeWithoutResponse) {
            guard p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst()
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
new_flush = '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }

        // Prefer WRITE WITH RESPONSE. ChronosESP32 explicitly exposes both WRITE and WRITE_NR,
        // and WRITE gives CoreBluetooth a deterministic completion callback for every packet.
        if c.properties.contains(.write) {
            guard !writing else { return }
            let data = queue.removeFirst()
            writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withResponse)
            return
        }

        if c.properties.contains(.writeWithoutResponse) {
            guard p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
        }
    }
'''
if old_flush not in s:
    raise SystemExit('v27: expected v26 flushQueue not found')
s = s.replace(old_flush, new_flush, 1)

# A WRITE response can fail; retry that exact packet once instead of silently dropping it.
s = s.replace('''    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        addLog(error == nil ? "TX OK" : "TX ERROR: \\(error!.localizedDescription)")
        flushQueue()
    }
''', '''    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            addLog("TX ERROR: \\(error.localizedDescription)")
        } else {
            addLog("TX OK")
        }
        flushQueue()
    }
''', 1)

# Do not require Apple-Music library authorization for basic system-player control.
# The system music player controls the Music app state; library authorization is only needed
# when we query/build a local media-library queue.
music_helper = '''    private func ensureMusicReady() -> Bool {
        let auth = MPMediaLibrary.authorizationStatus()
        if auth == .notDetermined {
            requestMusicPermission()
        }

        // If Music already has a now-playing item, systemMusicPlayer can control it without
        // replacing the user's queue. This is the preferred path for Play/Pause/Next/Previous.
        if music.nowPlayingItem != nil {
            return true
        }

        // If the user granted library access, create a queue only when there is no current item.
        if auth == .authorized {
            let query = MPMediaQuery.songs()
            if let items = query.items, !items.isEmpty {
                music.setQueue(with: query)
                addLog("MUSIC: очередь загружена (\\(items.count) треков)")
                return true
            }
            addLog("MUSIC: локальная медиатека Apple Music пуста")
        }

        // Still allow the system player operation to be attempted. This is important for a
        // currently-playing Music session and avoids turning a permission prompt into a hard stop.
        return true
    }
'''
s = re.sub(r'    private func ensureMusicReady\(\) -> Bool \{.*?\n    \}\n\n    func musicPlay', music_helper + '\n    func musicPlay', s, count=1, flags=re.S)

# Make Play/Pause/Next/Previous resilient when prepareToPlay is unavailable or there is no local queue.
s = re.sub(r'''    func musicPlay\(source: String = "APP"\) \{.*?\n    \}\n    func musicPause''', '''    func musicPlay(source: String = "APP") {
        guard ensureMusicReady() else { return }
        music.prepareToPlay { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.addLog("MUSIC PREPARE ERROR: \\(error.localizedDescription)")
                    // Try the system player anyway; some Music sessions do not need prepareToPlay.
                }
                self?.music.play()
                self?.playbackChanged()
                self?.addLog("MUSIC PLAY [\\(source)]")
            }
        }
    }
    func musicPause''', s, count=1, flags=re.S)

# Poll the iPhone battery more often while connected. The value is always read fresh immediately
# before encoding, so this also handles iOS battery changes without waiting for a notification.
s = s.replace('''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''', '''        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
''', 1)

# Give the user an explicit battery-sync action in the UI and make the current phone value visible.
s = s.replace('''                    Button("Отправить заряд") { bridge.sendBattery() }
''', '''                    Button("Отправить заряд") { bridge.sendBattery() }
                    Text(bridge.battery >= 0 ? "iPhone: \\(bridge.battery)%" : "iPhone: —")
''', 1)

required = [
    'Prefer WRITE WITH RESPONSE',
    'MUSIC PREPARE ERROR:',
    'withTimeInterval: 5',
    'iPhone: \\(bridge.battery)%'
]
for x in required:
    if x not in s:
        raise SystemExit('V27 validation failed: ' + x)

p.write_text(s, encoding='utf-8')
print('V27 PATCH OK')
