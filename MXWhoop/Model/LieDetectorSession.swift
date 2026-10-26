import Foundation
import Observation
import WhoopKit

/// Drives the lie-detector screen:
///
///  1. Baseline (60 s at rest) → how much your signals wobble when nothing happens.
///  2. Calibration: 3 truthful + 3 deliberately false statements, prompted by the app.
///  3. Interrogation: the operator asks anything, taps ASK when done asking, and ~16 s
///     later the model compares your reaction with your own truthful/lying reactions.
///
/// Each question needs a clean 10 s pre-window, so the session enforces a short settle
/// period between questions.
@Observable
final class LieDetectorSession {
    struct CalibrationStep {
        let instruction: String
        let say: String
        let deceptive: Bool
    }

    struct QuestionResult: Identifiable {
        let id = UUID()
        let question: String
        let date: Date
        let verdict: Verdict
        /// Demo mode only: what the virtual subject actually did.
        let demoWasLie: Bool?
    }

    enum Phase: Equatable {
        case intro
        case baseline(start: Date, end: Date)
        case calibrationSettle(step: Int, until: Date)
        case calibrationListen(step: Int, start: Date, until: Date)
        case ready
        case listening(start: Date, until: Date)
        case settling(until: Date)
    }

    enum DemoAnswer: String, CaseIterable, Identifiable {
        case truth = "Truth", lie = "Lie", random = "Random"
        var id: String { rawValue }
    }

    static let script: [CalibrationStep] = [
        .init(instruction: "Tell the TRUTH", say: "Say your real first name out loud.", deceptive: false),
        .init(instruction: "LIE on purpose", say: "Say out loud: “My name is Gandalf.”", deceptive: true),
        .init(instruction: "Tell the TRUTH", say: "Say out loud which city you are in right now.", deceptive: false),
        .init(instruction: "LIE on purpose", say: "Say out loud: “I am in Antarctica right now.”", deceptive: true),
        .init(instruction: "Tell the TRUTH", say: "Say out loud what you ate at your last meal.", deceptive: false),
        .init(instruction: "LIE on purpose", say: "Say out loud: “I have never told a lie in my life.”", deceptive: true),
    ]

    let config = LieDetectorConfig()
    private(set) var phase: Phase = .intro
    private(set) var model: LieModel?
    private(set) var history: [QuestionResult] = []
    private(set) var latest: QuestionResult?
    private(set) var calibrationDone: [Bool] = []   // per completed step: usable?
    /// Incremented on every phase change — drives haptics in the view.
    private(set) var transitions = 0
    var questionText = ""
    var demoAnswer: DemoAnswer = .random
    var settleTime: Double = 10

    private let hub: SensorHub
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var imuWasEnabled = false
    @ObservationIgnored private var pendingQuestion = ""
    @ObservationIgnored private var pendingDemoLie: Bool?

    init(hub: SensorHub) { self.hub = hub }

    var isActive: Bool { phase != .intro }
    var tier: LieModel.Tier? { model?.tier }

    /// Why Start is disabled, if it is.
    var blocker: String? {
        if !hub.linkState.isConnected { return "Connect your strap (or start Demo mode) first." }
        if !hub.hasLiveHeartRate { return "Waiting for live heart rate from the strap…" }
        return nil
    }

    // MARK: Controls

    func start(calibrate: Bool = true) {
        guard blocker == nil else { return }
        imuWasEnabled = hub.imuEnabled
        hub.setIMU(true)
        history = []; latest = nil; calibrationDone = []
        let now = Date()
        model = nil
        setPhase(.baseline(start: now, end: now.addingTimeInterval(config.baselineDuration)))
        skipCalibrationAfterBaseline = !calibrate
        startTimer()
    }

    func skipCalibration() {
        switch phase {
        case .calibrationSettle, .calibrationListen: setPhase(.ready)
        default: break
        }
    }

    /// The operator has just finished asking the question.
    func ask() {
        guard phase == .ready, model != nil else { return }
        let start = Date()
        pendingQuestion = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        questionText = ""
        if hub.isDemo {
            let lie = demoAnswer == .random ? Bool.random() : demoAnswer == .lie
            pendingDemoLie = lie
            hub.demoAsk(deceptive: lie)
        } else {
            pendingDemoLie = nil
        }
        setPhase(.listening(start: start, until: start.addingTimeInterval(config.evaluationDelay)))
    }

    func reset() {
        timer?.invalidate(); timer = nil
        if isActive { hub.setIMU(imuWasEnabled) }
        hub.noiseProfile = nil
        model = nil; latest = nil
        setPhase(.intro)
    }

    // MARK: State machine

    @ObservationIgnored private var skipCalibrationAfterBaseline = false

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let now = Date()
        switch phase {
        case .baseline(let start, let end) where now >= end:
            let noise = LieDetector.noiseProfile(from: hub.timeline, restFrom: ref(start), to: ref(end), config: config)
            model = LieModel(noise: noise)
            hub.noiseProfile = noise
            if skipCalibrationAfterBaseline {
                setPhase(.ready)
            } else {
                setPhase(.calibrationSettle(step: 0, until: now.addingTimeInterval(config.preWindow)))
            }

        case .calibrationSettle(let step, let until) where now >= until:
            if hub.isDemo { hub.demoAsk(deceptive: Self.script[step].deceptive) }
            setPhase(.calibrationListen(step: step, start: now, until: now.addingTimeInterval(config.evaluationDelay)))

        case .calibrationListen(let step, let start, let until) where now >= until:
            let f = LieDetector.features(from: hub.timeline, questionAt: ref(start), config: config)
            if Self.script[step].deceptive { model?.lies.append(f) } else { model?.truths.append(f) }
            calibrationDone.append(f.isUsable)
            let next = step + 1
            if next < Self.script.count {
                setPhase(.calibrationSettle(step: next, until: now.addingTimeInterval(settleTime)))
            } else {
                setPhase(.ready)
            }

        case .listening(let start, let until) where now >= until:
            guard let model else { setPhase(.ready); return }
            let f = LieDetector.features(from: hub.timeline, questionAt: ref(start), config: config)
            let verdict = model.verdict(for: f)
            let result = QuestionResult(question: pendingQuestion.isEmpty ? "Question \(history.count + 1)" : pendingQuestion,
                                        date: start, verdict: verdict, demoWasLie: pendingDemoLie)
            latest = result
            history.insert(result, at: 0)
            if verdict.kind == .lie && hub.buzzOnLie { hub.buzz(pulses: 2) }
            setPhase(.settling(until: now.addingTimeInterval(settleTime)))

        case .settling(let until) where now >= until:
            setPhase(.ready)

        default:
            break
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        transitions += 1
    }

    /// Timeline time base (see SensorHub.now).
    private func ref(_ d: Date) -> Double { d.timeIntervalSinceReferenceDate }
}
