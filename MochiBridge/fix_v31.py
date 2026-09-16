from pathlib import Path

# Apply the validated v30 protocol changes, then v31 diagnostics.
exec(Path('fix_v30.py').read_text(encoding='utf-8'), {'__name__': '__main__'})

p = Path('MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

old = '''        if b.count >= 7 && b[3] == 0xFF && b[4] == 0x9D && b[5] == 0x80 {\n            switch b[6] {'''
new = '''        if b.count >= 7 && (b[3] == 0xFF || b[3] == 0xFE) && b[4] == 0x9D && b[5] == 0x80 {\n            addLog("MUSIC RX command=\\(String(format: \"%02X\", b[6])) frame=\\(String(format: \"%02X\", b[3]))")\n            switch b[6] {'''
if old in s:
    s = s.replace(old, new, 1)

marker = '''    func musicNext(source: String = "APP") { music.skipToNextItem(); addLog("MUSIC NEXT [\\(source)]") }\n'''
insert = marker + '''\n    // Chronos music command frame, retained as a protocol diagnostic helper.\n    func sendMusicCommand(_ command: UInt8) {\n        let packet: [UInt8] = [0xAB, 0x00, 0x04, 0xFF, 0x9D, 0x80, command]\n        addLog("MUSIC TX command=\\(String(format: \"%02X\", command)): \\(hex(Data(packet)))")\n        enqueue(packet, label: "MUSIC")\n    }\n'''
if marker in s and 'func sendMusicCommand' not in s:
    s = s.replace(marker, insert, 1)

p.write_text(s, encoding='utf-8')
print('V31 PATCH OK')
