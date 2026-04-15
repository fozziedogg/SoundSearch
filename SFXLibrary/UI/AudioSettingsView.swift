import SwiftUI
import AppKit

// MARK: - Screen-aware colour picker (positions NSColorPanel on the same screen as the app)

private final class PositioningColorWell: NSColorWell {
    var onChange: ((NSColor) -> Void)?
    private var panelObserver: NSObjectProtocol?

    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        // Move the shared colour panel to the same screen as our window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let screen = window.screen else { return }
            let panel = NSColorPanel.shared
            var f  = panel.frame
            let sf = screen.visibleFrame
            f.origin.x = max(sf.minX, min(sf.maxX - f.width,  sf.midX - f.width  / 2))
            f.origin.y = max(sf.minY, min(sf.maxY - f.height, sf.midY - f.height / 2))
            panel.setFrameOrigin(f.origin)
        }
        panelObserver = NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: NSColorPanel.shared, queue: .main
        ) { [weak self] _ in
            self?.onChange?(NSColorPanel.shared.color)
        }
    }

    override func deactivate() {
        super.deactivate()
        if let obs = panelObserver {
            NotificationCenter.default.removeObserver(obs)
            panelObserver = nil
        }
    }
}

private struct ScreenAwareColorPicker: NSViewRepresentable {
    @Binding var selection: Color

    func makeNSView(context: Context) -> PositioningColorWell {
        let well = PositioningColorWell()
        well.color = NSColor(selection)
        return well
    }

    func updateNSView(_ well: PositioningColorWell, context: Context) {
        if !well.isActive { well.color = NSColor(selection) }
        let binding = $selection
        well.onChange = { nsColor in binding.wrappedValue = Color(nsColor) }
    }
}

// MARK: -

struct AudioSettingsView: View {
    @Environment(AppEnvironment.self) var env
    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedUID: String = ""

    var body: some View {
        @Bindable var bEnv = env
        Form {
            Section {
                Picker("Output Device", selection: $selectedUID) {
                    Text("System Default").tag("")
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedUID) { _, uid in
                    env.audioPlayer.setOutputDevice(uid: uid)
                }

                HStack {
                    if env.audioPlayer.outputSampleRate > 0 {
                        Text("Running at \(Int(env.audioPlayer.outputSampleRate / 1000)) kHz")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Refresh") {
                        refreshDevices()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            } header: {
                Text("Audio Output")
            } footer: {
                Text("Choose the CoreAudio device the preview engine sends audio to. Pro Tools Aux I/O and aggregate devices appear here when active. Switch devices while Pro Tools is running to match its session sample rate.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Waveform colour")
                    Spacer()
                    ScreenAwareColorPicker(selection: $bEnv.waveformColor)
                        .frame(width: 44, height: 26)
                }
            } header: {
                Text("Waveform")
            }

            Section {
                Toggle("Auto-add to active project", isOn: $bEnv.autoAddToProject)
            } header: {
                Text("Projects")
            } footer: {
                Text("When enabled, files are automatically added to the active project whenever you drag a file to Pro Tools or use the Spot button.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Selection export", selection: $bEnv.dragExportMode) {
                    ForEach(DragExportMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Pro Tools Drag")
            } footer: {
                Text("Controls what audio is delivered when dragging a waveform selection to the Pro Tools timeline. 'Whole file' delivers the original file with the BEXT timecode set to the selection start, so PT spots the clip at the right position and you can trim to taste.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .onAppear { refreshDevices() }
    }

    private func refreshDevices() {
        devices     = AudioDeviceManager.outputDevices()
        selectedUID = env.audioPlayer.currentOutputDeviceUID
    }
}
