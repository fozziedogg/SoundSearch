import SwiftUI

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
                ColorPicker("Waveform colour", selection: $bEnv.waveformColor)
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
