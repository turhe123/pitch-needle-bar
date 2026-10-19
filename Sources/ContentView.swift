import AppKit
import SwiftUI

/// The tuner popover: note readout, needle gauge, quick controls and the reference tone.
struct ContentView: View {
    @EnvironmentObject private var engine: TunerEngine
    @AppStorage(SettingsKey.referencePitch) private var reference = 440.0
    @AppStorage(SettingsKey.transposition) private var transposeRaw = Transposition.concert.rawValue
    @AppStorage(SettingsKey.toneNote) private var toneNote = 69
    @State private var clampMessage: String?

    private var transposition: Transposition { Transposition(rawValue: transposeRaw) ?? .concert }
    private var reading: (midi: Int, cents: Double)? {
        engine.frequency.map { NoteMath.reading(frequency: $0, reference: reference) }
    }

    var body: some View {
        VStack(spacing: 10) {
            if engine.permission == .denied {
                PermissionBlockedView()
            } else {
                header
                NeedleGauge(cents: reading?.cents)
                    .frame(height: 96)
                statusLine
                controls
                toneRow
            }
            Divider()
            HStack {
                SupportButton()
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit PitchNeedleBar")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 290)
        .onAppear {
            clampReference()
            engine.popoverOpened()
        }
        .onDisappear { engine.popoverClosed() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let reading {
                let written = reading.midi + transposition.rawValue
                Text(NoteMath.name(written))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(abs(reading.cents) <= 5 ? .green : .primary)
                Text("\(NoteMath.octave(written))")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("––").font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(engine.frequency.map { String(format: "%.1f Hz", $0) } ?? "––– Hz")
                    .font(.system(.body, design: .monospaced))
                Text(reading.map { String(format: "%+.0f cents", $0.cents) } ?? "–– cents")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if engine.isHeld {
                    Text("HOLD").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let message = engine.notice ?? clampMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if engine.micPausedForTone {
            Text("Mic paused while the tone plays on speakers — use headphones to tune along.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        } else if reading == nil {
            Text(engine.isRunning ? "Play a note" : "Starting microphone…")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            DevicePicker()
            Stepper(value: $reference, in: NoteMath.referenceRange, step: 1) {
                Text("A4 = \(Int(reference)) Hz")
            }
            .onChange(of: reference) { engine.updateTone(hz: NoteMath.frequency(midi: toneNote, reference: reference)) }
            Picker("Transpose", selection: $transposeRaw) {
                ForEach(Transposition.allCases) { Text($0.label).tag($0.rawValue) }
            }
        }
        .controlSize(.small)
    }

    private var toneRow: some View {
        HStack(spacing: 6) {
            Button { engine.isHeld.toggle() } label: {
                Label(engine.isHeld ? "Release" : "Hold", systemImage: engine.isHeld ? "lock.fill" : "lock.open")
            }
            Spacer()
            Text("Tone").foregroundStyle(.secondary)
            Button { changeTone(by: -1) } label: { Image(systemName: "chevron.left") }
            Text("\(NoteMath.name(toneNote + transposition.rawValue))\(NoteMath.octave(toneNote + transposition.rawValue))")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 34)
            Button { changeTone(by: 1) } label: { Image(systemName: "chevron.right") }
            Button {
                engine.toggleTone(hz: NoteMath.frequency(midi: toneNote, reference: reference))
            } label: {
                Image(systemName: engine.isTonePlaying ? "stop.fill" : "play.fill")
            }
            .help("Play a reference tone")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func changeTone(by step: Int) {
        toneNote = min(max(toneNote + step, 28), 96)
        engine.updateTone(hz: NoteMath.frequency(midi: toneNote, reference: reference))
    }

    private func clampReference() {
        let clamped = NoteMath.clampReference(reference)
        if clamped != reference {
            reference = clamped
            clampMessage = "Reference pitch must be 415–466 Hz; set to \(Int(clamped)) Hz."
        }
    }
}

/// Input-device menu; switching restarts the capture engine on the new device.
struct DevicePicker: View {
    @EnvironmentObject private var engine: TunerEngine
    @AppStorage(SettingsKey.deviceUID) private var deviceUID = ""

    var body: some View {
        Picker("Input", selection: $deviceUID) {
            Text("System Default").tag("")
            ForEach(engine.devices) { Text($0.name).tag($0.uid) }
        }
        .onChange(of: deviceUID) { engine.restart() }
    }
}

/// Semicircular cents meter from −50 to +50 whose needle turns green within ±5 cents.
struct NeedleGauge: View {
    let cents: Double?

    var body: some View {
        let inTune = cents.map { abs($0) <= 5 } ?? false
        ZStack {
            Canvas { context, size in
                let geometry = GaugeGeometry(rect: CGRect(origin: .zero, size: size))
                context.stroke(geometry.arc(from: -50, to: 50), with: .color(.secondary.opacity(0.25)), lineWidth: 6)
                context.stroke(geometry.arc(from: -5, to: 5), with: .color(.green.opacity(0.8)), lineWidth: 6)
                for value in stride(from: -50, through: 50, by: 10) {
                    var tick = Path()
                    let length: CGFloat = value == 0 ? 14 : 8
                    tick.move(to: geometry.point(cents: Double(value), radius: geometry.radius - 6))
                    tick.addLine(to: geometry.point(cents: Double(value), radius: geometry.radius - 6 - length))
                    context.stroke(tick, with: .color(.secondary), lineWidth: value == 0 ? 2 : 1)
                }
            }
            NeedleShape(cents: min(max(cents ?? 0, -50), 50))
                .stroke(inTune ? Color.green : (cents == nil ? Color.secondary.opacity(0.3) : Color.red),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .animation(.easeOut(duration: 0.15), value: cents ?? 0)
            HStack {
                Text("♭").font(.title3)
                Spacer()
                Text("♯").font(.title3)
            }
            .foregroundStyle(.secondary)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel(cents.map { String(format: "%+.0f cents", $0) } ?? "No pitch")
    }
}

/// Shared geometry for the gauge: pivot at the bottom centre, −50…+50 cents spans 180°.
struct GaugeGeometry {
    let center: CGPoint
    let radius: CGFloat

    init(rect: CGRect) {
        center = CGPoint(x: rect.midX, y: rect.maxY - 4)
        radius = max(10, min(rect.width / 2, rect.height) - 6)
    }

    func point(cents: Double, radius r: CGFloat) -> CGPoint {
        let angle = (cents / 50) * (Double.pi / 2)
        return CGPoint(x: center.x + r * CGFloat(sin(angle)), y: center.y - r * CGFloat(cos(angle)))
    }

    func arc(from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = 48
        for i in 0...steps {
            let p = point(cents: start + (end - start) * Double(i) / Double(steps), radius: radius)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Animatable needle line from the pivot towards the current cents value.
struct NeedleShape: Shape {
    var cents: Double
    var animatableData: Double {
        get { cents }
        set { cents = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = GaugeGeometry(rect: rect)
        var path = Path()
        path.move(to: geometry.center)
        path.addLine(to: geometry.point(cents: cents, radius: geometry.radius - 4))
        path.addEllipse(in: CGRect(x: geometry.center.x - 4, y: geometry.center.y - 4, width: 8, height: 8))
        return path
    }
}

/// Shown when microphone access is denied, with a shortcut to the Privacy settings pane.
struct PermissionBlockedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash.fill").font(.system(size: 36)).foregroundStyle(.red)
            Text("Microphone access is blocked").font(.headline)
            Text("PitchNeedleBar needs the microphone to hear your instrument. Audio never leaves your Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 20)
    }
}
