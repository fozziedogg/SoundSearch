import SwiftUI
import AppKit

/// Identifiable wrapper so a set of files can drive `.sheet(item:)`.
struct ExportRequest: Identifiable {
    let id = UUID()
    let files: [AudioFile]
}

/// Sheet that exports a set of files to a chosen format/rate/depth into a target
/// folder. Runs sequentially with a progress bar; per-file failures are collected
/// and shown without aborting the batch.
struct ExportSheet: View {
    let files: [AudioFile]
    @Environment(\.dismiss) private var dismiss

    // Options
    @State private var format: AudioExportFormat = .wav
    @State private var sampleRate: Int? = nil          // nil = Original
    @State private var bitDepth: Int? = nil            // nil = Original
    @State private var aacBitrateKbps: Int = 256
    @State private var mp3BitrateKbps: Int = 320
    @State private var preserveMetadata: Bool = true
    @State private var targetFolder: URL? = nil

    // Run state
    @State private var isExporting = false
    @State private var completed = 0
    @State private var failures: [(name: String, message: String)] = []
    @State private var finished = false

    private let sampleRates = [44_100, 48_000, 88_200, 96_000, 192_000]
    private let bitDepths = [16, 24, 32]                // 32 = 32-bit float
    private let bitrates = [128, 192, 256, 320]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if finished { resultView } else { optionsForm }
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear { if preserveMetadata == false { preserveMetadata = format.supportsMetadataBWF } }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up")
            Text(files.count == 1 ? "Export “\(files[0].filename)”"
                                  : "Export \(files.count) Files")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Options

    private var optionsForm: some View {
        Form {
            Picker("Format", selection: $format) {
                ForEach(AudioExportFormat.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .onChange(of: format) { _, new in
                if !new.supportsBitDepth { bitDepth = nil }
                preserveMetadata = new.supportsMetadataBWF
            }

            Picker("Sample Rate", selection: $sampleRate) {
                Text("Original").tag(Int?.none)
                ForEach(sampleRates, id: \.self) { r in
                    Text(rateLabel(r)).tag(Int?.some(r))
                }
            }

            if format.supportsBitDepth {
                Picker("Bit Depth", selection: $bitDepth) {
                    Text("Original").tag(Int?.none)
                    ForEach(bitDepths, id: \.self) { d in
                        Text(d == 32 ? "32-bit float" : "\(d)-bit").tag(Int?.some(d))
                    }
                }
            }

            if format.isLossy {
                Picker("Bitrate", selection: format == .aac ? $aacBitrateKbps : $mp3BitrateKbps) {
                    ForEach(bitrates, id: \.self) { b in
                        Text("\(b) kbps").tag(b)
                    }
                }
            }

            if format.supportsMetadataBWF {
                Toggle("Preserve BWF metadata (bext / iXML)", isOn: $preserveMetadata)
            }

            LabeledContent("Destination") {
                HStack(spacing: 6) {
                    Text(targetFolder?.lastPathComponent ?? "Choose a folder…")
                        .foregroundColor(targetFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 320)
    }

    // MARK: - Result

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let ok = files.count - failures.count
            Label("\(ok) of \(files.count) exported", systemImage: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(failures.isEmpty ? .green : .orange)
                .font(.headline)
            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures.indices, id: \.self) { i in
                            Text("• \(failures[i].name): \(failures[i].message)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            if let targetFolder {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([targetFolder])
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(minHeight: 120)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isExporting {
                ProgressView(value: Double(completed), total: Double(files.count))
                    .frame(width: 160)
                Text("\(completed)/\(files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if finished {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { Task { await runExport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetFolder == nil || isExporting || files.isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func rateLabel(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return abs(k - k.rounded()) < 0.05 ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.canCreateDirectories    = true
        panel.allowsMultipleSelection = false
        panel.prompt  = "Choose"
        panel.message = "Choose or create a destination folder for the exported files"
        if panel.runModal() == .OK { targetFolder = panel.url }
    }

    private func settings() -> ExportSettings {
        ExportSettings(
            format: format,
            sampleRate: sampleRate,
            bitDepth: format.supportsBitDepth ? bitDepth : nil,
            aacBitrate: aacBitrateKbps * 1000,
            mp3Bitrate: mp3BitrateKbps,
            region: nil,
            preserveMetadata: preserveMetadata)
    }

    private func runExport() async {
        guard let folder = targetFolder else { return }
        isExporting = true
        completed = 0
        failures = []
        let cfg = settings()

        for file in files {
            let source = URL(fileURLWithPath: file.fileURL)
            let dest = uniqueDestination(for: file, in: folder, ext: cfg.format.fileExtension)
            do {
                try await AudioExportService.export(source: source, to: dest, settings: cfg)
            } catch {
                failures.append((file.filename, error.localizedDescription))
            }
            completed += 1
        }

        isExporting = false
        finished = true
    }

    /// Builds a non-colliding destination URL, appending " (1)", " (2)"… if needed.
    private func uniqueDestination(for file: AudioFile, in folder: URL, ext: String) -> URL {
        let base = URL(fileURLWithPath: file.fileURL).deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
