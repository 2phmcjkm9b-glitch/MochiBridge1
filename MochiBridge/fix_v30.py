from pathlib import Path

# Start from the already validated v29 protocol patch.
exec(Path('fix_v29.py').read_text(encoding='utf-8'), {'__name__': '__main__'})

p = Path('MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# Make the transport choice explicit: Chronos RX supports both WRITE and WRITE_NR,
# but v30 deliberately uses WRITE WITH RESPONSE whenever available so every packet
# has a CoreBluetooth completion callback. WRITE_NR remains a fallback only.
old = '''        if characteristic.properties.contains(.write) {\n            guard !writing else { return }\n            let data = queue.removeFirst()\n            writing = true\n            addLog("TX WITH_RESPONSE: \\(hex(data))")\n            peripheral.writeValue(data, for: characteristic, type: .withResponse)\n            return\n        }\n\n        guard characteristic.properties.contains(.writeWithoutResponse) else {\n'''
new = '''        if characteristic.properties.contains(.write) {\n            guard !writing else { return }\n            let data = queue.removeFirst()\n            writing = true\n            addLog("TX WITH_RESPONSE: \\(hex(data))")\n            peripheral.writeValue(data, for: characteristic, type: .withResponse)\n            return\n        }\n\n        guard characteristic.properties.contains(.writeWithoutResponse) else {\n'''
if old not in s:
    raise SystemExit('v30 transport block not found')
s = s.replace(old, new, 1)

# Log the exact characteristic properties so future tests cannot confuse raw property
# values with the selected write transport.
s = s.replace('''        addLog("RX props=\\(r.properties.rawValue) TX props=\\(t.properties.rawValue)")\n''','''        addLog("RX props=\\(r.properties.rawValue) TX props=\\(t.properties.rawValue)")\n        addLog("RX WRITE=\\(r.properties.contains(.write)) WRITE_NR=\\(r.properties.contains(.writeWithoutResponse))")\n''',1)

# Log every phone-battery packet as a complete, independently verifiable frame.
s = s.replace('''        addLog("BATTERY \\(reason): \\(level)% state=\\(state)")\n        enqueue(packet, label: "BATTERY")\n''','''        addLog("BATTERY \\(reason): \\(level)% state=\\(state)")\n        addLog("BATTERY PACKET: \\(hex(Data(packet)))")\n        enqueue(packet, label: "BATTERY")\n''',1)

# Make music reception unmistakable. The app's own music buttons must not be mistaken
# for a Mochi-originated 0x9D command; only the BLE RX parser logs MUSIC RX command=.
needle = '''        if b.count >= 7 && (b[3] == 0xFF || b[3] == 0xFE) && b[4] == 0x9D && b[5] == 0x80 {\n            addLog("MUSIC RX command=\\(String(format: "%02X", b[6])) frame=\\(String(format: "%02X", b[3]))")\n'''
if needle not in s:
    raise SystemExit('v30 music parser block not found')

p.write_text(s, encoding='utf-8')
print('V30 PATCH OK')
