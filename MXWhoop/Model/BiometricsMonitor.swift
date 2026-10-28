import Foundation
import Observation
import WhoopKit

/// Skin temperature, steps and the strap's own state, taken from the one-second summary
/// records (layout 18) the strap stores in its history.
///
/// WHOOP 5/MG firmware has no command that returns the temperature directly: it only
/// lands in these stored records. They reach the phone in three read-only ways:
///  • **Passive** — whenever the official WHOOP app on this iPhone syncs, the records flow
///    over the shared Bluetooth link and every subscribed app receives them.
///  • **Fast sync** — ENTER_HIGH_FREQ_SYNC makes the strap prompt the WHOOP app to sync
///    every ~61 s (WHOOP's own mechanism). The WHOOP app stores and acknowledges as usual.
///  • **Peek** — SEND_HISTORICAL_DATA without ever acknowledging: the strap shows the first
///    stored chunk after the last sync and keeps everything.
/// The history acknowledgement that lets the strap delete data is never sent.
@Observable
final class BiometricsMonitor {
    enum Source: String { case sync = "WHOOP app sync", memory = "strap memory" }

    struct Reading: Equatable {
        let celsius: Double
        let measuredAt: Date
        let source: Source
    }

    enum FastSync: Equatable {
        case off
        case requested
        /// `ours`: the strap reported the session started by our request, so we may end it.
        case on(ours: Bool)
        case refused
    }

    enum Peek: Equatable {
        case idle
        case reading
        case done(records: Int)
        case unavailable(String)
    }

    private(set) var skinTemp: Reading?
    private(set) var auxTemps: (Double?, Double?) = (nil, nil)
    /// Skin temperature by measurement time (reference-date seconds), ≥ 10 s apart.
    private(set) var series: [TimedValue] = []
    private(set) var latest: BiometricRecord?
    private(set) var stepsSeen: Int?
    private(set) var recordsSeen = 0
    private(set) var lastSyncTraffic: Date?
    /// A history sync this app didn't start (the WHOOP app's) has been seen this session.
    private(set) var syncByOthersSeen = false
    private(set) var dataRange: DataRange?
    private(set) var dataRangeAt: Date?
    private(set) var fastSync: FastSync = .off
    private(set) var peek: Peek = .idle
    /// Last 24 h of archived summaries, one point per minute.
    private(set) var dayBins: [MinuteBin] = []
    /// Set by the hub whenever a response to another app's command is seen.
    var whoopAppLastSeen: Date?
    let archive = StrapArchive()

    var fastSyncWanted: Bool {
        didSet {
            UserDefaults.standard.set(fastSyncWanted, forKey: Self.fastSyncKey)
            fastSyncWanted ? startFastSync() : stopFastSync()
        }
    }

    @ObservationIgnored var send: ((CommandBody.Request) -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored var recorder: Recorder?
    @ObservationIgnored private var streaming = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var enterSentAt: Date?
    @ObservationIgnored private var lastEnterAt: Date = .distantPast
    @ObservationIgnored private var peekStartedAt: Date?
    @ObservationIgnored private var peekRecords = 0
    @ObservationIgnored private var lastRangeRequest: Date = .distantPast
    @ObservationIgnored private var seenIndices = Set<UInt32>()
    @ObservationIgnored private var firstSteps: UInt16?
    @ObservationIgnored private var lastSteps: UInt16?
    @ObservationIgnored private var stepTotal = 0
    /// Another app (the WHOOP app) asked for high-frequency sync too: never end it.
    @ObservationIgnored private var foreignFastSync = false
    @ObservationIgnored private var binsDirty = false
    @ObservationIgnored private var lastBinRebuild: Date = .distantPast

    private static let fastSyncKey = "fastSyncWanted"
    static let fastSyncInterval = 61
    /// Each request runs at most 30 min; while wanted it is renewed (after expiry) every 5 min.
    static let fastSyncDuration = 1800
    static let seriesSpan: Double = 6 * 3600

    init() {
        fastSyncWanted = UserDefaults.standard.object(forKey: Self.fastSyncKey) as? Bool ?? true
        archive.load { [weak self] in self?.rebuildBins() }
    }

    // MARK: Lifecycle (called by SensorHub)

    func reset() {
        skinTemp = nil; auxTemps = (nil, nil); series = []; latest = nil
        stepsSeen = nil; recordsSeen = 0; lastSyncTraffic = nil; dataRange = nil; dataRangeAt = nil
        fastSync = .off; peek = .idle; whoopAppLastSeen = nil; syncByOthersSeen = false
        seenIndices.removeAll(); firstSteps = nil; lastSteps = nil; stepTotal = 0
        streaming = false; enterSentAt = nil; peekStartedAt = nil; foreignFastSync = false
    }

    func rebuildBins() {
        dayBins = archive.recentBins()
        binsDirty = false
        lastBinRebuild = Date()
    }

    func sessionStarted() {
        streaming = true
        requestDataRange(force: true)
        if fastSyncWanted && appActive { startFastSync() }
    }

    func linkLost() {
        streaming = false
        if peek == .reading { peek = .idle }
        peekStartedAt = nil
        // The strap ends a fast-sync session on its own when its duration runs out.
        if case .on = fastSync { fastSync = .off }
        if fastSync == .requested { fastSync = .off }
    }

    /// Before a user-initiated disconnect, while commands can still be sent.
    func willDisconnect() { stopFastSync() }

    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        if active {
            if fastSyncWanted { startFastSync() }
            requestDataRange()
        } else {
            // Don't keep the WHOOP app syncing every minute while nobody is looking.
            stopFastSync()
        }
    }

