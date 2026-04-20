import Foundation
import AVFoundation
import CoreAudio
import Combine

final class AudioPlayer: ObservableObject {
    @Published var isPlaying:    Bool   = false
    @Published var playPosition: Double = 0   // 0.0 – 1.0
    @Published var duration:     Double = 0
    @Published var volume: Float = {
        if let saved = UserDefaults.standard.object(forKey: "playerVolume") as? Float {
            return saved
        }
        UserDefaults.standard.set(Float(1.0), forKey: "playerVolume")
        return 1.0
    }() {
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

    /// Explicit graph sample rate. 0 = auto (tracks output device via CoreAudio listener).
    /// Persisted to UserDefaults; set from AppEnvironment when the user changes the picker.
    var preferredSampleRate: Double = UserDefaults.standard.double(forKey: "preferredSampleRate") {
        didSet {
            guard oldValue != preferredSampleRate else { return }
            UserDefaults.standard.set(preferredSampleRate, forKey: "preferredSampleRate")
            applyPreferredSampleRate()
        }
    }

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile:  AVAudioFile?
    private var timer:      (any DispatchSourceTimer)?
    private var currentURL: URL?

    // The sample rate of the playerNode→mainMixerNode connection — set whenever we
    // reconnect the graph. Used for position math instead of playerTime.sampleRate,
    // which can transiently report the wrong value during HAL reconfiguration.
    private var graphSampleRate: Double = 0

    // Frame we last scheduled from — added to sampleTime for real position.
    private var seekFrame: AVAudioFramePosition = 0

    // Incremented each schedule call; lets completion callbacks self-invalidate.
    private var scheduleGeneration = 0

    // Debounces AVAudioEngineConfigurationChange — rapid-fire notifications
    // (e.g. Bluetooth glitching, PT Aux I/O reconfiguring) only trigger one restart.
    private var configChangeWork: DispatchWorkItem?
    // Preserved across debounce cancellations so rapid-fire notifications don't
    // lose the intent to resume (the second notification sees isPlaying == false
    // because the first already stopped the node).
    private var configChangeShouldResume:  Bool   = false
    private var configChangeResumePosition: Double = 0
    // Suppresses config-change responses briefly after we restart the engine,
    // breaking the feedback loop where our own restart triggers another notification.
    private var suppressConfigChangeUntil: Date = .distantPast

    // CoreAudio kAudioDevicePropertyNominalSampleRate listener —
    // fires when Pro Tools (or anything else) changes the device's session rate.
    private var sampleRateListenerDeviceID: AudioDeviceID = 0
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?

    // Debug helpers — writes directly to ~/Desktop/sfxaudio.log, bypassing Xcode's stdout pipe.
    private static let debugAudio = true
    private static var t0: Date = Date()
    private static let logHandle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/sfxaudio.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    private func dbg(_ msg: String) {
        guard Self.debugAudio else { return }
        let ms = Int(Date().timeIntervalSince(Self.t0) * 1000)
        let line = "[Audio +\(ms)ms] \(msg)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            Self.logHandle?.write(data)
        }
    }

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

        // Track sample rate changes on the output device so we can reconnect
        // the graph immediately when Pro Tools opens a session at a different rate.
        if let deviceID = resolvedOutputDeviceID() {
            registerSampleRateListener(for: deviceID)
        }

        // macOS stops AVAudioEngine whenever it reconfigures the audio graph —
        // device enumeration at launch, Pro Tools changing the session sample rate, etc.
        // Save playback state and auto-resume after reconnecting so the user hears
        // only a brief dropout rather than audio stopping entirely.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Ignore notifications we triggered ourselves when restarting the engine.
            guard Date() > self.suppressConfigChangeUntil else {
                self.dbg("AVAudioEngineConfigurationChange — SUPPRESSED (our own restart)")
                return
            }

            self.dbg("AVAudioEngineConfigurationChange — LIVE (isPlaying=\(self.isPlaying), engineRunning=\(self.engine.isRunning))")

