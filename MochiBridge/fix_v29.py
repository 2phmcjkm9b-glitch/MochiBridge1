from pathlib import Path
import re

p = Path('MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

old_notify = '''        ready = true
        status = "Подключено"
        addLog("NOTIFY ON — BLE READY FOR TX/RX")
        sendTime()
        sendBatterySnapshot(reason: "CONNECT")
        startTimers()
'''
new_notify = '''        ready = true
        status = "Подключено"
        addLog("NOTIFY ON — BLE READY FOR TX/RX")
        sendTime()
        // ChronosESP32 waits a few seconds after connection before requesting phone info.
        // Give Mochi the same settling time, then send a battery snapshot proactively.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.ready else { return }
            self.sendBatterySnapshot(reason: "CONNECT_DELAYED")
        }
        startTimers()
'''
if old_notify not in s:
    raise SystemExit('notify block not found')
s = s.replace(old_notify, new_notify, 1)

old_parser = '''        // ChronosESP32: AB 00 04 FF 9D 80 <command> = music control.
        if b.count >= 7 && b[3] == 0xFF && b[4] == 0x9D && b[5] == 0x80 {
            switch b[6] {
            case 0x00: musicPlay(source: "MOCHI")
            case 0x01: musicPause(source: "MOCHI")
            case 0x02: musicPrevious(source: "MOCHI")
            case 0x03: musicNext(source: "MOCHI")
            default: addLog("MUSIC UNKNOWN=\\(String(format: "%02X", b[6]))")
            }
        }
'''
new_parser = '''        // ChronosESP32 watch -> phone music control is AB 00 04 FF 9D 80 <command>.
        // Accept FE as well for compatibility with firmware variants, but log the framing.
        if b.count >= 7 && (b[3] == 0xFF || b[3] == 0xFE) && b[4] == 0x9D && b[5] == 0x80 {
            addLog("MUSIC RX command=\\(String(format: "%02X", b[6])) frame=\\(String(format: "%02X", b[3]))")
            switch b[6] {
            case 0x00: musicPlay(source: "MOCHI")
            case 0x01: musicPause(source: "MOCHI")
            case 0x02: musicPrevious(source: "MOCHI")
            case 0x03: musicNext(source: "MOCHI")
            default: addLog("MUSIC UNKNOWN=\\(String(format: "%02X", b[6]))")
            }
        }
'''
if old_parser not in s:
    raise SystemExit('music parser block not found')
s = s.replace(old_parser, new_parser, 1)

start = s.index('    private func flushQueue(')
end = s.index('\n    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic:', start)
new_flush = '''    private func flushQueue(_ p: CBPeripheral? = nil, _ c: CBCharacteristic? = nil) {
        guard ready, let peripheral = p ?? self.peripheral, let characteristic = c ?? rx,
              peripheral.state == .connected, !queue.isEmpty else { return }

        // Mochi's RX characteristic exposes both WRITE and WRITE_WITHOUT_RESPONSE.
        // Prefer WRITE WITH RESPONSE on iOS: it gives us a real delivery acknowledgement.
        if characteristic.properties.contains(.write) {
            guard !writing else { return }
            let data = queue.removeFirst()
            writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            return
        }

        guard characteristic.properties.contains(.writeWithoutResponse) else {
            addLog("TX ERROR: RX has no supported write mode")
            return
        }
        guard peripheral.canSendWriteWithoutResponse else { return }
        while !queue.isEmpty && peripheral.canSendWriteWithoutResponse {
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }
'''
s = s[:start] + new_flush + s[end:]

old_write = '''    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxUUID else { return }
        writing = false
        addLog(error == nil ? "TX OK" : "TX ERROR: \\(error!.localizedDescription)")
        flushQueue()
    }
'''
new_write = '''    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxUUID else { return }
        writing = false
        if let error {
            addLog("TX ERROR: \\(error.localizedDescription)")
        } else {
            addLog("TX OK [WITH_RESPONSE]")
        }
        flushQueue()
    }
'''
if old_write not in s:
    raise SystemExit('didWrite block not found')
s = s.replace(old_write, new_write, 1)

# Add explicit logging/response when the watch sends its own 0x91 status packet.
needle = '''        if b.count == 7 && b == [0xAB,0x00,0x04,0xFE,0x91,0x80,0x01] {
            addLog("BATTERY REQUEST FROM MOCHI")
            sendBatterySnapshot(reason: "REQUEST")
            return
        }
'''
replacement = '''        if b.count == 7 && b == [0xAB,0x00,0x04,0xFE,0x91,0x80,0x01] {
            addLog("BATTERY REQUEST FROM MOCHI")
            sendBatterySnapshot(reason: "REQUEST")
            return
        }

        // FF 91 from the watch is its own battery/status notification. It is not a phone-battery request.
        if b.count >= 8 && b[3] == 0xFF && b[4] == 0x91 && b[5] == 0x80 {
            addLog("MOCHI BATTERY RX: \\(b[7])% state=\\(b[6])")
            // The watch is alive and has accepted the BLE link. Send the phone battery now as well.
            sendBatterySnapshot(reason: "AFTER_MOCHI_STATUS")
        }
'''
if needle not in s:
    raise SystemExit('battery request block not found')
s = s.replace(needle, replacement, 1)

p.write_text(s, encoding='utf-8')
print('v29 protocol patch applied')
