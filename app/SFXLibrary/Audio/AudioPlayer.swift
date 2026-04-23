import Foundation
import AVFoundation
import CoreAudio
import Combine

// MARK: - SFXAudioLog

/// Writes [SFXAudio] diagnostic lines to console and to a per-session log file.
/// Call SFXAudioLog.configure(directory:) once at startup.
/// Each launch creates a new timestamped file; the oldest are pruned to keep ≤ maxFiles.
enum SFXAudioLog {
    private static var logURL: URL? = nil
    private static let maxFiles = 10
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func configure(directory: URL) {
        let logsDir = directory.appendingPathComponent("Debug Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "sfxaudio_\(stamp).log"
        let url = logsDir.appendingPathComponent(filename)
        logURL = url
        // Create the file immediately so it shows up even if no lines are written.
        try? "".write(to: url, atomically: false, encoding: .utf8)
        pruneOldLogs(in: logsDir)
        write("[SFXAudio] SESSION \(stamp)")
    }

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        guard let url = logURL else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        }
    }

    private static func pruneOldLogs(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles)
        else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("sfxaudio_") && $0.pathExtension == "log" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d1 < d2
            }
        let excess = logs.count - maxFiles
        guard excess > 0 else { return }
        for old in logs.prefix(excess) { try? fm.removeItem(at: old) }
    }
}

// C-convention callback for kAudioDeviceProcessorOverload — fires on the audio thread.
// Dispatches to main before touching AudioPlayer state or writing to the log file.
private let _overloadCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let ptr = clientData else { return noErr }
    DispatchQueue.main.async {
        Unmanaged<AudioPlayer>.fromOpaque(ptr).takeUnretainedValue().handleHALOverload()
    }
    return noErr
}

final class AudioPlayer: ObservableObject {
    @Published var isPlaying:    Bool   = false
    @Published var playPosition: Double = 0   // 0.0 – 1.0
    @Published var duration:     Double = 0
    @Published var volume: Float = (UserDefaults.standard.object(forKey: "playerVolume") as? Float) ?? 1.0 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    /// Current waveform selection as fractions of total duration. nil = no selection.
    @Published var selectionStart: Double? = nil
    @Published var selectionEnd:   Double? = nil

    /// When true and a selection is active, playback loops the selection.
    @Published var loopEnabled: Bool = UserDefaults.standard.bool(forKey: "loopEnabled") {
        didSet { UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled") }
    }

    /// UID of the currently active CoreAudio output device. Empty string = system default.
    @Published var currentOutputDeviceUID: String = ""

    /// Sample rate the engine's output node is actually running at (hardware rate).
    @Published var outputSampleRate: Double = 0

    private var engine     = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var configChangeObserver: (any NSObjectProtocol)?
    private var audioFile:  AVAudioFile?
    private var timer:      AnyCancellable?
    private var currentURL: URL?

    // Frame we last scheduled from — added to sampleTime for real position.
    private var seekFrame: AVAudioFramePosition = 0

    // Incremented each schedule call; lets completion callbacks self-invalidate.
    private var scheduleGeneration = 0

    // Counts AVAudioEngineConfigurationChange notifications this session.
    private var configChangeCount = 0
    // Counts timer ticks skipped because the engine wasn't running.
    private var timerSkipCount = 0
    // Counts HAL processor overloads (kAudioDeviceProcessorOverload).
    private var halOverloadCount = 0
    // Device ID we currently have the overload listener registered on.
    private var overloadListenerDeviceID: AudioDeviceID = AudioDeviceID(kAudioDeviceUnknown)
    // Timestamp of the most recent successful engine start, used to identify
    // spurious startup config changes and suppress them without a rebuild.
    private var lastEngineStartTime: Date = .distantPast
    // Counts how many consecutive startup-transient restarts have occurred.
    // Caps at 3 to prevent an infinite restart loop if something is truly wrong.
    private var consecutiveTransientRestarts = 0

    // Debounces AVAudioEngineConfigurationChange — rapid-fire notifications
    // (e.g. Bluetooth glitching, PT Aux I/O reconfiguring) only trigger one restart.
    private var configChangeWork: DispatchWorkItem?
    // Preserved across debounce cancellations so rapid-fire notifications don't
    // lose the intent to resume (the second notification sees isPlaying == false
    // because the first already stopped the node).
    private var configChangeShouldResume:  Bool   = false
    private var configChangeResumePosition: Double = 0

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        // Restore saved output device before starting the engine so we only start once.
        if let savedUID = UserDefaults.standard.string(forKey: "outputDeviceUID"),
           !savedUID.isEmpty,
           let deviceID = AudioDeviceManager.deviceID(forUID: savedUID) {
            applyOutputDeviceID(deviceID)
            currentOutputDeviceUID = savedUID
        }

        startEngine()
        engine.mainMixerNode.outputVolume = volume
        addConfigChangeObserver()
    }

