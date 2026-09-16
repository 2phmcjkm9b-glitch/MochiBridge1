from pathlib import Path
import re

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# Battery monitoring must be enabled before reading UIDevice batteryLevel.
if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('super.init()\n', 'super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# Battery is request/response; remove the old unsolicited 15-second timer completely.
s = s.replace('    private var batteryTimer: Timer?\n', '')
s = s.replace('        batteryTimer?.invalidate()\n', '')
s = s.replace('        batteryTimer?.invalidate();', '')
s = s.replace('        startSyncTimers()\n', '        startTimeSyncTimer()\n')
s = s.replace('        startSyncTimer()\n', '        startTimeSyncTimer()\n')
s = re.sub(r'    private func startSyncTimers\(\) \{.*?\n    \}\n', '''    private func startTimeSyncTimer() {\n        syncTimer?.invalidate()\n        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in\n            self?.sendTime()\n        }\n    }\n''', s, count=1, flags=re.S)

# Do not send battery packets merely because the phone battery changed.
s = s.replace('        if ready { sendBatterySnapshot(reason: "CHANGE") }\n', '')

# Keep incoming packet validation strict enough to avoid treating unrelated BLE data as commands.
old = '        guard b.count >= 6, b[0] == 0xAB, b[3] == 0xFE || b[3] == 0xFF else { return }\n'
s = s.replace(old, '        guard b.count >= 6, b[0] == 0xAB else { return }\n')

# Full RX diagnostics including characteristic UUID.
s = s.replace('        addLog("RX: \\(hex(data))")\n', '        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")\n')

# Add iOS remote-command routing once.
if 'private let remote = MPRemoteCommandCenter.shared()' not in s:
    s = s.replace('    private let music = MPMusicPlayerController.systemMusicPlayer\n', '    private let music = MPMusicPlayerController.systemMusicPlayer\n    private let remote = MPRemoteCommandCenter.shared()\n', 1)
if '        setupRemoteCommands()\n' not in s:
    s = s.replace('        music.beginGeneratingPlaybackNotifications()\n', '        music.beginGeneratingPlaybackNotifications()\n        setupRemoteCommands()\n', 1)

# Install remote command handlers if the source does not already contain them.
if 'private func setupRemoteCommands()' not in s:
    marker = '    // MARK: Music\n'
    insert = '''    private func setupRemoteCommands() {\n        remote.playCommand.isEnabled = true\n        remote.pauseCommand.isEnabled = true\n        remote.togglePlayPauseCommand.isEnabled = true\n        remote.nextTrackCommand.isEnabled = true\n        remote.previousTrackCommand.isEnabled = true\n        remote.playCommand.addTarget { [weak self] _ in self?.musicPlay(source: "REMOTE"); return .success }\n        remote.pauseCommand.addTarget { [weak self] _ in self?.musicPause(source: "REMOTE"); return .success }\n        remote.togglePlayPauseCommand.addTarget { [weak self] _ in self?.musicToggle(); return .success }\n        remote.nextTrackCommand.addTarget { [weak self] _ in self?.musicNext(source: "REMOTE"); return .success }\n        remote.previousTrackCommand.addTarget { [weak self] _ in self?.musicPrevious(source: "REMOTE"); return .success }\n    }\n\n'''
    s = s.replace(marker, marker + insert, 1)

# Clean remote handlers on teardown.
if 'remote.playCommand.removeTarget(nil)' not in s:
    s = s.replace('        music.endGeneratingPlaybackNotifications()\n', '        music.endGeneratingPlaybackNotifications()\n        remote.playCommand.removeTarget(nil)\n        remote.pauseCommand.removeTarget(nil)\n        remote.togglePlayPauseCommand.removeTarget(nil)\n        remote.nextTrackCommand.removeTarget(nil)\n        remote.previousTrackCommand.removeTarget(nil)\n', 1)

# Explicit source-aware music methods, while retaining systemMusicPlayer as the playback engine.
old_play = '    func musicPlay() { music.play(); playbackChanged(); addLog("MUSIC PLAY") }\n'
if old_play in s:
    s = s.replace(old_play, '''    func musicPlay(source: String = "APP") {\n        music.prepareToPlay { [weak self] error in\n            DispatchQueue.main.async {\n                guard let self else { return }\n                if let error { self.addLog("MUSIC PLAY ERROR: \\(error.localizedDescription)"); return }\n                self.music.play()\n                self.playbackChanged()\n                self.addLog("MUSIC PLAY [\\(source)]")\n            }\n        }\n    }\n''')
s = s.replace('    func musicPause() { music.pause(); playbackChanged(); addLog("MUSIC PAUSE") }\n', '    func musicPause(source: String = "APP") { music.pause(); playbackChanged(); addLog("MUSIC PAUSE [\\(source)]") }\n')
s = s.replace('    func musicPrevious() { music.skipToPreviousItem(); addLog("MUSIC PREVIOUS") }\n', '    func musicPrevious(source: String = "APP") { music.skipToPreviousItem(); playbackChanged(); addLog("MUSIC PREVIOUS [\\(source)]") }\n')
s = s.replace('    func musicNext() { music.skipToNextItem(); addLog("MUSIC NEXT") }\n', '    func musicNext(source: String = "APP") { music.skipToNextItem(); playbackChanged(); addLog("MUSIC NEXT [\\(source)]") }\n')

# Incoming 0x9D music commands should call the source-aware methods.
s = s.replace('case 0x00: musicPlay()', 'case 0x00: musicPlay(source: "MOCHI")')
s = s.replace('case 0x01: musicPause()', 'case 0x01: musicPause(source: "MOCHI")')
s = s.replace('case 0x02: musicPrevious()', 'case 0x02: musicPrevious(source: "MOCHI")')
s = s.replace('case 0x03: musicNext()', 'case 0x03: musicNext(source: "MOCHI")')

p.write_text(s, encoding='utf-8')

print('Applied MochiBridge v23 build fixes')
print('battery monitoring:', 'UIDevice.current.isBatteryMonitoringEnabled = true' in s)
print('battery timer removed:', 'batteryTimer' not in s)
print('time sync timer:', 'startTimeSyncTimer' in s)
print('request matcher:', 'b[6] == 0x01' in s)
print('RX hex log:', 'RX [\\(characteristic.uuid.uuidString)]' in s)
print('remote commands:', 'setupRemoteCommands()' in s)
