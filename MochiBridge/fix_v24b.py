from pathlib import Path
import re
p=Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s=p.read_text(encoding='utf-8')
if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s=s.replace('        super.init()\n','        super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n',1)
s=re.sub(r'    private func flushQueue\(\) \{.*?\n    \}\n\n    func peripheral\(_ peripheral: CBPeripheral, didWriteValueFor', '''    private func flushQueue() {
        guard ready, let p = peripheral, let c = rx, p.state == .connected, !queue.isEmpty else { return }
        if !writing && c.properties.contains(.write) {
            let data = queue.removeFirst(); writing = true
            addLog("TX WITH_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withResponse)
        } else if c.properties.contains(.writeWithoutResponse) && p.canSendWriteWithoutResponse {
            let data = queue.removeFirst()
            addLog("TX WITHOUT_RESPONSE: \\(hex(data))")
            p.writeValue(data, for: c, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushQueue() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor''',s,count=1,flags=re.S)
s=re.sub(r'    private var withoutResponseBusy.*\n','',s)
s=s.replace('withoutResponseBusy = false; ','').replace('withoutResponseBusy = false\n','').replace('withoutResponseBusy = true\n','')
s=s.replace('        guard b.count >= 7, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }','        guard b.count == 7, b[0] == 0xAB, b[1] == 0x00, b[2] == 0x04, b[3] == 0xFE, b[4] == 0x91, b[5] == 0x80, b[6] == 0x01 else { return }',1)
s=s.replace('        addLog("RX: \\(hex(data))")','        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")',1)
# Do not rewrite the existing music methods; keep the source implementation intact.
checks=['UIDevice.current.isBatteryMonitoringEnabled = true','TX WITH_RESPONSE:','func musicPrevious(source: String = "APP")','func musicNext(source: String = "APP")']
for x in checks:
    if x not in s: raise SystemExit('v24 validation failed: '+x)
print('V24 PATCH OK')
p.write_text(s,encoding='utf-8')
