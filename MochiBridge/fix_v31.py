from pathlib import Path
import re

# Apply the known-good v29 protocol changes, then v30 diagnostics.
exec(Path('fix_v30.py').read_text(encoding='utf-8'), {'__name__': '__main__'})

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# v31: make music RX parsing accept both known Chronos framings and log the raw frame.
old = '''        if b.count >= 7 && b[3] == 0xFF && b[4] == 0x9D && b[5] == 0x80 {\n            switch b[6] {'''
new = '''        if b.count >= 7 && (b[3] == 0xFF || b[3] == 0xFE) && b[4] == 0x9D && b[5] == 0x80 {\n            addLog("MUSIC RX command=\\(String(format: \"%02X\", b[6])) frame=\\(String(format: \"%02X\", b[3]))")\n            switch b[6] {'''
if old in s:
    s = s.replace(old, new, 1)

# v31: make the app's manual music controls explicit in the log; these are local Apple Music
# controls and are deliberately separate from Mochi-originated BLE 0x9D commands.
s = s.replace('''    func musicToggle() { music.playbackState == .playing ? musicPause() : musicPlay() }\n''','''    func musicToggle() {\n        addLog("MUSIC APP TOGGLE")\n        music.playbackState == .playing ? musicPause() : musicPlay()\n    }\n''',1)

# v31: add a deterministic BLE diagnostic button action for each Chronos music command.
marker = '''    func musicNext(source: String = "APP") { music.skipToNextItem(); addLog("MUSIC NEXT [\\(source)]") }\n'''
insert = marker + '''\n    // Chronos watch/phone music command frame. These are available for diagnostics and future Mochi-side controls.\n    func sendMusicCommand(_ command: UInt8) {\n        let packet: [UInt8] = [0xAB, 0x00, 0x04, 0xFF, 0x9D, 0x80, command]\n        addLog("MUSIC TX command=\\(String(format: \"%02X\", command)): \\(hex(Data(packet)))")\n        enqueue(packet, label: "MUSIC")\n    }\n'''
if marker in s and 'func sendMusicCommand' not in s:
    s = s.replace(marker, insert, 1)

p.write_text(s, encoding='utf-8')
print('V31 PATCH OK')
