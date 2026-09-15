import SwiftUI
import AppKit

/// Repoints the library at a folder that moved, instead of rescanning it.
///
/// Shown automatically at launch when a watched folder's stored path is gone, and
/// available on demand from Library > Relocate Library….
struct RelocateLibrarySheet: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) private var dismiss

    let request: AppEnvironment.RelocationRequest

    @State private var newPath: String = ""
    @State private var preview: LibraryRelocator.Preview?
    @State private var result: LibraryRelocator.Result?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let result {
                doneBody(result)
            } else {
                pathRows
                previewRow
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            newPath = request.suggestedNewPath ?? ""
            refreshPreview()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result == nil ? "Relocate Library" : "Library Relocated")
                .font(.title2.weight(.semibold))
            if result == nil {
                Text("This folder isn't where the database says it is — usually because the drive "
                     + "remounted under a different name, or the database came from another system. "
                     + "Point it at the new location to rewrite the stored paths. "
                     + "Ratings, notes, tags, and projects are preserved, and nothing is re-indexed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pathRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Stored location") {
                Text(request.oldPath)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("New location") {
                HStack(spacing: 8) {
                    TextField("", text: $newPath, prompt: Text("Choose the folder's current location"))
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { refreshPreview() }
                        .onChange(of: newPath) { _, _ in refreshPreview() }
                    Button("Choose…") { chooseFolder() }
                }
            }

            if let suggested = request.suggestedNewPath, suggested != newPath {
                Button("Use suggested: \(suggested)") { newPath = suggested }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                if preview.isEmpty {
                    Label("No stored paths start with the old location — nothing to rewrite.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("\(preview.audioFiles) files, \(preview.watchedFolders) watched "
                          + "folder(s), \(preview.projectFiles) project entries will be repointed.",
                          systemImage: "arrow.triangle.swap")
                }
                if preview.conflictingAudioFiles > 0 {
                    Text("\(preview.conflictingAudioFiles) file(s) were already re-indexed at the new "
                         + "location. The duplicates are discarded and the original records — with "
                         + "their ratings and notes — are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }
    }

    private func doneBody(_ result: LibraryRelocator.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(result.audioFilesUpdated) file records repointed to \(newPath)",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("\(result.watchedFoldersUpdated) watched folder(s) and "
                 + "\(result.projectFilesUpdated) project entries updated"
                 + (result.duplicatesReplaced > 0
                    ? ", \(result.duplicatesReplaced) duplicate record(s) removed." : "."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            if result == nil, !env.missingFolders.isEmpty {
                Text("\(env.missingFolders.count) folder(s) currently unreachable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if result == nil {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Relocate") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private var canApply: Bool {
        guard !newPath.isEmpty, newPath != request.oldPath, !env.isScanning else { return false }
        guard let preview else { return false }
        return !preview.isEmpty
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder's current location"
        panel.prompt  = "Select"
        if let suggested = request.suggestedNewPath,
           FileManager.default.fileExists(atPath: suggested) {
            panel.directoryURL = URL(fileURLWithPath: suggested)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newPath = url.path
    }

    private func refreshPreview() {
        errorMessage = nil
        guard !newPath.isEmpty, newPath != request.oldPath else { preview = nil; return }
        guard FileManager.default.fileExists(atPath: newPath) else {
            preview = nil
            errorMessage = "That location doesn't exist on this system."
            return
        }
        preview = env.previewRelocation(from: request.oldPath, to: newPath)
    }

    private func apply() {
        guard let outcome = env.relocateLibrary(from: request.oldPath, to: newPath) else {
            errorMessage = env.isScanning
                ? "A scan is in progress — wait for it to finish, then try again."
                : "Relocation failed. See the log in the database folder's Debug Logs."
            return
        }
        result = outcome
    }
}