    /// Restarts the engine if it has stopped without recreating it.
    /// Use for routine recovery (e.g. engine idled); forceReconnect for post-spot cleanup.
    func recoverEngineIfNeeded() {
        guard !engine.isRunning else { return }
        startEngine()
        engine.mainMixerNode.outputVolume = volume
    }

    /// Fully recreates the AVAudioEngine after a spot operation.
    /// The entire engine (including mainMixerNode → outputNode SRC chain) is
    /// replaced so no dirty state from the PT round-trip survives.
    func forceReconnect() {
        SFXAudioLog.write("[SFXAudio] RECONNECT  forced (post-spot)")
        rebuildEngine()
        refreshCurrentFile()
    }

    // MARK: - Output device

    /// Switches audio output to the device identified by `uid`.
    /// Pass an empty string to revert to the system default.
    func setOutputDevice(uid: String) {
        if !uid.isEmpty, AudioDeviceManager.deviceID(forUID: uid) == nil { return }
        if isPlaying { stop() }
        currentOutputDeviceUID = uid
        UserDefaults.standard.set(uid.isEmpty ? nil : uid, forKey: "outputDeviceUID")
        // rebuildEngine recreates the engine and re-applies currentOutputDeviceUID.
        rebuildEngine()
    }

    // MARK: - Load

    func load(url: URL, resetVolume: Bool = false) {
        guard url != currentURL else { return }
        stop()
        currentURL    = url
        selectionStart = nil
        selectionEnd   = nil
        if resetVolume { volume = 1.0 }
        do {
            audioFile    = try AVAudioFile(forReading: url)
            duration     = Double(audioFile!.length) / audioFile!.processingFormat.sampleRate
            playPosition = 0
            seekFrame    = 0
            let fileSR   = audioFile!.fileFormat.sampleRate
            let fileCh   = audioFile!.fileFormat.channelCount
            let hwSR     = outputSampleRate
            let mismatch = fileSR != hwSR ? " ⚠️ RATE MISMATCH" : ""
            SFXAudioLog.write(String(format: "[SFXAudio] LOAD   %@ | file: %.0fHz %dch | hw: %.0fHz | %.2fs%@",
                         url.lastPathComponent, fileSR, fileCh, hwSR, duration, mismatch))
        } catch {
            SFXAudioLog.write("[SFXAudio] LOAD ERROR: \(error)")
        }
    }

    // MARK: - Playback

    /// Plays from the current position, or from the active selection if one exists.
    func play() {
        guard let file = audioFile else { return }

        // The HAL disturbance from a graph rebuild can stop the engine ~200ms
        // after startEngine() returns, before the user has a chance to press play.
        // Silently restart it here rather than letting playback silently fail.
        recoverEngineIfNeeded()

        let fileSR = file.fileFormat.sampleRate
        let hwSR   = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rateTag = fileSR == hwSR
            ? String(format: "%.0fHz ok", fileSR)
            : String(format: "%.0f→%.0fHz CONVERTING", fileSR, hwSR)
        SFXAudioLog.write(String(format: "[SFXAudio] PLAY   pos=%.3f | %@ | engine.isRunning=%@",
                     playPosition, rateTag, engine.isRunning ? "true" : "false ⚠️"))

        // Stop and clear any pending/idle state so playerTime.sampleTime resets
        // to 0. Without this, sampleTime keeps incrementing while the node idles
        // after a segment finishes, making seekFrame + sampleTime wildly wrong.
        scheduleGeneration += 1
        playerNode.stop()

        if let start = selectionStart, let end = selectionEnd, end > start {
            let startFrame = AVAudioFramePosition(start * Double(file.length))
            let endFrame   = AVAudioFramePosition(end   * Double(file.length))
            playPosition   = start
            scheduleSegment(from: startFrame, to: endFrame)
        } else {
            let frame = AVAudioFramePosition(playPosition * Double(file.length))
            scheduleSegment(from: frame, to: nil)
        }
        playerNode.play()
        isPlaying = true
        startPositionTimer()
    }

