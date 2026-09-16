from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# iOS battery monitoring must be enabled before reading batteryLevel/state.
if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('        super.init()\n', '        super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# --- BLE TX: prefer the mode that is actually supported by the Chronos RX characteristic.
# The original ChronosESP32 creates RX as WRITE | WRITE_NR. Prefer WRITE_NR because it
# matches the proven LightBlue/manual path and does not depend on didWriteValueFor timing.
new_flush = '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if c.properties.contains(.writeWithoutResponse) {
            guard p.canSendWriteWithoutResponse else { return }
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushQueue() }
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
s = re.sub(r'    private func flushQueue\(\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didWriteValueFor', new_flush + '\n    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor', s, count=1, flags=re.S)

# Do not keep the obsolete write-without-response busy flag from older versions.
s = re.sub(r'    private var withoutResponseBusy.*\n', '', s)
s = s.replace('withoutResponseBusy = false; ', '')
s = s.replace('withoutResponseBusy = false\n', '')
s = s.replace('withoutResponseBusy = true\n', '')

# Log the actual notification characteristic and only declare BLE ready after notifications are enabled.
s = s.replace('        ready = true; status = "Подключено"\n        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"\n        addLog("BLE READY RX=\\(r.properties.rawValue) MODE=\\(mode) TX=\\(tx != nil ? "OK" : "нет")")\n        sendTime()\n        sendBatterySnapshot(reason: "CONNECT")\n        startSyncTimers()\n', '''        let mode = r.properties.contains(.writeWithoutResponse) ? "WITHOUT_RESPONSE" : "WITH_RESPONSE"
        addLog("BLE CHARACTERISTICS RX=\\(r.properties.rawValue) MODE=\\(mode) TX=\\(tx != nil ? "OK" : "нет")")
        if tx == nil {
            addLog("BLE ERROR: TX notify characteristic missing")
        }
''')

# Replace notify callback so initial sync starts only after the TX notification subscription succeeds.
s = re.sub(r'    func peripheral\(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error\?\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didUpdateValueFor', '''    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            ready = false
            addLog("NOTIFY ERROR: \\(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            ready = true
            status = "Подключено"
            addLog("NOTIFY ON — BLE READY FOR TX/RX")
            sendTime()
            sendBatterySnapshot(reason: "CONNECT")
            startSyncTimers()
        } else {
            ready = false
            addLog("NOTIFY OFF")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor''', s, count=1, flags=re.S)

# RX logging and command handling: accept the exact Chronos phone-control packet and also
# tolerate FE/FF framing variants while debugging.
s = s.replace('        addLog("RX: \\(hex(data))")', '        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")', 1)

# Battery request is exactly AB 00 04 FE 91 80 01.
s = re.sub(r'        guard b.count >= 7, b\[3\] == 0xFE, b\[4\] == 0x91, b\[5\] == 0x80, b\[6\] == 0x01 else \{ return \}', '        guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }', s, count=1)

# ChronosESP32 source confirms watch->phone music packets are FF 9D 80 <command>.
# Keep a FE variant too so the diagnostic bridge is tolerant of firmware variants.
s = s.replace('if b.count >= 7, b[3] == 0xFF, b[4] == 0x9D, b[5] == 0x80 {', 'if b.count >= 7, (b[3] == 0xFF || b[3] == 0xFE), b[4] == 0x9D, b[5] == 0x80 {', 1)

# Phone battery should be sent periodically because the Chronos library itself sends its
# own battery on connect/change; the phone app historically also sends its snapshot.
# Keep a modest 15 s period, but always refresh the raw iOS value immediately before encoding.
s = re.sub(r'    private func startSyncTimers\(\) \{.*?\n    \}\n\n    // MARK: Time', '''    private func startSyncTimers() {
        syncTimer?.invalidate(); batteryTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendTime() }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }
    }

    // MARK: Time''', s, count=1, flags=re.S)

# Add a diagnostic log with the raw iOS battery value immediately before sending.
s = s.replace('        let level = UInt8(max(0, min(100, battery)))\n', '        let raw = UIDevice.current.batteryLevel\n        let fresh = raw >= 0 ? max(0, min(100, Int(round(raw * 100)))) : battery\n        battery = fresh\n        let level = UInt8(max(0, min(100, fresh)))\n        addLog("BATTERY RAW=\\(raw) LEVEL=\\(level)% STATE=\\(UIDevice.current.batteryState.rawValue)")\n', 1)

# Music: keep Apple Music/system player implementation. The BLE 0x9D handler is the bridge;
# do not pretend MPRemoteCommandCenter can send commands to arbitrary third-party players.
checks = [
    'UIDevice.current.isBatteryMonitoringEnabled = true',
    'TX WITHOUT_RESPONSE:',
    'NOTIFY ON — BLE READY FOR TX/RX',
    'BATTERY REQUEST FROM MOCHI',
    'BATTERY RAW=',
    'case 0x03: musicNext(source: "MOCHI")'
]
for item in checks:
    if item not in s:
        raise SystemExit('V25 validation failed: ' + item)

p.write_text(s, encoding='utf-8')
print('V25 PATCH OK')