    func tick() {
        let now = Date()
        if fastSyncWanted, appActive, streaming, fastSync != .refused, now.timeIntervalSince(lastEnterAt) > 300 {
            // Entering while a session is active changes nothing, so this only restarts
            // one that expired.
            sendEnter()
        }
        if peek == .reading, let started = peekStartedAt, now.timeIntervalSince(started) > 12 {
            finishPeek()
        }
        if binsDirty, now.timeIntervalSince(lastBinRebuild) > 5 { rebuildBins() }
    }

    // MARK: Frames

    func ingest(_ r: BiometricRecord) {
        lastSyncTraffic = Date()
        if peek == .reading { peekRecords += 1 }
        guard seenIndices.insert(r.recordIndex).inserted else { return }
        if seenIndices.count > 50_000 { seenIndices.removeAll() }
        recordsSeen += 1
        archive.append(r)
        binsDirty = true

        let measured = Date(timeIntervalSince1970: TimeInterval(r.unixTime))
        let source: Source = peek == .reading ? .memory : .sync
        recorder?.biometric(r, source: source.rawValue)

        // Older than what we already have (e.g. a peek behind a sync): history only.
        guard measured >= (latest.map { Date(timeIntervalSince1970: TimeInterval($0.unixTime)) } ?? .distantPast) else {
            if let c = r.skinTempC { insert(TimedValue(t: measured.timeIntervalSinceReferenceDate, v: c)) }
            return
        }
        trackSteps(r.steps)
        latest = r
        auxTemps = (r.auxTemp1C, r.auxTemp2C)
        if let c = r.skinTempC {
            skinTemp = Reading(celsius: c, measuredAt: measured, source: source)
            insert(TimedValue(t: measured.timeIntervalSinceReferenceDate, v: c))
        }
    }

    func handleMarker(_ kind: UInt8) {
        lastSyncTraffic = Date()
        if peek != .reading { syncByOthersSeen = true }
        guard let marker = HistoryMarker(rawValue: kind) else { return }
        if peek == .reading, marker == .end || marker == .complete {
            finishPeek()
        } else if marker == .complete {
            // A sync just finished; the backlog changed.
            requestDataRange()
        }
    }

    func handleEvent(_ e: StrapEvent) {
        switch e.number {
        case StrapEvent.highFreqSyncEnabled:
            let ours = enterSentAt.map { Date().timeIntervalSince($0) < 5 } ?? false
            fastSync = .on(ours: ours)
            log?("High-frequency sync on\(ours ? "" : " (started by another app)")")
        case StrapEvent.highFreqSyncDisabled:
            fastSync = .off
        case StrapEvent.highFreqSyncPrompt:
            if fastSync == .off || fastSync == .requested { fastSync = .on(ours: false) }
        default:
            break
        }
    }