    func stop() {
        scheduleGeneration += 1
        playerNode.stop()
        isPlaying = false
        timer?.cancel()
        seekFrame = 0
        // Reset playhead to selection start so next play begins at the right place.
        if let start = selectionStart {
            playPosition = start
        }
    }

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    // MARK: - Scrubbing

    /// Seeks to a fractional position. When playing, restarts from that point
    /// (ignores selection — use play() to respect selection).
    func seek(to fraction: Double) {
        guard let file = audioFile else { return }
        let clamped  = min(max(fraction, 0), 1)
        playPosition = clamped
        if isPlaying {
            let frame = AVAudioFramePosition(clamped * Double(file.length))
            SFXAudioLog.write(String(format: "[SFXAudio] SEEK   pos=%.3f frame=%lld / %lld",
                         clamped, frame, file.length))
            scheduleGeneration += 1
            playerNode.stop()
            scheduleSegment(from: frame, to: nil)   // seek ignores selection / looping
            playerNode.play()
        }
    }

    // MARK: - Private

    /// Re-opens the current file after a graph reconnect so the player node
    /// gets a fresh AVAudioFile handle. Without this, stale file state fed into
    /// the rebuilt graph can leave the SRC dirty, causing persistent glitches.
    private func refreshCurrentFile() {
        guard let url = currentURL else { return }
        seekFrame = 0
        do {
            audioFile = try AVAudioFile(forReading: url)
            SFXAudioLog.write("[SFXAudio] FILE   refreshed after reconnect")
        } catch {
            SFXAudioLog.write("[SFXAudio] FILE   refresh error: \(error)")
        }
    }

    /// Recreates the engine, starts it, and immediately registers the config change observer.
    /// AVAudioEngine fires a spurious AVAudioEngineConfigurationChange ~150ms after
    /// startEngine() (HAL disturbance from the restart). The observer handles this as a
    /// startup transient — it simply restarts the engine rather than triggering another
    /// full rebuild, breaking the infinite rebuild loop that the old 500ms delay was
    /// designed to prevent.
    private func rebuildEngine() {
        consecutiveTransientRestarts = 0
        reconnectGraph()
        startEngine()
        engine.mainMixerNode.outputVolume = volume
        addConfigChangeObserver()
    }

    /// Replaces the AVAudioEngine and playerNode. Does NOT start the engine or
    /// register the config change observer — call rebuildEngine() instead.
    private func reconnectGraph() {
        SFXAudioLog.write("[SFXAudio] GRAPH  reconnecting")
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        engine.stop()
        engine     = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        if !currentOutputDeviceUID.isEmpty,
           let deviceID = AudioDeviceManager.deviceID(forUID: currentOutputDeviceUID) {
            applyOutputDeviceID(deviceID)
        }
    }

