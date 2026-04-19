import SwiftUI
import AppKit

struct MainWindowView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selectedFile: AudioFile?
    @State private var showFileInfo: Bool = true
    @State private var detailHeight: CGFloat = 380
    @State private var fileInfoHeight: CGFloat = 140

    private let minDetail: CGFloat  = 240
    private let minBrowser: CGFloat = 120
    private let dividerHeight: CGFloat = 28   // height of the Browser header/handle

    private var windowTitle: String {
        let dbName = env.currentDatabaseURL.deletingPathExtension().lastPathComponent
        return "SoundSearch — \(dbName)"
    }

    private func applyWindowTitle(_ title: String) {
        NSApplication.shared.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .forEach { $0.title = title }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            GeometryReader { geo in
                let total    = geo.size.height
                let clamped  = max(minDetail, min(total - dividerHeight - minBrowser, detailHeight))

                VStack(spacing: 0) {
                    // Top pane — Preview + File Info
                    Group {
                        if let file = selectedFile {
                            VStack(spacing: 0) {
                                PreviewView(file: file)
                                    .frame(maxHeight: .infinity)
                                FileInfoView(
                                    file: file,
                                    isExpanded: $showFileInfo,
                                    onHeaderDrag: { delta in
                                        let minFI: CGFloat = 80
                                        let maxFI = max(minFI, clamped - 120)
                                        if !showFileInfo {
                                            // Collapsed: drag up to expand
                                            if delta < -10 {
                                                withAnimation(.easeInOut(duration: 0.18)) { showFileInfo = true }
                                            }
                                        } else {
                                            let proposed = fileInfoHeight - delta
                                            if proposed < minFI - 30 {
                                                withAnimation(.easeInOut(duration: 0.18)) { showFileInfo = false }
                                            } else {
                                                fileInfoHeight = max(minFI, min(maxFI, proposed))
                                            }
                                        }
                                    }
                                )
                                .frame(height: showFileInfo
                                       ? max(80, min(fileInfoHeight, clamped - 120))
                                       : nil)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                PanelHeader(title: "Preview")
                                Spacer()
                                PlayerControlsView()
                                    .environmentObject(env.audioPlayer)
                                    .environment(env)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .padding(.bottom, 4)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: clamped)

                    // Draggable Browser header — acts as both title and resize handle
                    BrowserDivider { delta in
                        detailHeight = max(minDetail,
                                          min(total - dividerHeight - minBrowser,
                                              detailHeight + delta))
                    }

                    // Bottom pane — Browser (header supplied by BrowserDivider above)
                    FileListView(selectedFile: $selectedFile, showHeader: false)
                }
            }
        }
        .id(env.databaseEpoch)
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(windowTitle)
        .onAppear { applyWindowTitle(windowTitle) }
        .onChange(of: env.currentDatabaseURL) { _, _ in
            applyWindowTitle(windowTitle)
            selectedFile = nil
        }
        .onChange(of: env.audioFiles) { _, newFiles in
            if let sel = selectedFile, !newFiles.contains(where: { $0.id == sel.id }) {
                selectedFile = nil
            }
        }
    }
}

// MARK: - Draggable Browser header / pane divider

private struct BrowserDivider: View {
    let onDrag: (CGFloat) -> Void

    @State private var prevTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text("Browser")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.70))
                .textCase(.uppercase)
                .tracking(1.5)
            Spacer()
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(white: isHovering ? 0.65 : 0.42))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(isHovering ? 0.65 : 0.55))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 0.5)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeUpDown.push() }
            else        { NSCursor.pop() }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { val in
                    let delta = val.translation.height - prevTranslation
                    prevTranslation = val.translation.height
                    onDrag(delta)
                }
                .onEnded { _ in prevTranslation = 0 }
        )
    }
}
