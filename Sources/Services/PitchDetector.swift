import Accelerate
import Foundation

/// Pure DSP: estimates the fundamental frequency of a mono buffer using the
/// normalized square difference function (McLeod Pitch Method) built on vDSP.
enum PitchDetector {
    /// Lowest and highest frequencies the tuner tries to detect (low B0 bass to high violin harmonics).
    static let minFrequency = 30.0
    static let maxFrequency = 2_000.0

    /// Returns the detected frequency in Hz, or `nil` when no clear periodic peak exists.
    static func detect(_ x: [Float], sampleRate: Double, clarityThreshold: Float = 0.6) -> Double? {
        let n = x.count
        let minLag = max(2, Int(sampleRate / maxFrequency))
        let maxLag = min(n / 2, Int(sampleRate / minFrequency))
        guard n > 0, maxLag > minLag + 2 else { return nil }

        // Cumulative sum of squares lets us compute m'(tau) in O(1) per lag.
        var squares = [Float](repeating: 0, count: n)
        vDSP_vsq(x, 1, &squares, 1, vDSP_Length(n))
        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cumulative[i + 1] = cumulative[i] + Double(squares[i]) }

        var nsdf = [Float](repeating: 0, count: maxLag + 2)
        x.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for tau in 0...(maxLag + 1) {
                let length = n - tau
                var r: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &r, vDSP_Length(length))
                let m = cumulative[length] + (cumulative[n] - cumulative[tau])
                nsdf[tau] = m > 0 ? Float(2 * Double(r) / m) : 0
            }
        }

        // Collect the maximum of every positive lobe after the first negative zero crossing.
        var peaks: [Int] = []
        var tau = 1
        while tau <= maxLag, nsdf[tau] > 0 { tau += 1 }
        while tau <= maxLag {
            while tau <= maxLag, nsdf[tau] <= 0 { tau += 1 }
            var best = -1
            while tau <= maxLag, nsdf[tau] > 0 {
                if best < 0 || nsdf[tau] > nsdf[best] { best = tau }
                tau += 1
            }
            if best >= minLag { peaks.append(best) }
        }
        guard let highest = peaks.map({ nsdf[$0] }).max(), highest >= clarityThreshold else { return nil }

        // Octave-error guard: take the lowest lag whose peak is close to the strongest one.
        guard let chosen = peaks.first(where: { nsdf[$0] >= 0.9 * highest }) else { return nil }

        // Parabolic interpolation for sub-sample accuracy.
        let a = nsdf[chosen - 1], b = nsdf[chosen], c = nsdf[chosen + 1]
        let denominator = a - 2 * b + c
        let shift = abs(denominator) > .ulpOfOne ? 0.5 * (a - c) / denominator : 0
        let period = Double(chosen) + Double(max(-0.5, min(0.5, shift)))
        let frequency = sampleRate / period
        return (minFrequency...maxFrequency).contains(frequency) ? frequency : nil
    }
}

/// Converts between frequencies, MIDI note numbers, note names and cents.
enum NoteMath {
    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    static let referenceRange = 415.0...466.0

    static func clampReference(_ value: Double) -> Double {
        min(max(value, referenceRange.lowerBound), referenceRange.upperBound)
    }

    /// Nearest concert MIDI note and deviation in cents (−50…+50).
    static func reading(frequency: Double, reference: Double) -> (midi: Int, cents: Double) {
        let noteNumber = 12 * log2(frequency / clampReference(reference)) + 69
        let nearest = noteNumber.rounded()
        return (Int(nearest), (noteNumber - nearest) * 100)
    }

    static func frequency(midi: Int, reference: Double) -> Double {
        clampReference(reference) * pow(2, Double(midi - 69) / 12)
    }

    static func name(_ midi: Int) -> String { names[((midi % 12) + 12) % 12] }

    static func octave(_ midi: Int) -> Int { Int((Double(midi) / 12).rounded(.down)) - 1 }
}

/// Transposing-instrument presets: semitones added to concert pitch to get the written note.
enum Transposition: Int, CaseIterable, Identifiable {
    case concert = 0, bFlat = 2, eFlat = 9, f = 7, a = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .concert: return "C (concert)"
        case .bFlat: return "B♭ (trumpet, clarinet)"
        case .eFlat: return "E♭ (alto sax)"
        case .f: return "F (horn)"
        case .a: return "A (clarinet in A)"
        }
    }
}
