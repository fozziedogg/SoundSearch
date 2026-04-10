import SwiftUI

struct MainWindowView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selectedFile: AudioFile?

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VSplitView {
                // Top pane: waveform + detail for selected file
                Group {
                    if let file = selectedFile {
                        DetailView(file: file)
                    } else {
                        Text("Select a file")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 240)

                // Bottom pane: file list
                FileListView(selectedFile: $selectedFile)
                    .frame(minHeight: 160)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
