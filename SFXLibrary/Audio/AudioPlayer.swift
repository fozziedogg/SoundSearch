import Foundation
import AVFoundation
import CoreAudio
import Combine

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

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile:  AVAudioFile?
    private var timer:      AnyCancellable?
    private var currentURL: URL?

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
                self.reconnectGraph()
                self.startEngine()
                self.engine.mainMixerNode.outputVolume = self.volume
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

    /// Restarts the engine if it has stopped (e.g. after Pro Tools changes the session sample rate).
    func recoverEngineIfNeeded() {
        guard !engine.isRunning else { return }
        reconnectGraph()
        startEngine()
        engine.mainMixerNode.outputVolume = volume
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

    /// Disconnects and reconnects the processing graph so AVAudioEngine
    /// re-derives node formats from the current hardware rate on next start.
    private func reconnectGraph() {
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    /// Starts the engine and captures the hardware output sample rate.
    private func startEngine() {
        do {
            try engine.start()
            outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        } catch {
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

    private func startPositionTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updatePosition() }
    }

    private func updatePosition() {
        guard engine.isRunning,
              let file = audioFile,
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
