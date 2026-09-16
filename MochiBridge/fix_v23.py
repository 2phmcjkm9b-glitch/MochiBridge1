from pathlib import Path

p = Path('MochiBridge/MochiBridge/MochiBridgeApp.swift')
s = p.read_text(encoding='utf-8')

# Battery: iOS monitoring must be enabled, and battery data must be request/response.
if 'UIDevice.current.isBatteryMonitoringEnabled = true' not in s:
    s = s.replace('super.init()\n', 'super.init()\n        UIDevice.current.isBatteryMonitoringEnabled = true\n', 1)

# Remove the unsolicited 15-second battery timer introduced in build #22.
s = s.replace('    private var batteryTimer: Timer?\n', '')
s = s.replace('        batteryTimer?.invalidate()\n', '')
s = s.replace('        startSyncTimers()\n', '        startSyncTimer()\n')
s = s.replace('    private func startSyncTimers() {\n        syncTimer?.invalidate(); batteryTimer?.invalidate()\n        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendTime() }\n        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendBatterySnapshot(reason: "PERIODIC") }\n    }\n', '')

# Never send a battery packet just because the phone battery changed.
old = '''        if ready { sendBatterySnapshot(reason: "CHANGE") }\n'''
s = s.replace(old, '')

# Keep the actual request matcher strict: AB 00 .. FE 91 80 01.
old = '''        guard b.count >= 6, b[0] == 0xAB, b[3] == 0xFE || b[3] == 0xFF else { return }\n'''
if old in s:
    s = s.replace(old, '        guard b.count >= 6, b[0] == 0xAB else { return }\n')

# Improve BLE diagnostics: always log the characteristic UUID and full RX bytes.
s = s.replace('        addLog("RX: \\(hex(data))")\n', '        addLog("RX [\\(characteristic.uuid.uuidString)]: \\(hex(data))")\n')

# Add remote-command routing while retaining systemMusicPlayer for Apple Music control.
marker = '    // MARK: Music\n'
if marker in s and 'private let remote = MPRemoteCommandCenter.shared()' not in s:
    s = s.replace('    private let music = MPMusicPlayerController.systemMusicPlayer\n', '    private let music = MPMusicPlayerController.systemMusicPlayer\n    private let remote = MPRemoteCommandCenter.shared()\n', 1)
    s = s.replace('        music.beginGeneratingPlaybackNotifications()\n', '        music.beginGeneratingPlaybackNotifications()\n        setupRemoteCommands()\n', 1)
    insert = '''    private func setupRemoteCommands() {\n        remote.playCommand.isEnabled = true\n        remote.pauseCommand.isEnabled = true\n        remote.togglePlayPauseCommand.isEnabled = true\n        remote.nextTrackCommand.isEnabled = true\n        remote.previousTrackCommand.isEnabled = true\n        remote.playCommand.addTarget { [weak self] _ in self?.musicPlay(source: "REMOTE"); return .success }\n        remote.pauseCommand.addTarget { [weak self] _ in self?.musicPause(source: "REMOTE"); return .success }\n        remote.togglePlayPauseCommand.addTarget { [weak self] _ in self?.musicToggle(); return .success }\n        remote.nextTrackCommand.addTarget { [weak self] _ in self?.musicNext(source: "REMOTE"); return .success }\n        remote.previousTrackCommand.addTarget { [weak self] _ in self?.musicPrevious(source: "REMOTE"); return .success }\n    }\n\n'''
    s = s.replace(marker, marker + insert, 1)
    s = s.replace('        music.endGeneratingPlaybackNotifications()\n', '        music.endGeneratingPlaybackNotifications()\n        remote.playCommand.removeTarget(nil)\n        remote.pauseCommand.removeTarget(nil)\n        remote.togglePlayPauseCommand.removeTarget(nil)\n        remote.nextTrackCommand.removeTarget(nil)\n        remote.previousTrackCommand.removeTarget(nil)\n', 1)

# Use prepareToPlay before Play; this avoids a no-op on a cold system music player.
old = '    func musicPlay() { music.play(); playbackChanged(); addLog("MUSIC PLAY") }\n'
if old in s:
    s = s.replace(old, '''    func musicPlay(source: String = "APP") {\n        music.prepareToPlay { [weak self] error in\n            DispatchQueue.main.async {\n                guard let self else { return }\n                if let error { self.addLog("MUSIC PLAY ERROR: \\(error.localizedDescription)"); return }\n                self.music.play()\n                self.playbackChanged()\n                self.addLog("MUSIC PLAY [\\(source)]")\n            }\n        }\n    }\n''')
    s = s.replace('    func musicPause() { music.pause(); playbackChanged(); addLog("MUSIC PAUSE") }\n', '    func musicPause(source: String = "APP") { music.pause(); playbackChanged(); addLog("MUSIC PAUSE [\\(source)]") }\n')
    s = s.replace('    func musicPrevious() { music.skipToPreviousItem(); addLog("MUSIC PREVIOUS") }\n', '    func musicPrevious(source: String = "APP") { music.skipToPreviousItem(); playbackChanged(); addLog("MUSIC PREVIOUS [\\(source)]") }\n')
    s = s.replace('    func musicNext() { music.skipToNextItem(); addLog("MUSIC NEXT") }\n', '    func musicNext(source: String = "APP") { music.skipToNextItem(); playbackChanged(); addLog("MUSIC NEXT [\\(source)]") }\n')

# Build #22 already had these source-aware methods; make incoming 0x9D commands explicit if present.
s = s.replace('case 0x00: musicPlay()', 'case 0x00: musicPlay(source: "MOCHI")')
s = s.replace('case 0x01: musicPause()', 'case 0x01: musicPause(source: "MOCHI")')
s = s.replace('case 0x02: musicPrevious()', 'case 0x02: musicPrevious(source: "MOCHI")')
s = s.replace('case 0x03: musicNext()', 'case 0x03: musicNext(source: "MOCHI")')

p.write_text(s, encoding='utf-8')
print('Applied MochiBridge v23 build fixes')
print('battery monitoring:', 'UIDevice.current.isBatteryMonitoringEnabled = true' in s)
print('battery timer removed:', 'batteryTimer' not in s)
print('request matcher:', 'b[6] == 0x01' in s)
print('RX hex log:', 'RX [\\(characteristic.uuid.uuidString)]' in s)
print('remote commands:', 'setupRemoteCommands()' in s)
