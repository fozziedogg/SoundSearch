import Foundation
import AVFoundation
import Combine

final class AudioPlayer: ObservableObject {
    @Published var isPlaying:     Bool   = false
    @Published var playPosition:  Double = 0   // 0.0 – 1.0
    @Published var duration:      Double = 0
    @Published var pitchSemitones: Float = 0
    @Published var pitchCents:     Float = 0

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch  = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var timer:     AnyCancellable?
    private var currentURL: URL?

    // Tracks which frame we last scheduled from, so updatePosition() can
    // add this offset to sampleTime and get the real playhead position.
    private var seekFrame: AVAudioFramePosition = 0

    // Incremented each time we schedule a new segment; lets the completion
    // callback tell whether it belongs to the most recent schedule call.
    private var scheduleGeneration = 0

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch,            format: nil)
        engine.connect(timePitch,  to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    // MARK: - Load

    func load(url: URL) {
        guard url != currentURL else { return }
        stop()
        currentURL = url
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

    func play() {
        guard let file = audioFile else { return }
        let targetFrame = AVAudioFramePosition(playPosition * Double(file.length))
        schedule(from: targetFrame)
        playerNode.play()
        isPlaying = true
        startPositionTimer()
    }

    func stop() {
        scheduleGeneration += 1   // invalidate any pending completion callback
        playerNode.stop()
        isPlaying = false
        timer?.cancel()
    }

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    // MARK: - Scrubbing

    func seek(to fraction: Double) {
        guard let file = audioFile else { return }
        let clamped = min(max(fraction, 0), 1)
        playPosition = clamped
        if isPlaying {
            scheduleGeneration += 1   // invalidate old completion callback before stop
            playerNode.stop()
            let targetFrame = AVAudioFramePosition(clamped * Double(file.length))
            schedule(from: targetFrame)
            playerNode.play()
        }
    }

    // MARK: - Pitch

    func setPitch(semitones: Float, cents: Float) {
        pitchSemitones  = semitones
        pitchCents      = cents
        timePitch.pitch = semitones * 100 + cents
    }

    func resetPitch() { setPitch(semitones: 0, cents: 0) }

    // MARK: - Private

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        seekFrame = frame
        let remaining = AVAudioFrameCount(max(0, file.length - frame))
        guard remaining > 0 else { return }

        scheduleGeneration += 1
        let gen = scheduleGeneration

        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == gen else { return }
                self.isPlaying    = false
                self.playPosition = 0
                self.seekFrame    = 0
                self.timer?.cancel()
            }
        }
    }

    private func startPositionTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updatePosition() }
    }

    private func updatePosition() {
        guard let file = audioFile,
              let nodeTime   = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              file.length > 0 else { return }
        // sampleTime counts from the last scheduleSegment call, so add seekFrame
        let frame = seekFrame + playerTime.sampleTime
        playPosition = min(max(Double(frame) / Double(file.length), 0), 1)
    }
}
