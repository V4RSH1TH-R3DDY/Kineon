// Synthetic accelerometer windows in g, a Swift port of backend/tests/synth.py.
// For simulators (which have no motion sensor) and tests only. Anything built from it must be labelled
// "Simulated signal" on screen so it can never pass as a real recording in a demo.
import Foundation

public enum SyntheticSignal {
    public static let sampleRate = 50.0

    /// Same parameters as `synth.window`: a tremor sine, a 1.8 Hz walking sway, Gaussian noise, gravity on z.
    public static func samples(seconds: Double = 10, tremorHz: Double? = nil, tremorAmp: Double = 0,
                               noise: Double = 0.005, walkAmp: Double = 0, seed: UInt64 = 0) -> [Vec3] {
        var rng = SplitMix64(seed: seed)
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            var x = rng.gaussian(sd: noise), y = rng.gaussian(sd: noise), z = 1.0 + rng.gaussian(sd: noise)
            if let hz = tremorHz {
                let s = tremorAmp * sin(2 * .pi * hz * t)
                x += s; y += 0.6 * s; z += 0.4 * s
            }
            if walkAmp > 0 {
                let s = walkAmp * sin(2 * .pi * 1.8 * t)
                x += 0.5 * s; y += 0.3 * s; z += s
            }
            return Vec3(x, y, z)
        }
    }

    /// Gait, as `synth.walking`: a 1.8 Hz fundamental plus harmonics that land inside the 3-12 Hz tremor band.
    /// The scorer should withhold this as voluntary movement.
    public static func walking(seconds: Double = 10, hz: Double = 1.8, amp: Double = 0.4, seed: UInt64 = 0) -> [Vec3] {
        var rng = SplitMix64(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            var s = 0.0
            for (k, w) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.3)] { s += amp * w * sin(2 * .pi * k * hz * t) }
            return Vec3(0.5 * s + rng.gaussian(sd: 0.01), 0.3 * s + rng.gaussian(sd: 0.01), 1 + s + rng.gaussian(sd: 0.01))
        }
    }

    public static func window(patientId: String, startedAt: Date = Date(), source: Source = .watch,
                              seconds: Double = 10, tremorHz: Double? = nil, tremorAmp: Double = 0,
                              walkAmp: Double = 0, seed: UInt64 = 0) -> MotionWindow {
        MotionWindow(patientId: patientId, startedAt: startedAt, sampleRateHz: sampleRate,
                     accel: samples(seconds: seconds, tremorHz: tremorHz, tremorAmp: tremorAmp, walkAmp: walkAmp, seed: seed),
                     source: source)
    }
}

/// Small seeded generator so synthetic windows repeat exactly.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Box-Muller.
    mutating func gaussian(sd: Double) -> Double {
        let u1 = max(uniform(), .leastNonzeroMagnitude), u2 = uniform()
        return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
