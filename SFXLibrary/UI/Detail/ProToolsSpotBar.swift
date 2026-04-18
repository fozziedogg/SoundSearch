import SwiftUI

struct ProToolsSpotBar: View {
    let file: AudioFile
    @EnvironmentObject var player: AudioPlayer
    @Environment(AppEnvironment.self) var env

    @State private var isWorking  = false
    @State private var workLabel  = ""
    @State private var lastResult: SpotResult? = nil

    private enum SpotResult {
        case success
        case failure(String)
    }

    var body: some View {
        HStack(spacing: 6) {
            feedbackView
            Spacer()
            if isWorking {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(workLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Spot to PT") { Task { await doSpotContent() } }
                    .buttonStyle(PTSpotButtonStyle())
            }
        }
        .onChange(of: file.id) { _, _ in lastResult = nil }
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackView: some View {
        switch lastResult {
        case .none:
            EmptyView()
        case .success:
            Label("Spotted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(msg)
        }
    }

    // MARK: - Actions

    private func doSpotContent() async {
        guard let sampleRate = file.sampleRate, let duration = file.duration else {
            lastResult = .failure("Missing file metadata"); return
        }
        player.stop()
        begin("Spotting…")

        let request = PTSLContentSpotRequest(
            fileURL:          URL(fileURLWithPath: file.fileURL),
            contentStartSecs: (player.selectionStart ?? 0.0) * duration,
            contentEndSecs:   (player.selectionEnd   ?? 1.0) * duration,
            handles:          env.spotHandles,
            fileSampleRate:   sampleRate
        )
        await run {
            try await env.ptslClient.spotContent(request)
        }
    }

    // MARK: - Helpers

    private func begin(_ label: String) {
        isWorking  = true
        workLabel  = label
        lastResult = nil
    }

    private func run(_ block: @escaping () async throws -> Void) async {
        do {
            try await block()
            lastResult = .success
            env.addToActiveProject(fileURL: file.fileURL)
        } catch {
            lastResult = .failure(error.localizedDescription)
        }
        isWorking = false
    }
}

// MARK: - Button style

private struct PTSpotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
    }
}