            if self.isPlaying {
                self.configChangeShouldResume   = true
                self.configChangeResumePosition = self.playPosition
                self.scheduleGeneration += 1
                self.playerNode.stop()
                self.isPlaying = false
                self.timer?.cancel()
                self.seekFrame = 0
                self.dbg("  → stopped playback, will resume at \(String(format: "%.3f", self.configChangeResumePosition))")
            }
            self.configChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldResume = self.configChangeShouldResume
                let resumePos    = self.configChangeResumePosition
                self.configChangeShouldResume = false
                self.dbg("  → restarting engine (shouldResume=\(shouldResume))")
                self.reconnectGraph()
                self.startEngine()
                self.engine.mainMixerNode.outputVolume = self.volume
                self.dbg("  → engine restarted, running=\(self.engine.isRunning), sr=\(self.outputSampleRate)")
                if shouldResume {
                    self.playPosition = resumePos
                    self.play()
                    self.dbg("  → playback resumed")
                }
            }
            self.configChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    /// Restarts the engine if it has stopped (e.g. after Pro Tools changes the session sample rate).
    func recoverEngineIfNeeded() {
        guard !engine.isRunning else { return }
        dbg("recoverEngineIfNeeded — engine was stopped, restarting")
        reconnectGraph()
        startEngine()
        engine.mainMixerNode.outputVolume = volume
        dbg("recoverEngineIfNeeded — done, running=\(engine.isRunning), sr=\(outputSampleRate)")
    }

    // MARK: - Output device

    /// Switches audio output to the device identified by `uid`.
    /// Pass an empty string to revert to the system default.
    func setOutputDevice(uid: String) {
        let deviceID: AudioDeviceID?
        if uid.isEmpty {
            deviceID = AudioDeviceManager.systemDefaultOutputDeviceID()
        } else {
            deviceID = AudioDeviceManager.deviceID(forUID: uid)
        }
        guard let deviceID else { return }

        if isPlaying { stop() }
        engine.stop()

        applyOutputDeviceID(deviceID)
        currentOutputDeviceUID = uid
        UserDefaults.standard.set(uid.isEmpty ? nil : uid, forKey: "outputDeviceUID")

        // Reconnect the graph so the engine re-derives its processing format
        // from the new device's hardware rate (e.g. 44.1 kHz → 48 kHz).
        // Without this the old format is reused and the HAL bridges the mismatch,
        // causing glitches.
        reconnectGraph()
        startEngine()
        if let deviceID = resolvedOutputDeviceID() {
            registerSampleRateListener(for: deviceID)
        }
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
        } catch {
            print("AudioPlayer load error: \(error)")
        }
    }

    // MARK: - Playback

    /// Plays from the current position, or from the active selection if one exists.
    func play() {
        guard let file = audioFile else { return }

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
            scheduleGeneration += 1
            playerNode.stop()
            let frame = AVAudioFramePosition(clamped * Double(file.length))
            scheduleSegment(from: frame, to: nil)   // seek ignores selection / looping
            playerNode.play()
        }
    }

    // MARK: - Private

    /// Disconnects and reconnects the processing graph.
    /// Pass `sampleRate` to lock the graph to a specific rate; nil lets AVAudioEngine
    /// derive the format from the hardware on the next start.
    private func reconnectGraph(sampleRate: Double? = nil) {
        engine.disconnectNodeOutput(playerNode)
        let format: AVAudioFormat? = sampleRate.flatMap {
            AVAudioFormat(standardFormatWithSampleRate: $0, channels: 2)
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        // graphSampleRate is updated to nil-format value after start in startEngine().
        if let rate = sampleRate { graphSampleRate = rate }
    }

    /// Starts the engine and captures the hardware output sample rate.
    /// Reconnects the graph AFTER starting so the node format is derived from
    /// the actually-running hardware rate, not a stale cached value.
    private func startEngine() {
        suppressConfigChangeUntil = Date().addingTimeInterval(2.0)
        dbg("startEngine — suppressing config changes for 2s")
        // Request a large I/O buffer BEFORE starting the engine so AVAudioEngine
        // configures its internal AUs with the matching mMaxFramesPerSlice.
        // Setting it after start causes kAudioUnitErr_TooManyFramesToProcess (-10874).
        if let deviceID = resolvedOutputDeviceID() {
            let ok = AudioDeviceManager.setBufferFrameSize(2048, forDeviceID: deviceID)
            dbg("startEngine — setBufferFrameSize(2048) \(ok ? "OK" : "FAILED")")
        }
        do {
            try engine.start()
            // Reconnect now that the engine is running so the format is derived from
            // the actual settled hardware rate, not a stale pre-start value.
            // If the user has pinned a rate, use that instead of nil.
            let rate: Double? = preferredSampleRate > 0 ? preferredSampleRate : nil
            reconnectGraph(sampleRate: rate)
            outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            // For nil-format connections, graphSampleRate equals the hardware rate.
            if rate == nil { graphSampleRate = outputSampleRate }
            dbg("startEngine — OK, sr=\(outputSampleRate)")
        } catch {
            dbg("startEngine — FAILED: \(error)")
            print("[AudioPlayer] engine start error: \(error)")
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
                        let connRate  = self.graphSampleRate > 0 ? self.graphSampleRate : (self.playerNode.lastRenderTime?.sampleRate ?? file.fileFormat.sampleRate)
                        let rateRatio = file.fileFormat.sampleRate / connRate
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

    private func startPositionTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.updatePosition() }
        }
        t.resume()
        timer = t
    }

    private var _nilPlayerTimeCount = 0

    private func updatePosition() {
        guard isPlaying else { return }
        guard engine.isRunning else {
            dbg("updatePosition — engine stopped while isPlaying=true")
            return
        }
        guard let file = audioFile, file.length > 0 else { return }
        guard let nodeTime = playerNode.lastRenderTime else {
            _nilPlayerTimeCount += 1
            if _nilPlayerTimeCount == 1 || _nilPlayerTimeCount % 24 == 0 {
                dbg("updatePosition — lastRenderTime nil (x\(_nilPlayerTimeCount))")
            }
            return
        }
        guard let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            _nilPlayerTimeCount += 1
            if _nilPlayerTimeCount == 1 || _nilPlayerTimeCount % 24 == 0 {
                dbg("updatePosition — playerTime nil (x\(_nilPlayerTimeCount)), nodeRunning=\(playerNode.isPlaying)")
            }
            return
        }
        _nilPlayerTimeCount = 0

        // playerTime.sampleTime is in the player node's connection rate (graphSampleRate).
        // seekFrame and file.length are in the file's native sample rate.
        // Scale so all three are in the same unit.
        // Use graphSampleRate (captured at engine start) rather than playerTime.sampleRate,
        // which can transiently report the wrong value during HAL reconfiguration.
        let connectionRate = graphSampleRate > 0 ? graphSampleRate : playerTime.sampleRate
        let rateRatio = file.fileFormat.sampleRate / connectionRate
        let scaledSampleTime = AVAudioFramePosition(Double(playerTime.sampleTime) * rateRatio)

        let frame    = seekFrame + scaledSampleTime
        let newPos   = min(max(Double(frame) / Double(file.length), 0), 1)

        // Detect a position jump larger than ~0.5s — likely a glitch or engine restart.
        if abs(newPos - playPosition) > (0.5 / max(duration, 1)) {
            dbg("POSITION JUMP: \(String(format: "%.3f", playPosition)) → \(String(format: "%.3f", newPos))  (nodeRunning=\(playerNode.isPlaying), sampleTime=\(playerTime.sampleTime), seekFrame=\(seekFrame), rateRatio=\(String(format: "%.4f", file.fileFormat.sampleRate / playerTime.sampleRate)))")
        }

        if abs(newPos - playPosition) > 0.0002 {
            playPosition = newPos
        }
    }

    // MARK: - Sample rate listener

    private func resolvedOutputDeviceID() -> AudioDeviceID? {
        currentOutputDeviceUID.isEmpty
            ? AudioDeviceManager.systemDefaultOutputDeviceID()
            : AudioDeviceManager.deviceID(forUID: currentOutputDeviceUID)
    }

    private func registerSampleRateListener(for deviceID: AudioDeviceID) {
        unregisterSampleRateListener()
        guard deviceID != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceSampleRateChange() }
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, nil, block)
        sampleRateListenerDeviceID = deviceID
        sampleRateListenerBlock    = block
        dbg("sampleRateListener — registered on device \(deviceID)")
    }

    private func unregisterSampleRateListener() {
        guard sampleRateListenerDeviceID != 0, let block = sampleRateListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(sampleRateListenerDeviceID, &addr, nil, block)
        sampleRateListenerDeviceID = 0
        sampleRateListenerBlock    = nil
    }

    /// Called by the CoreAudio listener when the output device's nominal sample rate changes.
    /// Restarts the engine with the new rate so our graph stays in sync with the PT session.
    private func handleDeviceSampleRateChange() {
        guard Date() > suppressConfigChangeUntil else {
            dbg("sampleRateListener — SUPPRESSED (our own restart)")
            return
        }
        // If the user has pinned a rate, the device rate is irrelevant.
        guard preferredSampleRate == 0 else {
            dbg("sampleRateListener — ignored (pinned to \(Int(preferredSampleRate)) Hz)")
            return
        }
        let newRate = AudioDeviceManager.nominalSampleRate(forDeviceID: sampleRateListenerDeviceID)
        guard newRate > 0 else { return }
        dbg("sampleRateListener — device rate → \(Int(newRate)) Hz, restarting engine")

        let wasPlaying = isPlaying
        let resumePos  = playPosition
        if wasPlaying {
            scheduleGeneration += 1
            playerNode.stop()
            isPlaying = false
            timer?.cancel()
            seekFrame = 0
        }
        engine.stop()
        reconnectGraph(sampleRate: newRate)
        startEngine()
        engine.mainMixerNode.outputVolume = volume
        if wasPlaying {
            playPosition = resumePos
            play()
            dbg("sampleRateListener — playback resumed at \(String(format: "%.3f", resumePos))")
        }
    }

    /// Applies a change to `preferredSampleRate` immediately: restarts the engine with the
    /// new rate (or nil for auto) and resumes playback if it was active.
    private func applyPreferredSampleRate() {
        let wasPlaying = isPlaying
        let resumePos  = playPosition
        if wasPlaying {
            scheduleGeneration += 1
            playerNode.stop()
            isPlaying = false
            timer?.cancel()
            seekFrame = 0
        }
        engine.stop()
        reconnectGraph(sampleRate: preferredSampleRate > 0 ? preferredSampleRate : nil)
        startEngine()
        engine.mainMixerNode.outputVolume = volume
        if wasPlaying {
            playPosition = resumePos
            play()
        }
    }

    deinit {
        unregisterSampleRateListener()
    }
}
