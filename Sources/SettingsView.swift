import ServiceManagement
import SwiftUI

/// Preferences: launch at login, input device, noise-gate sensitivity and listening mode.
struct SettingsView: View {
    @EnvironmentObject private var engine: TunerEngine
    @AppStorage(SettingsKey.sensitivity) private var sensitivity = 0.5
    @AppStorage(SettingsKey.listenOnlyWhileOpen) private var listenOnlyWhileOpen = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { updateLoginItem() }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Listen only while the tuner is open", isOn: $listenOnlyWhileOpen)
                    .onChange(of: listenOnlyWhileOpen) { engine.listeningPreferenceChanged() }
                Text("Saves battery. Turn off to keep the menu bar icon live at all times.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                DevicePicker()
                VStack(alignment: .leading) {
                    Slider(value: $sensitivity, in: 0...1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "speaker")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                    .onChange(of: sensitivity) { engine.setSensitivity(sensitivity) }
                    Text(String(format: "Noise gate: %.0f dBFS. Lower sensitivity ignores more room noise.",
                                TunerEngine.gate(for: sensitivity)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Text("PitchNeedleBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    SupportButton()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }
}