    /// Registers the AVAudioEngineConfigurationChange observer on the current engine.
    /// Must be called after every engine recreation and once at init.
    private func addConfigChangeObserver() {
        // macOS stops AVAudioEngine whenever it reconfigures the audio graph —
        // device enumeration at launch, Pro Tools changing the session sample rate, etc.
        // Save playback state and auto-resume after reconnecting so the user hears
        // only a brief dropout rather than audio stopping entirely.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // AVAudioEngine fires a spurious config-change notification ~150ms after
            // startEngine() due to HAL negotiation, then stops itself. No real format
            // change has occurred — just restart the engine and return. Cap at 3
            // consecutive transient restarts to prevent an infinite loop if something
            // is genuinely wrong.
            if Date().timeIntervalSince(self.lastEngineStartTime) < 0.3 {
                self.consecutiveTransientRestarts += 1
                SFXAudioLog.write("[SFXAudio] CONFIG CHANGE  startup transient #\(self.consecutiveTransientRestarts) — restarting engine")
                if self.consecutiveTransientRestarts <= 3 {
                    // Re-apply the selected output device before restarting — the config
                    // change may have reset the audio unit's device property, which would
                    // cause startEngine() to register the overload listener on the wrong
                    // device (system default instead of e.g. Fireface UCX).
                    if !self.currentOutputDeviceUID.isEmpty,
                       let deviceID = AudioDeviceManager.deviceID(forUID: self.currentOutputDeviceUID) {
                        self.applyOutputDeviceID(deviceID)
                    }
                    self.startEngine()
                    self.engine.mainMixerNode.outputVolume = self.volume
                    return
                }
                // Too many consecutive transients — fall through to full rebuild.
                self.consecutiveTransientRestarts = 0
            }

            self.configChangeCount += 1
            SFXAudioLog.write(String(format: "[SFXAudio] CONFIG CHANGE #%d | wasPlaying=%@ | rate=%.0fHz | debounce %@",
                         self.configChangeCount,
                         self.isPlaying ? "true" : "false",
                         self.outputSampleRate,
                         self.configChangeWork != nil ? "reset" : "started"))
            // Only update the resume target when we're actually playing — a second
            // notification would see isPlaying==false (we already stopped) and lose
            // the intent to resume. configChangeShouldResume persists until consumed.
            if self.isPlaying {
                self.configChangeShouldResume   = true
                self.configChangeResumePosition = self.playPosition
                self.scheduleGeneration += 1
                self.playerNode.stop()
                self.isPlaying = false
                self.timer?.cancel()
                self.seekFrame = 0
            }
            // Debounce: cancel any pending restart so rapid-fire notifications
            // (Bluetooth glitching, PT Aux I/O reconfiguring) only trigger one restart.
            self.configChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldResume = self.configChangeShouldResume
                let resumePos    = self.configChangeResumePosition
                self.configChangeShouldResume = false
                self.rebuildEngine()
                self.refreshCurrentFile()
                if shouldResume {
                    self.playPosition = resumePos
                    self.play()
                }
            }
            self.configChangeWork = work
            // Short delay lets the triggering app (e.g. Pro Tools) finish its own
            // reconfiguration before we try to reclaim the device.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Starts the engine and captures the hardware output sample rate.
    private func startEngine() {
        do {
            try engine.start()
            lastEngineStartTime = Date()
            let prevRate     = outputSampleRate
            outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let rateChange   = prevRate > 0 && prevRate != outputSampleRate
                ? String(format: " (was %.0fHz ⚠️ RATE CHANGED)", prevRate) : ""
            SFXAudioLog.write(String(format: "[SFXAudio] ENGINE started | hw=%.0fHz%@",
                         outputSampleRate, rateChange))
            addOverloadListener(for: currentHardwareDeviceID())
        } catch {
            SFXAudioLog.write("[SFXAudio] ENGINE start error: \(error)")
            outputSampleRate = 0
        }
    }

    /// Sets the CoreAudio output device on the engine's output unit without
    /// starting or stopping the engine. Call only while the engine is stopped.
    private func applyOutputDeviceID(_ deviceID: AudioDeviceID) {
        guard let outputUnit = engine.outputNode.audioUnit else { return }
        var mutableID = deviceID
        let err = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if err != noErr {
            print("[AudioPlayer] setOutputDevice error: \(err)")
        }
    }