    /// `ours`: the response answers a command this app sent (otherwise the WHOOP app's).
    func handleResponse(_ r: CommandResponse, ours: Bool) {
        if let range = WhoopParser.dataRange(r) {
            dataRange = range
            dataRangeAt = Date()
        }
        if !ours {
            if r.command == WhoopCommand.enterHighFreqSync.rawValue, r.result == .success {
                foreignFastSync = true
                fastSync = .on(ours: false)
            } else if r.command == WhoopCommand.exitHighFreqSync.rawValue {
                foreignFastSync = false
            }
            return
        }
        if r.command == WhoopCommand.enterHighFreqSync.rawValue, let result = r.result {
            switch result {
            case .failure, .unsupported:
                fastSync = .refused
                log?("Strap refused ENTER_HIGH_FREQ_SYNC (result \(r.resultRaw))")
            case .success:
                // Already active (no "enabled" event): someone else's session is running.
                if fastSync == .requested { fastSync = .on(ours: false) }
            case .pending:
                break
            }
        }
    }

    // MARK: Actions

    /// Reads the oldest not-yet-synced chunk straight from the strap's memory, without
    /// acknowledging it.
    func readStrapMemory() {
        guard streaming else { peek = .unavailable("Connect the strap first."); return }
        guard peek != .reading else { return }
        // Only when the WHOOP app is not around: while it syncs, its records arrive here
        // anyway, and a parallel history request could interrupt its sync (it would retry).
        let recentSync = lastSyncTraffic.map { Date().timeIntervalSince($0) < 300 } ?? false
        let recentApp = whoopAppLastSeen.map { Date().timeIntervalSince($0) < 120 } ?? false
        if recentSync || recentApp {
            peek = .unavailable("Not needed: the WHOOP app is active and its syncs already bring the records here. Reading memory directly is only allowed when the WHOOP app has been quiet for 5 minutes, so it never interrupts its sync.")
            return
        }
        peek = .reading
        peekStartedAt = Date()
        peekRecords = 0
        send?(CommandBody.dataRange)
        send?(CommandBody.sendHistory)
    }

    func requestDataRange(force: Bool = false) {
        guard streaming, force || Date().timeIntervalSince(lastRangeRequest) > 30 else { return }
        lastRangeRequest = Date()
        send?(CommandBody.dataRange)
    }

    // MARK: Private

    private func startFastSync() {
        guard streaming, appActive else { return }
        if case .on = fastSync { return }
        fastSync = .requested
        sendEnter()
    }

    private func sendEnter() {
        enterSentAt = Date()
        lastEnterAt = Date()
        send?(CommandBody.enterHighFreqSync(interval: Self.fastSyncInterval, duration: Self.fastSyncDuration))
    }

    /// Ends only a session we started, never one the WHOOP app is running for itself.
    private func stopFastSync() {
        if case .on(ours: true) = fastSync, streaming, !foreignFastSync {
            send?(CommandBody.exitHighFreqSync)
        }
        if fastSync != .refused { fastSync = .off }
    }

    private func finishPeek() {
        // Close the attempt without acknowledging anything; the next sync starts from the same place.
        send?(CommandBody.abortHistory)
        peek = .done(records: peekRecords)
        peekStartedAt = nil
        requestDataRange(force: true)
    }

    private func trackSteps(_ counter: UInt16) {
        if let last = lastSteps {
            let delta = Int(counter &- last)
            // Ignore jumps that look like a counter reset or records from another day.
            if delta < 5_000 { stepTotal += delta }
        }
        lastSteps = counter
        if firstSteps == nil { firstSteps = counter }
        stepsSeen = stepTotal
    }

    private func insert(_ p: TimedValue) {
        if let last = series.last, p.t >= last.t {
            guard p.t - last.t >= 10 else { return }
            series.append(p)
        } else {
            let i = series.firstIndex { $0.t > p.t } ?? series.count
            let tooClose = (i > 0 && p.t - series[i - 1].t < 10) || (i < series.count && series[i].t - p.t < 10)
            guard !tooClose else { return }
            series.insert(p, at: i)
        }
        if let newest = series.last?.t { series.trim(before: newest - Self.seriesSpan) }
    }
}
