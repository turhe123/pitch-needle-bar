import AppKit
import SwiftUI

/// App entry point: a menu bar tuner window plus a standard Settings scene.
@main
struct PitchNeedleBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = TunerEngine.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(engine)
        } label: {
            MenuBarIcon(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}

/// Starts continuous listening at launch when the user opted out of "listen only while open".
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TunerEngine.shared.appLaunched()
    }
}

/// Tuning-fork status item that turns green while the current note is within ±5 cents.
struct MenuBarIcon: View {
    @ObservedObject var engine: TunerEngine
    @AppStorage(SettingsKey.referencePitch) private var reference = 440.0

    var body: some View {
        let inTune = engine.frequency.map { abs(NoteMath.reading(frequency: $0, reference: reference).cents) <= 5 } ?? false
        Image(nsImage: Self.image(inTune: inTune))
    }

    static func image(inTune: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: "tuningfork", accessibilityDescription: "PitchNeedleBar")
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "PitchNeedleBar")
            ?? NSImage()
        if inTune, let colored = base.withSymbolConfiguration(.init(paletteColors: [.systemGreen])) {
            colored.isTemplate = false
            return colored
        }
        base.isTemplate = true
        return base
    }
}

/// The donation button required on every surface of the app.
struct SupportButton: View {
    var body: some View {
        Button("Support / Donate ❤️") {
            if let url = URL(string: "https://ko-fi.com/leodavidai") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
