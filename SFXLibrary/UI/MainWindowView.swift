import SwiftUI

struct MainWindowView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selectedFile: AudioFile?
    @State private var showFileInfo: Bool = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VSplitView {
                // Top pane: Preview above File Info (File Info collapsible)
                Group {
                    if let file = selectedFile {
                        VStack(spacing: 0) {
                            PreviewView(file: file)
                            Divider()
                            FileInfoView(file: file, isExpanded: $showFileInfo)
                                .frame(minHeight: showFileInfo ? 120 : 0)
                        }
                    } else {
                        Text("Select a file")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 200)

                // Bottom pane: Browser
                FileListView(selectedFile: $selectedFile)
                    .frame(minHeight: 160)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
