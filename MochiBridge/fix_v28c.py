from pathlib import Path

# Apply the validated v28b changes first, then fix WRITE_NR queue draining so packets do not stall.
exec(Path('MochiBridge/fix_v28b.py').read_text(encoding='utf-8'), {'__name__': '__main__'})

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

old = '''    private func flushQueue() {
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
new = '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }

        // Chronos exposes RX as WRITE | WRITE_NR. Drain every packet that CoreBluetooth
        // currently accepts; when the peripheral becomes ready again, the delegate calls us.
        if c.properties.contains(.writeWithoutResponse) {
            guard p.canSendWriteWithoutResponse else { return }
            while !queue.isEmpty && p.canSendWriteWithoutResponse {
                let data = queue.removeFirst()
                addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
                p.writeValue(data, for: c, type: .withoutResponse)
            }
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
    raise SystemExit('v28c: queue block not found after v28b')
s = s.replace(old, new, 1)
s = s.replace('''        withoutResponseBusy = false
        addLog("BLE READY FOR TX")
        flushQueue()
''','''        addLog("BLE READY FOR TX")
        flushQueue()
''',1)
if 'while !queue.isEmpty && p.canSendWriteWithoutResponse' not in s:
    raise SystemExit('v28c validation failed')
p.write_text(s, encoding='utf-8')
print('V28C PATCH OK')
