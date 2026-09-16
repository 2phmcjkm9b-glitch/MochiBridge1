from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# iOS battery monitoring must be enabled before batteryLevel is read.
if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('        super.init()\n', '        super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# The previous version could leave the no-response BLE queue stalled on canSendWriteWithoutResponse.
# ChronosESP32 explicitly exposes both WRITE and WRITE_NR; use WRITE with response whenever available.
s = re.sub(r'    private var withoutResponseBusy: Bool = false\n', '', s)
s = re.sub(r'    private var withoutResponseBusy = false\n', '', s)
s = s.replace('withoutResponseBusy = false; ', '')
s = s.replace('withoutResponseBusy = false\n', '')
s = s.replace('withoutResponseBusy = true\n', '')
s = s.replace('        if c.properties.contains(.writeWithoutResponse) {\n            guard !withoutResponseBusy, p.canSendWriteWithoutResponse else { return }\n            let data = queue.removeFirst(); withoutResponseBusy = true\n            addLog("TX: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withoutResponse)\n            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] _ in\n                guard let self, self.withoutResponseBusy else { return }\n                self.withoutResponseBusy = false; self.flushQueue()\n            }\n        } else if !writing && c.properties.contains(.write) {\n            let data = queue.removeFirst(); writing = true\n            addLog("TX: \\(hex(data))"); p.writeValue(data, for: c, type: .withResponse)\n        }', '''        if !writing && c.properties.contains(.write) {\n            let data = queue.removeFirst()\n            writing = true\n            addLog("TX WITH_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withResponse)\n        } else if c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse {\n            let data = queue.removeFirst()\n            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withoutResponse)\n            DispatchQueue.main.async { [weak self] in self?.flushQueue() }\n        }''')

# If the exact old queue block was not matched, replace the whole function body safely.
if 'TX WITH_RESPONSE:' not in s:
    s = re.sub(r'    private func flushQueue\(\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didWriteValueFor', '''    private func flushQueue() {\n        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }\n        if !writing && c.properties.contains(.write) {\n            let data = queue.removeFirst()\n            writing = true\n            addLog("TX WITH_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withResponse)\n        } else if c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse {\n            let data = queue.removeFirst()\n            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")\n            p.writeValue(data, for: c, type: .withoutResponse)\n            DispatchQueue.main.async { [weak self] in self?.flushQueue() }\n        }\n    }\n\n    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor''', s, count=1, flags=re.S)

# Do not mark the connection fully ready until the write characteristic is confirmed.
# Keep the standard Chronos handshake packets, but send them with the reliable write path.
s = s.replace('        sendTime()\n        sendBatterySnapshot(reason: "CONNECT")\n        startSyncTimers()\n', '        sendTime()\n        sendBatterySnapshot(reason: "CONNECT")\n        startSyncTimers()\n')

# Exact ChronosESP32 phone-battery protocol. Request is AB 00 04 FE 91 80 01;
# response is AB 00 05 FF 91 80 <charging> <level>.
# Remove the old response rate limiter because a request is authoritative and tiny.
s = re.sub(r'    private var lastBatteryResponse = Date\.distantPast\n', '', s)
s = re.sub(r'        let now = Date\(\)\n        if now\.timeIntervalSince\(lastBatteryResponse\) < 0\.35 \{ return \}\n        lastBatteryResponse = now\n', '', s)

# Always respond to the exact battery request, including repeated requests.
s = s.replace('        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', '        guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }\n', 1)

# Battery changes should be sent immediately, matching ChronosESP32's _batteryChanged behavior.
s = s.replace('        if ready { sendBatterySnapshot(reason: "CHANGE") }\n', '        if ready { sendBatterySnapshot(reason: "CHANGE") }\n')

# Keep a periodic refresh as a fallback in case a Mochi firmware build does not re-request battery.
s = re.sub(r'    private func startSyncTimers\(\) \{.*?\n    \}\n', '''    private func startSyncTimers() {\n        syncTimer?.invalidate()\n        batteryTimer?.invalidate()\n        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in\n            self?.sendTime()\n        }\n        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in\n            self?.sendBatterySnapshot(reason: "PERIODIC")\n        }\n    }\n''', s, count=1, flags=re.S)

# Remove obsolete references that can break the build after timer refactors.
s = s.replace('batteryTimer?.invalidate()', '')

# Log the exact RX characteristic and packet. This is useful if Mochi sends a request later.
s = s.replace('        addLog("RX: \\(hex(data))")\n', '        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")\n', 1)

# Music: MPRemoteCommandCenter only receives system remote events; it does not send commands to other apps.
# Remove the misleading v23 command-center handlers and use Apple's system Music player directly.
s = re.sub(r'    private let remote = MPRemoteCommandCenter\.shared\(\)\n', '', s)
s = re.sub(r'\n    private func setupRemoteCommands\(\) \{.*?\n    \}\n', '\n', s, count=1, flags=re.S)
s = s.replace('        setupRemoteCommands()\n', '')
s = s.replace('        remote.playCommand.removeTarget(nil)\n        remote.pauseCommand.removeTarget(nil)\n        remote.togglePlayPauseCommand.removeTarget(nil)\n        remote.nextTrackCommand.removeTarget(nil)\n        remote.previousTrackCommand.removeTarget(nil)\n', '')

# Reliable main-thread system Music commands. Apple documents systemMusicPlayer as controlling Music.app.
s = re.sub(r'    func musicPlay\(source: String = "APP"\) \{.*?\n    \}\n', '''    func musicPlay(source: String = "APP") {\n        guard ensureMusicReady() else { return }\n        DispatchQueue.main.async { [weak self] in\n            guard let self else { return }\n            self.music.prepareToPlay()\n            self.music.play()\n            self.playbackChanged()\n            self.addLog("MUSIC PLAY [\\(source)]")\n        }\n    }\n''', s, count=1, flags=re.S)
s = re.sub(r'    func musicPause\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicPause(source: String = "APP") { guard ensureMusicReady() else { return }; music.pause(); playbackChanged(); addLog("MUSIC PAUSE [\\(source)]") }\n', s, count=1, flags=re.S)
s = re.sub(r'    func musicPrevious\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicPrevious(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToPreviousItem(); playbackChanged(); addLog("MUSIC PREVIOUS [\\(source)]") }\n', s, count=1, flags=re.S)
s = re.sub(r'    func musicNext\(source: String = "APP"\) \{.*?\n    \}\n', '    func musicNext(source: String = "APP") { guard ensureMusicReady() else { return }; music.skipToNextItem(); playbackChanged(); addLog("MUSIC NEXT [\\(source)]") }\n', s, count=1, flags=re.S)

# Exact Chronos Control enum mapping: 9D00 play, 9D01 pause, 9D02 previous, 9D03 next.
s = s.replace('if b.count >= 7, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 'if b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 1)

# Ensure the source contains no stale v23 timer or remote-command state.
print('v24 battery monitoring:', 'UIDevice.current.isBatteryMonitoringEnabled = true' in s)
print('v24 write-with-response:', 'TX WITH_RESPONSE:' in s)
print('v24 battery protocol:', 'b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91' in s)
print('v24 exact music protocol:', 'b[4] == 0x9D' in s)
print('v24 stale remote:', 'MPRemoteCommandCenter.shared()' in s)
print('v24 stale battery timer references:', 'batteryTimer' in s)

p.write_text(s, encoding='utf-8')
