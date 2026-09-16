from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('        super.init()\n', '        super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# Prefer WRITE-with-response. ChronosESP32 exposes both WRITE and WRITE_NR; WRITE gives
# an explicit completion callback and avoids the iOS canSendWriteWithoutResponse stall.
s = re.sub(r'    private var withoutResponseBusy: Bool = false\n', '', s)
s = re.sub(r'    private var withoutResponseBusy = false\n', '', s)
s = s.replace('withoutResponseBusy = false; ', '')
s = s.replace('withoutResponseBusy = false\n', '')
s = s.replace('withoutResponseBusy = true\n', '')

queue_block = r'''        if c.properties.contains(.writeWithoutResponse) {
            guard !withoutResponseBusy, p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst(); withoutResponseBusy = true
            addLog("TX: \(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                guard let self, self.withoutResponseBusy else { return }
                self.withoutResponseBusy = false; self.flushQueue()
            }
        } else if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst(); writing = true
            addLog("TX: \(hex(data))"); p.writeValue(data, for: c, type: .withResponse)
        }'''
queue_new = '''        if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst()
            writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withResponse)
        } else if c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse {
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushQueue() }
        }'''
s = s.replace(queue_block, queue_new)

if 'TX WITH_RESPONSE:' not in s:
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

# Exact ChronosESP32 phone battery protocol.
s = re.sub(r'    private var lastBatteryResponse = Date\.distantPast\n', '', s)
s = re.sub(r'        let now = Date\(\)\n        if now\.timeIntervalSince\(lastBatteryResponse\) < 0\.35 \{ return \}\n        lastBatteryResponse = now\n', '', s)
s = s.replace('        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', '        guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', 1)

# Periodic fallback plus immediate response to a Mochi request.
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

# MPRemoteCommandCenter receives remote events; it is not a way to inject commands into Music.app.
s = re.sub(r'    private let remote = MPRemoteCommandCenter\.shared\(\)\n', '', s)
s = re.sub(r'\n    private func setupRemoteCommands\(\) \{.*?\n    \}\n', '\n', s, count=1, flags=re.S)
s = s.replace('        setupRemoteCommands()\n', '')
s = s.replace('        remote.playCommand.removeTarget(nil)\n        remote.pauseCommand.removeTarget(nil)\n        remote.togglePlayPauseCommand.removeTarget(nil)\n        remote.nextTrackCommand.removeTarget(nil)\n        remote.previousTrackCommand.removeTarget(nil)\n', '')

# Replace only the four music functions, then verify they exist.
s = re.sub(r'    func musicPlay\(source: String = "APP"\) \{.*?\n    \}\n', '''    func musicPlay(source: String = "APP") {
        guard ensureMusicReady() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.music.prepareToPlay()
            self.music.play()
            self.playbackChanged()
            self.addLog("MUSIC PLAY [\\(source)]")
        }
    }
''', s, count=1, flags=re.S)
s = re.sub(r'    func musicPause\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicPause(source: String = "APP") { guard ensureMusicReady() else { return }; music.pause(); playbackChanged(); addLog("MUSIC PAUSE [\\(source)]") }\n', s, count=1, flags=re.S)
s = re.sub(r'    func musicPrevious\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicPrevious(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToPreviousItem(); playbackChanged(); addLog("MUSIC PREVIOUS [\\(source)]") }\n', s, count=1, flags=re.S)
s = re.sub(r'    func musicNext\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicNext(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToNextItem(); playbackChanged(); addLog("MUSIC NEXT [\\(source)]") }\n', s, count=1, flags=re.S)

# If a previous transformation removed these functions, restore them before Navigation.
marker = '    // MARK: Navigation\n'
if 'func musicPrevious(source: String = "APP")' not in s:
    s = s.replace(marker, '''    func musicPrevious(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToPreviousItem(); playbackChanged(); addLog("MUSIC PREVIOUS [\\(source)]") }

'''+marker, 1)
if 'func musicNext(source: String = "APP")' not in s:
    s = s.replace(marker, '''    func musicNext(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToNextItem(); playbackChanged(); addLog("MUSIC NEXT [\\(source)]") }

'''+marker, 1)
if 'func musicPause(source: String = "APP")' not in s:
    s = s.replace(marker, '''    func musicPause(source: String = "APP") { guard ensureMusicReady() else { return }; music.pause(); playbackChanged(); addLog("MUSIC PAUSE [\\(source)]") }

'''+marker, 1)
if 'func musicPlay(source: String = "APP")' not in s:
    s = s.replace(marker, '''    func musicPlay(source: String = "APP") { guard ensureMusicReady() else { return }; music.prepareToPlay(); music.play(); playbackChanged(); addLog("MUSIC PLAY [\\(source)]") }

'''+marker, 1)

# Exact Chronos Control enum mapping: 9D00 play, 9D01 pause, 9D02 previous, 9D03 next.
s = s.replace('if b.count >= 7, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 'if b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 1)

print('v24 battery monitoring:', 'UIDevice.current.isBatteryMonitoringEnabled = true' in s)
print('v24 write-with-response:', 'TX WITH_RESPONSE:' in s)
print('v24 battery protocol:', 'b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91' in s)
print('v24 exact music protocol:', 'b[4] == 0x9D' in s)
print('v24 music previous:', 'func musicPrevious(source: String = "APP")' in s)
print('v24 music next:', 'func musicNext(source: String = "APP")' in s)
print('v24 stale remote:', 'MPRemoteCommandCenter.shared()' in s)

p.write_text(s, encoding='utf-8')
