import Foundation

/// What the effort estimates need to know about the wearer.
public struct EffortProfile: Codable, Equatable, Sendable {
    public enum Sex: String, Codable, CaseIterable, Sendable { case male, female }

    public var age: Int = 35
    public var weightKg: Double = 75
    public var sex: Sex = .male

    public init(age: Int = 35, weightKg: Double = 75, sex: Sex = .male) {
        self.age = age; self.weightKg = weightKg; self.sex = sex
    }

    /// Tanaka et al. (2001): 208 − 0.7 × age.
    public var maxHR: Double { 208 - 0.7 * Double(age) }
}

/// Heart-rate zones, calories and a WHOOP-style 0–21 strain estimate. These are textbook
/// formulas, not WHOOP's (proprietary) algorithms.
public enum Effort {
    /// Zone 1–5 by % of max HR (50/60/70/80/90 %); 0 below 50 %.
    public static func zone(hr: Double, maxHR: Double) -> Int {
        let p = hr / maxHR
        switch p {
        case ..<0.5: return 0
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    /// kcal/min from Keytel et al. (2005), floored at 1 MET (≈ 1 kcal per kg per hour): the
    /// HR equation is only meaningful during activity and goes negative at rest.
    public static func kcalPerMinute(hr: Double, profile p: EffortProfile) -> Double {
        let w = p.weightKg, a = Double(p.age)
        let kj: Double
        switch p.sex {
        case .male: kj = -55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a
        case .female: kj = -20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a
        }
        return max(kj / 4.184, w / 60)
    }

    /// Banister TRIMP accumulated over `seconds` at heart rate `hr`.
    public static func trimp(hr: Double, restingHR: Double, profile p: EffortProfile, seconds: Double) -> Double {
        let reserve = p.maxHR - restingHR
        guard reserve > 10 else { return 0 }
        let x = Stats.clamp((hr - restingHR) / reserve, 0, 1)
        let (k, b) = p.sex == .male ? (0.64, 1.92) : (0.86, 1.67)
        return seconds / 60 * x * k * exp(b * x)
    }

    /// Maps TRIMP onto a saturating 0–21 scale: ~45 min at 75 % HR reserve ≈ 11,
    /// an hour at 90 % ≈ 17.
    public static func strain(trimp: Double) -> Double {
        21 * (1 - exp(-max(trimp, 0) / 115))
    }
}
