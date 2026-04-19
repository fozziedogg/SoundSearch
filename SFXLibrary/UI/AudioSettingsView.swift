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

                Picker("Engine Sample Rate", selection: $bEnv.preferredSampleRate) {
                    Text("Auto (follow device)").tag(Double(0))
                    Divider()
                    Text("44.1 kHz").tag(Double(44100))
                    Text("48 kHz").tag(Double(48000))
                    Text("88.2 kHz").tag(Double(88200))
                    Text("96 kHz").tag(Double(96000))
                }
                .pickerStyle(.menu)

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
                Text("Choose the CoreAudio device the preview engine sends audio to. Engine Sample Rate: Auto tracks Pro Tools session rate changes automatically via CoreAudio. Pin to a specific rate if you always work at one rate and want to avoid restarts.")
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
                Toggle("Stop playback when switching apps", isOn: $bEnv.stopOnDefocus)
                Toggle("Reset gain when opening new file", isOn: $bEnv.resetVolumeOnLoad)
                Toggle("Commit volume on export", isOn: $bEnv.commitVolumeOnExport)
            } header: {
                Text("Playback")
            } footer: {
                Text("Commit volume: when enabled, the current preview volume is baked into audio delivered via drag or Spot to PT. Unity gain (100%) is a no-op.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable metadata editing", isOn: $bEnv.metadataEditingEnabled)
            } header: {
                Text("File Info")
            } footer: {
                Text("When off, the File Info pane shows metadata as read-only text. Enable to edit BWF, iXML, UCS, and notes fields.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                Toggle("Focus Pro Tools after spot", isOn: $bEnv.focusProToolsOnSpot)
            } header: {
                Text("Pro Tools Spot")
            }

            Section {
                Picker("Appearance", selection: $bEnv.appearanceMode) {
                    Text("Dark").tag("dark")
                    Text("Warm").tag("warm")
                    Text("Light").tag("light")
                }
                Toggle("Graham Rogers Mode", isOn: $bEnv.grahamRogersMode)
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Graham Rogers Mode replaces green/red with teal/orange throughout the interface, making status indicators distinguishable for red-green colour blindness.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 460, height: 490)
        .onAppear { refreshDevices() }
    }

    private func refreshDevices() {
        devices     = AudioDeviceManager.outputDevices()
        selectedUID = env.audioPlayer.currentOutputDeviceUID
    }
}
