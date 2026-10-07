import Foundation
import XCTest
@testable import Smolder

/// Scenario tests for the detectors. The two real incidents that motivated Smolder are encoded here:
/// a background daemon stuck burning one core for hours (must alert), and an ordinary heavy workload
/// that runs hot (must not).
final class DetectionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var config = Config.Detection()

    private func minutes(_ count: Int, start: Date? = nil, power: (Int) -> Double, die: (Int) -> Double, pressure: Int = 0, screenOn: Bool? = nil) -> [MinuteSample] {
        (0..<count).map { i in
            MinuteSample(timestamp: (start ?? t0).addingTimeInterval(Double(i) * 60), dieMax: die(i) + 4, dieAvg: die(i),
                         ssd: 30, battery: 26, power: power(i), cpuCores: nil, thermalState: pressure, expectedDie: nil, screenOn: screenOn)
        }
    }

    private func programs(_ count: Int, usage: [String: Double]) -> [MinuteContext.ProgramMinute] {
        (0..<count).map { i in
            MinuteContext.ProgramMinute(timestamp: t0.addingTimeInterval(Double(i) * 60), cores: usage,
                                        names: usage.keys.reduce(into: [:]) { $0[$1] = ($1 as NSString).lastPathComponent },
                                        pids: usage.keys.reduce(into: [:]) { $0[$1] = 100 })
        }
    }

    // MARK: runaway

    func testIdleDaemonBurningACoreIsFlagged() {
        let detector = RunawayDetector()
        let ctx = MinuteContext(now: t0.addingTimeInterval(1800), minutes: [],
                                programs: programs(30, usage: ["/System/Library/appstoreagent": 1.0]), learning: false, config: config)
        let findings = detector.evaluate(ctx)
        XCTAssertEqual(findings.map(\.key), ["process:/System/Library/appstoreagent"])
    }

    func testNotYetSustainedIsNotFlagged() {
        let detector = RunawayDetector()
        let ctx = MinuteContext(now: t0, minutes: [], programs: programs(20, usage: ["/usr/libexec/daemon": 1.0]), learning: false, config: config)
        XCTAssertTrue(detector.evaluate(ctx).isEmpty)
    }

    func testBusyProgramWithinItsOwnHistoryIsNotFlagged() {
        let detector = RunawayDetector()
        detector.setUsualPeaksForTesting(["/opt/agent/claude": 0.9])
        let ctx = MinuteContext(now: t0, minutes: [], programs: programs(60, usage: ["/opt/agent/claude": 1.1]), learning: false, config: config)
        XCTAssertTrue(detector.evaluate(ctx).isEmpty, "1.1 cores is below 1.5 × its usual 0.9")
    }

    func testIgnoredProgramIsNotFlagged() {
        config.ignoredProcesses = ["appstoreagent"]
        let ctx = MinuteContext(now: t0, minutes: [], programs: programs(30, usage: ["/System/Library/appstoreagent": 1.0]), learning: false, config: config)
        XCTAssertTrue(RunawayDetector().evaluate(ctx).isEmpty)
    }

    func testLearningPeriodUsesConservativeRule() {
        let detector = RunawayDetector()
        let mild = MinuteContext(now: t0, minutes: [], programs: programs(60, usage: ["/bin/x": 0.7]), learning: true, config: config)
        XCTAssertTrue(detector.evaluate(mild).isEmpty)
        let burning = MinuteContext(now: t0, minutes: [], programs: programs(60, usage: ["/bin/x": 0.98]), learning: true, config: config)
        XCTAssertEqual(detector.evaluate(burning).count, 1)
    }

    // MARK: thermal model

    /// Synthetic chip: 30 °C at idle, +4 °C per watt, 3-minute lag, ±0.5 °C noise, with daily heavy work.
    private func syntheticHistory(days: Int) -> [MinuteSample] {
        var smoothed = 0.5
        var rng = SeededRandom(seed: 7)
        return minutes(days * 1440, power: { i in
            let minuteOfDay = i % 1440
            if (600..<720).contains(minuteOfDay) { return 8 }          // two hours of heavy work daily
            if (900..<960).contains(minuteOfDay) { return 3.5 }
            return 0.6
        }, die: { _ in 0 }).map { s in
            var s = s
            smoothed += (1 - exp(-1 / 3.0)) * (s.power! - smoothed)
            s.dieAvg = 30 + 4 * smoothed + rng.next(in: -0.5...0.5)
            return s
        }
    }

    func testThermalFitRecoversPhysics() throws {
        let fit = try XCTUnwrap(ThermalModel.fit(syntheticHistory(days: 4), excluded: [], minimumMinutes: 1000))
        XCTAssertEqual(fit.resistance, 4, accuracy: 0.4)
        XCTAssertEqual(fit.base, 30, accuracy: 1)
        XCTAssertEqual(fit.tau, 3, accuracy: 1)
        XCTAssertLessThan(fit.residualMAD, 0.6)
    }

    func testHeavyLoadRunningHotIsNotFlagged() throws {
        let fit = try XCTUnwrap(ThermalModel.fit(syntheticHistory(days: 4), excluded: [], minimumMinutes: 1000))
        let detector = ThermalDetector(fit: fit)
        // 40 minutes at 8 W: the die sits around 62 °C — hot, but exactly what the load explains.
        let heavy = minutes(40, power: { _ in 8 }, die: { i in 30 + 4 * 8 * (1 - exp(-Double(i + 1) / 3)) })
        var findings: [Finding] = []
        for (i, s) in heavy.enumerated() {
            _ = detector.observe(s)
            findings = detector.evaluate(MinuteContext(now: s.timestamp, minutes: Array(heavy[...i]), programs: [], learning: false, config: config))
        }
        XCTAssertTrue(findings.isEmpty)
    }

    func testHotterThanLoadExplainsIsFlagged() throws {
        let fit = try XCTUnwrap(ThermalModel.fit(syntheticHistory(days: 4), excluded: [], minimumMinutes: 1000))
        let detector = ThermalDetector(fit: fit)
        // Light load (1.5 W, expect ~36 °C) but the die reads 45 °C: cooling is impaired.
        let blocked = minutes(30, power: { _ in 1.5 }, die: { _ in 45 })
        var findings: [Finding] = []
        for (i, s) in blocked.enumerated() {
            _ = detector.observe(s)
            findings = detector.evaluate(MinuteContext(now: s.timestamp, minutes: Array(blocked[...i]), programs: [], learning: false, config: config))
        }
        XCTAssertEqual(findings.map(\.key), ["thermal"])
    }

    func testOutsideLearnedPowerRangeIsNotJudged() throws {
        // Fit only ever saw idle; a sudden 10 W load is beyond what it knows.
        let idleOnly = minutes(3000, power: { _ in 0.6 }, die: { i in 32 + Double(i % 3) * 0.2 })
        let fit = try XCTUnwrap(ThermalModel.fit(idleOnly, excluded: [], minimumMinutes: 1000))
        let detector = ThermalDetector(fit: fit)
        let busy = minutes(30, power: { _ in 10 }, die: { _ in 70 })
        var findings: [Finding] = []
        for (i, s) in busy.enumerated() {
            _ = detector.observe(s)
            findings = detector.evaluate(MinuteContext(now: s.timestamp, minutes: Array(busy[...i]), programs: [], learning: false, config: config))
        }
        XCTAssertTrue(findings.isEmpty)
    }

    func testExcludedIncidentIsNotLearned() throws {
        var history = syntheticHistory(days: 4)
        // Day 3: four hours where cooling was blocked (+10 °C). Excluding it must keep the fit clean.
        let start = 2 * 1440 + 100
        for i in start..<(start + 240) { history[i].dieAvg! += 10 }
        let range = history[start].timestamp...history[start + 239].timestamp
        let all = try XCTUnwrap(ThermalModel.fit(history, excluded: [], minimumMinutes: 1000))
        let clean = try XCTUnwrap(ThermalModel.fit(history, excluded: [range], minimumMinutes: 1000))
        XCTAssertEqual(all.minutes - clean.minutes, 240, "the incident's minutes are left out")
        XCTAssertEqual(clean.base, 30, accuracy: 1)
    }

    // MARK: idle power floor

    func testRaisedIdleFloorIsFlaggedUnlessAlreadyExplained() {
        let detector = PowerFloorDetector()
        detector.setBaselineForTesting(0.5)
        let busy = minutes(120, power: { i in i % 10 == 0 ? 6 : 2.6 }, die: { _ in 40 })
        let ctx = MinuteContext(now: t0, minutes: busy, programs: [], learning: false, config: config)
        XCTAssertEqual(detector.evaluate(ctx, suppress: false).map(\.key), ["power-floor"])
        XCTAssertTrue(detector.evaluate(ctx, suppress: true).isEmpty, "a runaway incident already names the culprit")
        let normalWork = minutes(120, power: { i in i % 4 == 0 ? 0.6 : 7 }, die: { _ in 50 })
        XCTAssertTrue(detector.evaluate(MinuteContext(now: t0, minutes: normalWork, programs: [], learning: false, config: config), suppress: false).isEmpty,
                      "busy work with quiet moments keeps the floor low")
    }

    /// 2026-10-07, the first day after learning: someone opened the lid and watched video for two hours.
    /// The screen alone kept every quiet minute at 7–9 W against a 0.5 W baseline — not background work.
    func testLitScreenIsNotBackgroundWork() {
        let detector = PowerFloorDetector()
        detector.setBaselineForTesting(0.5)
        let watching = minutes(120, power: { i in [7.6, 8.8, 9.5, 12.1, 17.8][i % 5] }, die: { _ in 36 }, screenOn: true)
        let ctx = MinuteContext(now: t0, minutes: watching, programs: [], learning: false, config: config)
        XCTAssertFalse(detector.canJudge(ctx))
        XCTAssertTrue(detector.evaluate(ctx, suppress: false).isEmpty)

        // Lid closed after an hour: still too few screen-off minutes to judge.
        let mixed = Array(watching.prefix(60)) + minutes(60, start: t0.addingTimeInterval(3600), power: { _ in 2.6 }, die: { _ in 30 }, screenOn: false)
        XCTAssertFalse(detector.canJudge(MinuteContext(now: t0, minutes: mixed, programs: [], learning: false, config: config)))

        // The same raised floor with every screen off is exactly what the rule is for.
        let dark = minutes(120, power: { _ in 2.6 }, die: { _ in 30 }, screenOn: false)
        XCTAssertEqual(detector.evaluate(MinuteContext(now: t0, minutes: dark, programs: [], learning: false, config: config), suppress: false).map(\.key),
                       [PowerFloorDetector.key])
    }

    func testFloorBaselineIgnoresScreenOnMinutes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        // 26 hours with every screen off at 0.5 W, then two days of use at 4 W with the screen on:
        // most hours are screen-on, so counting them would put the baseline at 4 W.
        for s in minutes(26 * 60, power: { _ in 0.5 }, die: { _ in 30 }, screenOn: false) { store.append(s) }
        for s in minutes(48 * 60, start: t0.addingTimeInterval(26 * 3600), power: { _ in 4 }, die: { _ in 40 }, screenOn: true) { store.append(s) }
        XCTAssertEqual(store.samples(since: t0).map(\.screenOn).filter { $0 == true }.count, 48 * 60, "screen state survives storage")
        let detector = PowerFloorDetector()
        detector.refreshBaseline(store: store, excluded: [], config: config, now: t0.addingTimeInterval(74 * 3600))
        XCTAssertEqual(try XCTUnwrap(detector.baselineFloor), 0.5, accuracy: 0.01)
    }

    // MARK: hard limits

    func testThrottlingMustLastTheFullWindow() {
        let nine = minutes(9, power: { _ in 8 }, die: { _ in 90 }, pressure: PressureLevel.heavy.rawValue)
        XCTAssertTrue(HardLimitDetector.evaluate(MinuteContext(now: t0, minutes: nine, programs: [], learning: true, config: config)).isEmpty)
        let ten = minutes(10, power: { _ in 8 }, die: { _ in 90 }, pressure: PressureLevel.heavy.rawValue)
        XCTAssertEqual(HardLimitDetector.evaluate(MinuteContext(now: t0, minutes: ten, programs: [], learning: true, config: config)).map(\.key), ["pressure"])
    }

    // MARK: incidents

    func testIncidentNotifiesOnceAndRecovers() {
        let tracker = IncidentTracker(open: [], history: [])
        let finding = Finding(key: "process:/x", kind: .runawayProcess, severity: .warning, title: "x", lines: [])
        var events: [SmolderEvent] = []
        for m in 0..<45 { events += tracker.update(findings: [finding], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true) }
        XCTAssertEqual(events.count, 1, "one notification for a 45-minute incident")
        for m in 45..<59 { events += tracker.update(findings: [], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true) }
        XCTAssertEqual(events.count, 1, "not resolved before 15 normal minutes")
        events += tracker.update(findings: [], now: t0.addingTimeInterval(59 * 60), clearMinutes: 15, notifyRecoveries: true)
        XCTAssertEqual(events.last?.kind, .recovered)
        XCTAssertTrue(tracker.open.isEmpty)
        XCTAssertEqual(tracker.excludedRanges.count, 1)
    }

    func testUnjudgedMinutesDoNotResolveAnIncident() {
        let tracker = IncidentTracker(open: [], history: [])
        let finding = Finding(key: PowerFloorDetector.key, kind: .runawayProcess, severity: .warning, title: "f", lines: [])
        _ = tracker.update(findings: [finding], now: t0, clearMinutes: 15, notifyRecoveries: true)
        var events: [SmolderEvent] = []
        for m in 1...60 {
            events += tracker.update(findings: [], held: [PowerFloorDetector.key], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true)
        }
        XCTAssertTrue(events.isEmpty, "an hour with the screen on is not an hour of normal")
        XCTAssertEqual(tracker.open[PowerFloorDetector.key]?.normalStreak, 0)
        for m in 61...75 { events += tracker.update(findings: [], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true) }
        XCTAssertEqual(events.map(\.kind), [.recovered])
    }

    func testBlipResetsRecoveryCountdown() {
        let tracker = IncidentTracker(open: [], history: [])
        let finding = Finding(key: "thermal", kind: .thermalAnomaly, severity: .warning, title: "t", lines: [])
        _ = tracker.update(findings: [finding], now: t0, clearMinutes: 15, notifyRecoveries: true)
        for m in 1..<10 { _ = tracker.update(findings: [], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true) }
        _ = tracker.update(findings: [finding], now: t0.addingTimeInterval(600), clearMinutes: 15, notifyRecoveries: true)
        for m in 11..<20 { _ = tracker.update(findings: [], now: t0.addingTimeInterval(Double(m) * 60), clearMinutes: 15, notifyRecoveries: true) }
        XCTAssertEqual(tracker.open.count, 1)
    }

    func testCPUTimeParsing() {
        XCTAssertEqual(ProcessSampler.parseCPUTime("192:46.54")!, 11566.54, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.parseCPUTime("1:02:03")!, 3723, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.parseCPUTime("2-01:00:00")!, 176400, accuracy: 0.001)
        XCTAssertNil(ProcessSampler.parseCPUTime("abc"))
    }
}

/// Deterministic noise so the scenarios are reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