    /// Schedules audio from `startFrame` to `endFrame` (nil = end of file).
    /// If `endFrame` is non-nil and `loopEnabled` is true at completion, loops the segment.
    private func scheduleSegment(from startFrame: AVAudioFramePosition,
                                 to endFrame: AVAudioFramePosition?) {
        guard let file = audioFile else { return }
        seekFrame = startFrame

        let fileEnd    = file.length
        let segEnd     = endFrame ?? fileEnd
        let frameCount = AVAudioFrameCount(max(0, segEnd - startFrame))
        guard frameCount > 0 else { return }

        scheduleGeneration += 1
        let gen        = scheduleGeneration
        let loopStart  = startFrame
        let loopEnd    = endFrame   // nil → no looping

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == gen else { return }

                if let loopEnd, self.loopEnabled, self.selectionStart != nil {
                    // The player node keeps running between iterations (producing
                    // silence), so sampleTime never resets. Capture it now so we
                    // can bias seekFrame: seekFrame + sampleTime == loopStart at
                    // the boundary, then grows correctly through the new iteration.
                    let capturedSampleTime: AVAudioFramePosition
                    if let nt = self.playerNode.lastRenderTime,
                       let pt = self.playerNode.playerTime(forNodeTime: nt) {
                        capturedSampleTime = pt.sampleTime
                    } else {
                        capturedSampleTime = 0
                    }
                    self.scheduleSegment(from: loopStart, to: loopEnd)
                    // Override the seekFrame set inside scheduleSegment so that
                    // updatePosition() computes the correct position immediately.
                    // capturedSampleTime is in the hardware (output) rate; scale to
                    // the file's native rate so both sides of the subtraction match.
                    if let file = self.audioFile {
                        let rateRatio = file.fileFormat.sampleRate / (self.playerNode.lastRenderTime?.sampleRate ?? file.fileFormat.sampleRate)
                        let scaledCaptured = AVAudioFramePosition(Double(capturedSampleTime) * rateRatio)
                        self.seekFrame = loopStart - scaledCaptured
                    } else {
                        self.seekFrame = loopStart - capturedSampleTime
                    }
                    self.playPosition = self.selectionStart ?? 0
                    if !self.playerNode.isPlaying { self.playerNode.play() }
                } else {
                    self.playerNode.stop()
                    self.isPlaying    = false
                    self.playPosition = self.selectionStart ?? 0
                    self.seekFrame    = 0
                    self.timer?.cancel()
                }
            }
        }
    }

    // MARK: - HAL overload monitoring

    /// Called on the main thread when the HAL fires kAudioDeviceProcessorOverload.
    func handleHALOverload() {
        halOverloadCount += 1
        SFXAudioLog.write(String(format: "[SFXAudio] HAL OVERLOAD #%d | isPlaying=%@",
                                 halOverloadCount, isPlaying ? "true" : "false"))
    }

    /// Registers the overload listener on `deviceID`, removing any prior registration first.
    private func addOverloadListener(for deviceID: AudioDeviceID) {
        removeOverloadListener()
        guard deviceID != AudioDeviceID(kAudioDeviceUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if AudioObjectAddPropertyListener(deviceID, &addr, _overloadCallback, selfPtr) == noErr {
            overloadListenerDeviceID = deviceID
        }
    }

    private func removeOverloadListener() {
        guard overloadListenerDeviceID != AudioDeviceID(kAudioDeviceUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(overloadListenerDeviceID, &addr, _overloadCallback, selfPtr)
        overloadListenerDeviceID = AudioDeviceID(kAudioDeviceUnknown)
    }

    /// Reads the current output device ID from the engine's output AudioUnit.
    private func currentHardwareDeviceID() -> AudioDeviceID {
        guard let unit = engine.outputNode.audioUnit else { return AudioDeviceID(kAudioDeviceUnknown) }
        var id   = AudioDeviceID(kAudioDeviceUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &id, &size)
        return id
    }

    private func startPositionTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updatePosition() }
    }

    private func updatePosition() {
        guard engine.isRunning else {
            timerSkipCount += 1
            if timerSkipCount == 1 || timerSkipCount % 24 == 0 {
                SFXAudioLog.write("[SFXAudio] TIMER  engine not running (×\(timerSkipCount))")
            }
            return
        }
        timerSkipCount = 0
        // Detect if the player node stopped unexpectedly while we think we're playing.
        // This can happen due to HAL overloads or CoreAudio-level issues that don't
        // stop the engine itself — the engine stays running but the node goes silent.
        if isPlaying && !playerNode.isPlaying {
            SFXAudioLog.write(String(format: "[SFXAudio] TIMER  playerNode.isPlaying=false while isPlaying=true | overloads=%d",
                                     halOverloadCount))
        }
        guard let file = audioFile,
              let nodeTime   = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              file.length > 0 else { return }

        // playerTime.sampleTime is in the player node's output format rate (= hardware rate),
        // but seekFrame and file.length are in the file's native sample rate.
        // Scale so all three are in the same unit before dividing.
        let rateRatio = file.fileFormat.sampleRate / playerTime.sampleRate
        let scaledSampleTime = AVAudioFramePosition(Double(playerTime.sampleTime) * rateRatio)

        let frame    = seekFrame + scaledSampleTime
        let newPos   = min(max(Double(frame) / Double(file.length), 0), 1)
        // Avoid publishing when the change is too small to move a pixel on screen,
        // which would otherwise spam objectWillChange 30× per second for nothing.
        if abs(newPos - playPosition) > 0.0002 {
            playPosition = newPos
        }
    }
}
