from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('        super.init()\n', '        super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# Use WRITE-with-response whenever supported. ChronosESP32 exposes WRITE and WRITE_NR;
# WRITE gives a completion callback and avoids canSendWriteWithoutResponse stalls.
s = re.sub(r'    private var withoutResponseBusy: Bool = false\n', '', s)
s = re.sub(r'    private var withoutResponseBusy = false\n', '', s)
s = s.replace('withoutResponseBusy = false; ', '')
s = s.replace('withoutResponseBusy = false\n', '')
s = s.replace('withoutResponseBusy = true\n', '')

s = re.sub(r'    private func flushQueue\(\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didWriteValueFor', '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst()
            writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withResponse)
        } else if c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse {
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushQueue() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor''', s, count=1, flags=re.S)

# Exact ChronosESP32 phone-battery protocol.
s = re.sub(r'    private var lastBatteryResponse = Date\.distantPast\n', '', s)
s = re.sub(r'        let now = Date\(\)\n        if now\.timeIntervalSince\(lastBatteryResponse\) < 0\.35 \{ return \}\n        lastBatteryResponse = now\n', '', s)
s = s.replace('        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', '        guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', 1)

s = re.sub(r'    private func startSyncTimers\(\) \{.*?\n    \}\n', '''    private func startSyncTimers() {
        syncTimer?.invalidate()
        batteryTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendTime()
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sendBatterySnapshot(reason: "PERIODIC")
        }
    }
''', s, count=1, flags=re.S)
s = s.replace('batteryTimer?.invalidate()', '')
s = s.replace('        addLog("RX: \\(hex(data))")\n', '        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")\n', 1)

# MPRemoteCommandCenter is for receiving remote events, not injecting them into Music.app.
s = re.sub(r'    private let remote = MPRemoteCommandCenter\.shared\(\)\n', '', s)
s = re.sub(r'\n    private func setupRemoteCommands\(\) \{.*?\n    \}\n', '\n', s, count=1, flags=re.S)
s = s.replace('        setupRemoteCommands()\n', '')
s = s.replace('        remote.playCommand.removeTarget(nil)\n        remote.pauseCommand.removeTarget(nil)\n        remote.togglePlayPauseCommand.removeTarget(nil)\n        remote.nextTrackCommand.removeTarget(nil)\n        remote.previousTrackCommand.removeTarget(nil)\n', '')

# Remove any previous music function definitions. This avoids regex collisions with nested closures.
s = re.sub(r'    func musicPlay\(source: String = "APP"\) \{.*?^    \}\n', '', s, flags=re.S|re.M)
s = re.sub(r'    func musicPause\(source: String = "APP"\) \{.*?^    \}\n', '', s, flags=re.S|re.M)
s = re.sub(r'    func musicPrevious\(source: String = "APP"\) \{.*?^    \}\n', '', s, flags=re.S|re.M)
s = re.sub(r'    func musicNext\(source: String = "APP"\) \{.*?^    \}\n', '', s, flags=re.S|re.M)

# Insert deterministic music methods immediately before Navigation.
marker = '    // MARK: Navigation\n'
music_methods = '''    func musicPlay(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.prepareToPlay()\n        music.play()\n        playbackChanged()\n        addLog("MUSIC PLAY [\\(source)]")\n    }\n\n    func musicPause(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.pause()\n        playbackChanged()\n        addLog("MUSIC PAUSE [\\(source)]")\n    }\n\n    func musicPrevious(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.skipToPreviousItem()\n        playbackChanged()\n        addLog("MUSIC PREVIOUS [\\(source)]")\n    }\n\n    func musicNext(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        music.skipToNextItem()\n        playbackChanged()\n        addLog("MUSIC NEXT [\\(source)]")\n    }\n\n'''
if marker in s:
    s = s.replace(marker, music_methods + marker, 1)
else:
    raise SystemExit('v24: Navigation marker not found')

# Exact Chronos Control enum mapping: 9D00 play, 9D01 pause, 9D02 previous, 9D03 next.
s = s.replace('if b.count >= 7, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 'if b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 1)

checks = {
    'battery monitoring': 'UIDevice.current.isBatteryMonitoringEnabled = true' in s,
    'write-with-response': 'TX WITH_RESPONSE:' in s,
    'battery protocol': 'b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91' in s,
    'music previous': 'func musicPrevious(source: String = "APP")' in s,
    'music next': 'func musicNext(source: String = "APP")' in s,
    'music pause': 'func musicPause(source: String = "APP")' in s,
    'music play': 'func musicPlay(source: String = "APP")' in s,
    'remote removed': 'MPRemoteCommandCenter.shared()' not in s,
}
for k, v in checks.items():
    print('v24', k + ':', v)
    if not v:
        raise SystemExit('v24 validation failed: ' + k)

p.write_text(s, encoding='utf-8')
