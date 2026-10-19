import Accelerate
import AVFoundation
import Combine

/// Microphone authorization state as seen by the UI.
enum MicPermission {
    case unknown, granted, denied
}

/// UserDefaults keys shared by `@AppStorage` views and the engine.
enum SettingsKey {
    static let deviceUID = "inputDeviceUID"
    static let sensitivity = "gateSensitivity"
    static let listenOnlyWhileOpen = "listenOnlyWhileOpen"
    static let referencePitch = "referencePitch"
    static let transposition = "transposition"
    static let toneNote = "toneNote"
}

/// Owns the capture `AVAudioEngine`, device selection, permissions, hold and the reference tone.
/// Publishes the median-filtered fundamental frequency for the UI.
final class TunerEngine: ObservableObject {
    static let shared = TunerEngine()

    @Published private(set) var frequency: Double?
    @Published private(set) var permission: MicPermission = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var notice: String?
    @Published private(set) var devices: [AudioDevices.Device] = []
    @Published private(set) var isTonePlaying = false
    @Published private(set) var micPausedForTone = false
    @Published var isHeld = false

    private var engine: AVAudioEngine?
    private let analyzer = PitchAnalyzer()
    private let tone = ToneGenerator()
    private var popoverVisible = false
    private var noticeClear: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            SettingsKey.sensitivity: 0.5,
            SettingsKey.listenOnlyWhileOpen: true,
            SettingsKey.referencePitch: 440.0,
            SettingsKey.toneNote: 69,
        ])
        analyzer.onResult = { [weak self] value in
            DispatchQueue.main.async { self?.receive(value) }
        }
        refreshDevices()
        AudioDevices.observeDeviceChanges { [weak self] in self?.devicesChanged() }
        updatePermission()
    }

    var listenOnlyWhileOpen: Bool { defaults.bool(forKey: SettingsKey.listenOnlyWhileOpen) }

    // MARK: - Lifecycle

    /// Called at launch: listen continuously if the user disabled "only while open".
    func appLaunched() {
        if !listenOnlyWhileOpen, permission == .granted { start() }
    }

    func popoverOpened() {
        popoverVisible = true
        updatePermission()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permission = granted ? .granted : .denied
                    if granted, self.popoverVisible || !self.listenOnlyWhileOpen { self.start() }
                }
            }
        default:
            permission = .denied
        }
    }

    func popoverClosed() {
        popoverVisible = false
        if listenOnlyWhileOpen {
            stop()
            stopTone()
        }
    }

    /// Re-evaluates whether the engine should run after the listening preference changes.
    func listeningPreferenceChanged() {
        if listenOnlyWhileOpen, !popoverVisible { stop() } else if permission == .granted { start() }
    }

    func start() {
        guard permission == .granted, engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = defaults.string(forKey: SettingsKey.deviceUID) ?? ""
        if !uid.isEmpty {
            if var deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            } else {
                defaults.set("", forKey: SettingsKey.deviceUID)
                post("Selected microphone is unavailable — using the system default.")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            post("No microphone input is available.")
            return
        }
        analyzer.configure(sampleRate: format.sampleRate)
        analyzer.gateDB = Self.gate(for: defaults.double(forKey: SettingsKey.sensitivity))
        let analyzer = self.analyzer
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(analyzer.windowSize), format: format) { buffer, _ in
            analyzer.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            post("Could not start the microphone: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        isRunning = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restart() }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        if !isHeld { frequency = nil }
    }

    func restart() {
        guard engine != nil else { return }
        stop()
        start()
    }

    func setSensitivity(_ value: Double) {
        analyzer.gateDB = Self.gate(for: value)
    }

    /// Maps sensitivity 0…1 to an RMS gate between −30 dBFS (least) and −70 dBFS (most sensitive).
    static func gate(for sensitivity: Double) -> Float {
        Float(-30 - 40 * min(max(sensitivity, 0), 1))
    }

    // MARK: - Reference tone

    func toggleTone(hz: Double) {
        if isTonePlaying { stopTone(); return }
        do {
            try tone.start(frequency: hz)
            isTonePlaying = true
            // Avoid the tuner hearing its own tone through the speakers.
            micPausedForTone = AudioDevices.outputIsBuiltInSpeaker()
            analyzer.muted = micPausedForTone
            if micPausedForTone, !isHeld { frequency = nil }
        } catch {
            post("Could not play the reference tone: \(error.localizedDescription)")
        }
    }

    func updateTone(hz: Double) {
        if isTonePlaying { tone.frequency = hz }
    }

    func stopTone() {
        tone.stop()
        isTonePlaying = false
        micPausedForTone = false
        analyzer.muted = false
    }

    // MARK: - Private

    private func receive(_ value: Double?) {
        guard !isHeld else { return }
        frequency = value
    }

    private func updatePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .notDetermined: permission = .unknown
        default: permission = .denied
        }
    }

    private func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    private func devicesChanged() {
        refreshDevices()
        let uid = defaults.string(forKey: SettingsKey.deviceUID) ?? ""
        if !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
            defaults.set("", forKey: SettingsKey.deviceUID)
            post("Microphone disconnected — switched to the system default.")
        }
        restart()
    }

    private func post(_ message: String) {
        notice = message
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

/// Runs on the audio tap thread: buffers samples into analysis windows, applies the RMS gate,
/// detects pitch and smooths results with a five-reading median filter.
final class PitchAnalyzer {
    var gateDB: Float = -50
    var muted = false
    var onResult: ((Double?) -> Void)?
    private(set) var windowSize = 4096
    private var sampleRate = 44_100.0
    private var samples: [Float] = []
    private var history: [Double] = []
    private var misses = 0

    /// Sizes the window proportionally to the sample rate (4096 at 44.1/48 kHz), as a power of two.
    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        let scaled = 4096 * max(1, sampleRate / 48_000)
        var size = 2048
        while Double(size) < scaled * 0.75, size < 16_384 { size *= 2 }
        windowSize = size
        samples.removeAll(keepingCapacity: true)
        history.removeAll()
        misses = 0
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        while samples.count >= windowSize {
            analyze(Array(samples[0..<windowSize]))
            samples.removeFirst(windowSize / 2)
        }
    }

    private func analyze(_ window: [Float]) {
        var rms: Float = 0
        vDSP_rmsqv(window, 1, &rms, vDSP_Length(window.count))
        let level = 20 * log10(max(rms, 1e-9))
        guard !muted, level >= gateDB,
              let detected = PitchDetector.detect(window, sampleRate: sampleRate) else {
            misses += 1
            if misses == 4 {
                history.removeAll()
                onResult?(nil)
            }
            return
        }
        misses = 0
        history.append(detected)
        if history.count > 5 { history.removeFirst() }
        let sorted = history.sorted()
        onResult?(sorted[sorted.count / 2])
    }
}
