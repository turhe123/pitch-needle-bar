import AVFoundation

/// Plays a reference sine wave through its own `AVAudioEngine` using an `AVAudioSourceNode`.
final class ToneGenerator {
    /// Render-thread state, shared by reference with the source node's render block.
    private final class State {
        var frequency: Double = 440
        var phase: Double = 0
        var amplitude: Double = 0
        var targetAmplitude: Double = 0
    }

    private let state = State()
    private var engine: AVAudioEngine?

    var frequency: Double {
        get { state.frequency }
        set { state.frequency = newValue }
    }

    var isPlaying: Bool { engine?.isRunning == true }

    func start(frequency: Double) throws {
        stop()
        state.frequency = frequency
        state.amplitude = 0
        state.targetAmplitude = 0.25
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = sampleRate > 0 ? sampleRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let state = self.state
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let increment = 2 * Double.pi * state.frequency / rate
            for frame in 0..<Int(frameCount) {
                // Short linear ramp avoids clicks when starting.
                state.amplitude += (state.targetAmplitude - state.amplitude) * 0.002
                let sample = Float(sin(state.phase) * state.amplitude)
                state.phase += increment
                if state.phase >= 2 * Double.pi { state.phase -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
