import Foundation

/// One-second summary of a 100 Hz IMU buffer.
public struct MotionSummary: Equatable, Sendable {
    /// Std-dev of acceleration magnitude, g. ~0.002–0.005 g when the arm rests.
    public let movement: Double
    /// Mean angular speed, °/s.
    public let rotation: Double
    /// Acceleration power in the 4–12 Hz physiological-tremor band, summed over the
    /// three axes, mg². Rises with muscle tension; also with any shaking.
    public let tremor: Double
    /// Mean acceleration vector (≈ gravity when still) — wrist orientation.
    public let gravity: SIMD3<Float>
}

public enum MotionAnalyzer {
    public static func summarize(accel: [SIMD3<Float>], gyro: [SIMD3<Float>],
                                 sampleRate: Double = IMUBatch.sampleRate) -> MotionSummary? {
        guard accel.count >= 20 else { return nil }
        let mags = accel.map { Double(($0 * $0).sum().squareRoot()) }
        let movement = Stats.std(mags) ?? 0
        let rotation = gyro.isEmpty ? 0 : gyro.map { Double(($0 * $0).sum().squareRoot()) }.reduce(0, +) / Double(gyro.count)
        // Tremor is measured per axis: shaking perpendicular to gravity barely changes
        // the acceleration magnitude, so a magnitude-only measure would miss it.
        var tremor = 0.0
        for axis in 0..<3 {
            let centred = HRV.detrend(accel.map { Double($0[axis]) * 1000 }) // mg
            var f = 4.0
            while f <= 12 {
                tremor += HRV.power(centred, frequency: f, sampleRate: sampleRate)
                f += 1
            }
        }
        tremor /= Double(accel.count)
        let sum = accel.reduce(SIMD3<Float>(repeating: 0), +)
        return MotionSummary(movement: movement, rotation: rotation, tremor: tremor,
                             gravity: sum / Float(accel.count))
    }
}
