import Foundation
import Combine

/// What the menu bar, the panel, heartbeats and `/status` show.
struct LiveState {
    var dieMax: Double?
    var dieAvg: Double?
    var ssd: Double?
    var battery: Double?
    var power: Double?
    var cpuCores: Double?
    var pressure: PressureLevel = .nominal
    var expectedDie: Double?
    var band: Double?
    var learning = true
    var learningProgress: Double = 0
    var topProcesses: [ProcessUsage] = []
    var openIncidents: [Incident] = []
    var recentIncidents: [Incident] = []
    var fit: ThermalFit?
    var deliveryErrors: [String: String] = [:]
    var pendingDeliveries = 0
    var lastHeartbeat: Date?
    var heartbeatError: String?
    var telegramPollError: String?
}

/// Persisted between launches.
private struct PersistedState: Codable {
    var openIncidents: [Incident] = []
    var history: [Incident] = []
    var fit: ThermalFit?
    var referenceFit: ThermalFit?
    var lastDriftNotice: Date?
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var live = LiveState()
    @Published private(set) var chart: [MinuteSample] = []
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            ConfigStore.save(config)
            Localization.shared.apply(languageCode: config.general.language)
            reconfigureNotifiers()
        }
    }

    let store: HistoryStore
    private let hid = HIDTemperature()
    private let smc = SMC()
    private let cpu = CPULoad()
    private let pressure = ThermalPressure()
    private let processes = ProcessSampler()
    private let outbox = Outbox(url: Paths.outbox)
    private let bot = TelegramBot()

    private let runaway = RunawayDetector()
    private let powerFloor = PowerFloorDetector()
    private let thermal: ThermalDetector
    private let tracker: IncidentTracker
    private var persisted: PersistedState

    // Current minute accumulators
    private var minuteStart = Monitor.minuteFloor(Date())
    private var readings: [(TemperatureReading, Double?, Double?, PressureLevel, Bool?)] = []
    private var programSeconds: [String: Double] = [:]
    private var programNames: [String: String] = [:]
    private var programPIDs: [String: (Int32, Double)] = [:]
    private var programCovered: TimeInterval = 0
    private var lastProcessSample: Date?

    // Rolling windows (in memory)
    private var recentMinutes: [MinuteSample] = []
    private var recentPrograms: [MinuteContext.ProgramMinute] = []
    private var bucketSums: [String: Double] = [:]
    private var bucketMinutes = 0

    private var notifiers: [Notifier] = []
    private var timers: [Timer] = []
    private var lastHeartbeatSent: Date?
    private let bootTime: Date = {
        var tv = timeval(); var size = MemoryLayout<timeval>.stride
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }()

    /// `passive`: no sampling loop, no notifications, no Telegram polling (documentation renders).
    private let passive: Bool

    init(passive: Bool = false) throws {
        self.passive = passive
        config = ConfigStore.load()
        store = try HistoryStore(url: Paths.history)
        if let data = try? Data(contentsOf: Paths.state), let state = try? JSONDecoder.smolder.decode(PersistedState.self, from: data) {
            persisted = state
        } else {
            persisted = PersistedState()
        }
        thermal = ThermalDetector(fit: persisted.fit)
        tracker = IncidentTracker(open: persisted.openIncidents, history: persisted.history)
        Localization.shared.apply(languageCode: config.general.language)
        // Re-seed the in-memory windows so a restart does not reset persistence counters to zero.
        recentMinutes = store.samples(since: Date().addingTimeInterval(-3 * 3600))
        for sample in recentMinutes { _ = thermal.observe(sample) }
        reconfigureNotifiers()
    }

    /// Held for the app's lifetime. Without it App Nap throttles a windowless menu bar app on a
    /// lid-closed Mac: timers slip by many minutes, minutes go unsampled and heartbeats stop.
    private var activity: NSObjectProtocol?

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Continuous thermal monitoring and heartbeats")
        _ = cpu.sample()
        _ = processes.sample()
        lastProcessSample = Date()
        sampleSensors()
        refreshLive()
        reloadChart()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } },
        ]
        Task { await flushOutbox() }
    }

    // MARK: - Sampling

    private func tick() {
        let now = Date()
        if Monitor.minuteFloor(now) > minuteStart { closeMinute(at: minuteStart) }
        sampleSensors()
        if let last = lastProcessSample, now.timeIntervalSince(last) >= 30 { sampleProcesses(now: now) }
        if let interval = Optional(config.general.heartbeatSeconds), lastHeartbeatSent.map({ now.timeIntervalSince($0) >= interval }) ?? true {
            lastHeartbeatSent = now
            Task { await sendHeartbeat() }
        }
        refreshLive()
    }

    private func sampleSensors() {
        let temps = hid.read()
        let power = smc?.float("PSTR")
        readings.append((temps, power, cpu.sample(), pressure.read(), ScreenState.isOn()))
    }

    private func sampleProcesses(now: Date) {
        let elapsed = now.timeIntervalSince(lastProcessSample ?? now)
        lastProcessSample = now
        let usage = processes.sample()
        programCovered += elapsed
        for p in usage {
            programSeconds[p.path, default: 0] += p.cores * elapsed
            programNames[p.path] = p.name
            if p.cores > (programPIDs[p.path]?.1 ?? -1) { programPIDs[p.path] = (p.pid, p.cores) }
        }
        live.topProcesses = Array(usage.prefix(8))
    }

    // MARK: - Minute close: aggregate, detect, notify

    private func closeMinute(at start: Date) {
        let now = start.addingTimeInterval(60)
        defer {
            minuteStart = Monitor.minuteFloor(Date())
            readings = []
            programSeconds = [:]; programNames = [:]; programPIDs = [:]; programCovered = 0
        }
        guard !readings.isEmpty else { return }

        let screens = readings.compactMap(\.4)
        var sample = MinuteSample(
            timestamp: start,
            dieMax: readings.compactMap(\.0.dieMax).max(),
            dieAvg: Stats.mean(readings.compactMap(\.0.dieAvg)),
            ssd: readings.compactMap(\.0.ssd).max(),
            battery: Stats.mean(readings.compactMap(\.0.battery)),
            power: Stats.mean(readings.compactMap(\.1)),
            cpuCores: Stats.mean(readings.compactMap(\.2)),
            thermalState: readings.map(\.3.rawValue).max() ?? 0,
            expectedDie: nil,
            screenOn: screens.isEmpty ? nil : screens.contains(true))
        sample.expectedDie = thermal.observe(sample)

        let covered = max(programCovered, 1)
        let programMinute = MinuteContext.ProgramMinute(
            timestamp: start,
            cores: programSeconds.mapValues { $0 / covered },
            names: programNames,
            pids: programPIDs.mapValues(\.0))

        recentMinutes.append(sample)
        recentPrograms.append(programMinute)
        recentMinutes.removeAll { now.timeIntervalSince($0.timestamp) > 3 * 3600 }
        recentPrograms.removeAll { now.timeIntervalSince($0.timestamp) > 3 * 3600 }
        store.append(sample)
        chart.append(sample)
        chart.removeAll { now.timeIntervalSince($0.timestamp) > 24 * 3600 }

        // 10-minute program buckets feed each program's own baseline.
        for (path, cores) in programMinute.cores { bucketSums[path, default: 0] += cores }
        bucketMinutes += 1
        if Calendar.current.component(.minute, from: now) % 10 == 0 {
            let bucket = now.addingTimeInterval(-600)
            store.appendProcessUsage(bucket: bucket, usage: bucketSums.mapValues { $0 / Double(max(bucketMinutes, 1)) }, anomalous: tracker.anomalousPrograms)
            bucketSums = [:]; bucketMinutes = 0
        }

        runDetectors(now: now)
        if Calendar.current.component(.hour, from: now) == 4, Calendar.current.component(.minute, from: now) == 0 { store.prune(now: now) }
    }

    private func runDetectors(now: Date) {
        let d = config.detection
        let learning = isLearning(now: now)
        let excluded = tracker.excludedRanges
        runaway.refreshBaselines(store: store, config: d, now: now)
        powerFloor.refreshBaseline(store: store, excluded: excluded, config: d, now: now)
        if let newFit = thermal.refitIfDue(store: store, excluded: excluded, config: d, now: now) {
            persisted.fit = newFit
            checkDrift(newFit, now: now)
        }

        let ctx = MinuteContext(now: now, minutes: recentMinutes, programs: recentPrograms, learning: learning, config: d)
        let runawayFindings = runaway.evaluate(ctx)
        var findings = runawayFindings
        let runawayOpen = tracker.open.values.contains { $0.kind == .runawayProcess && $0.key != PowerFloorDetector.key }
        findings += powerFloor.evaluate(ctx, suppress: runawayOpen || !runawayFindings.isEmpty)
        let held: Set<String> = powerFloor.canJudge(ctx) ? [] : [PowerFloorDetector.key]
        findings += thermal.evaluate(ctx)
        findings += HardLimitDetector.evaluate(ctx)

        let events = tracker.update(findings: findings, held: held, now: now, clearMinutes: d.clearMinutes, notifyRecoveries: config.general.notifyRecoveries)
        persisted.openIncidents = Array(tracker.open.values)
        persisted.history = tracker.history
        savePersisted()
        if !events.isEmpty {
            Task {
                for event in events { await outbox.enqueue(event) }
                await flushOutbox()
            }
        } else {
            Task { await flushOutbox() }
        }
    }

    /// A slowly drifting model can quietly absorb a real problem. Compare against a frozen reference
    /// (the first fit with a full baseline window) and say so when the physics changed noticeably.
    private func checkDrift(_ fit: ThermalFit, now: Date) {
        // A reference from the power-only model (0.1.x) has a different R; start over with this one.
        if persisted.referenceFit?.model != ThermalFit.currentModel { persisted.referenceFit = nil }
        guard let reference = persisted.referenceFit else {
            if Double(fit.minutes) >= config.detection.baselineDays * 1440 * 0.5 { persisted.referenceFit = fit }
            return
        }
        let resistanceChange = reference.steadyResistance > 0.1 ? fit.steadyResistance / reference.steadyResistance - 1 : 0
        let baseChange = fit.base - reference.base
        guard resistanceChange > 0.2 || baseChange > 8 else { return }
        if let last = persisted.lastDriftNotice, now.timeIntervalSince(last) < 7 * 86400 { return }
        persisted.lastDriftNotice = now
        let event = SmolderEvent(kind: .thermalAnomaly, severity: .info,
                                 title: L("Cooling has drifted from its reference"),
                                 lines: [L("Now %@ °C/W and %@ at idle; reference %@ °C/W and %@",
                                           String(format: "%.1f", fit.steadyResistance), Format.celsius(fit.base),
                                           String(format: "%.1f", reference.steadyResistance), Format.celsius(reference.base)),
                                         L("A hotter room looks the same as worse cooling — Smolder has no ambient sensor")],
                                 incidentID: UUID().uuidString, startedAt: now)
        Task { await outbox.enqueue(event); await flushOutbox() }
    }

    private func isLearning(now: Date) -> Bool {
        guard let first = store.firstSampleDate() else { return true }
        return now.timeIntervalSince(first) < config.detection.learningHours * 3600
    }

    // MARK: - Delivery

    private func reconfigureNotifiers() {
        guard !passive else { return }
        var list: [Notifier] = []
        if config.local.enabled { list.append(LocalNotifier()) }
        let token = SecretStore.get(Secrets.telegramToken) ?? ""
        if config.telegram.enabled, !token.isEmpty, !config.telegram.chatID.isEmpty {
            list.append(TelegramNotifier(botToken: token, chatID: config.telegram.chatID))
        }
        if config.webhook.enabled, let url = URL(string: config.webhook.url), url.scheme?.hasPrefix("http") == true {
            list.append(WebhookNotifier(url: url, bearerToken: SecretStore.get(Secrets.webhookBearer), sendEvents: config.webhook.sendEvents, sendHeartbeats: config.webhook.sendHeartbeats))
        }
        if config.command.enabled, !config.command.executable.isEmpty {
            list.append(CommandNotifier(executable: config.command.executable, arguments: config.command.arguments, sendEvents: config.command.sendEvents, sendHeartbeats: config.command.sendHeartbeats))
        }
        if config.ping.enabled, let url = URL(string: config.ping.url), url.scheme?.hasPrefix("http") == true {
            list.append(PingNotifier(url: url))
        }
        notifiers = list

        let chatID = config.telegram.chatID
        if config.telegram.enabled, config.telegram.answerCommands, !token.isEmpty, !chatID.isEmpty {
            let bot = self.bot
            let status: @Sendable () async -> String = { [weak self] in await self?.statusHTML() ?? "" }
            Task { await bot.start(token: token, chatID: chatID, status: status) }
        } else {
            let bot = self.bot
            Task { await bot.stop() }
        }
    }

    func flushOutbox() async {
        await outbox.flush(using: notifiers)
        live.deliveryErrors = await outbox.failures()
        live.pendingDeliveries = await outbox.pendingCount()
    }

    func sendTest() {
        let event = SmolderEvent(kind: .test, severity: .info, title: L("Smolder test notification"),
                                 lines: [L("If you can read this, notifications work.")],
                                 incidentID: UUID().uuidString, startedAt: Date())
        Task { await outbox.enqueue(event); await flushOutbox() }
    }

    private func sendHeartbeat() async {
        let beat = Heartbeat(host: Host.current().localizedName ?? "Mac", sentAt: Date(), bootTime: bootTime,
                             appVersion: AppInfo.version, status: snapshot())
        var failure: String?
        for notifier in notifiers {
            do { try await notifier.heartbeat(beat) } catch { failure = "\(notifier.id): \(error.localizedDescription)" }
        }
        live.lastHeartbeat = Date()
        live.heartbeatError = failure
        live.telegramPollError = await bot.lastError
    }

    func snapshot() -> StatusSnapshot {
        StatusSnapshot(dieMax: live.dieMax, expectedDie: live.expectedDie, ssd: live.ssd, battery: live.battery,
                       power: live.power, cpuCores: live.cpuCores, thermalState: live.pressure.rawValue,
                       learning: live.learning, openIncidents: live.openIncidents.map(\.title),
                       topProcesses: Array(live.topProcesses.prefix(5)),
                       pendingDeliveries: live.pendingDeliveries, deliveryErrors: live.deliveryErrors)
    }

    func statusHTML() -> String {
        let s = live
        var lines = ["🔥 <b>Smolder · \(escape(Host.current().localizedName ?? "Mac"))</b>"]
        var temps = L("Die %@", Format.celsius(s.dieMax))
        if let expected = s.expectedDie, let band = s.band { temps += L(" (expected %@ ± %@)", Format.celsius(expected), String(format: "%.0f", band)) }
        temps += " · " + L("SSD %@", Format.celsius(s.ssd)) + " · " + L("Battery %@", Format.celsius(s.battery))
        lines.append(temps)
        lines.append(L("Power %@ · CPU %@ cores · Pressure %@", Format.watts(s.power), Format.cores(s.cpuCores ?? 0), s.pressure.label))
        let top = s.topProcesses.prefix(3).filter { $0.cores >= 0.05 }.map { "\(escape($0.name)) \(Format.cores($0.cores))" }
        if !top.isEmpty { lines.append(L("Top CPU: %@", top.joined(separator: ", "))) }
        if s.openIncidents.isEmpty {
            lines.append(L("No open incidents"))
        } else {
            for incident in s.openIncidents {
                lines.append("⚠️ " + escape(incident.title) + " — " + L("since %@", Format.clock(incident.openedAt)))
            }
        }
        if s.learning { lines.append(L("Learning: %d%% done", Int(s.learningProgress * 100))) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions from the UI

    func accept(_ incident: Incident) {
        tracker.accept(key: incident.key, now: Date())
        for program in incident.programs { store.markNormal(path: program, since: incident.openedAt) }
        persisted.openIncidents = Array(tracker.open.values)
        persisted.history = tracker.history
        savePersisted()
        refreshLive()
    }

    func ignore(program name: String) {
        guard !config.detection.ignoredProcesses.contains(name) else { return }
        config.detection.ignoredProcesses.append(name)
    }

    func setTelegramToken(_ token: String) {
        SecretStore.set(Secrets.telegramToken, token.trimmingCharacters(in: .whitespacesAndNewlines))
        reconfigureNotifiers()
    }

    func setWebhookBearer(_ token: String) {
        SecretStore.set(Secrets.webhookBearer, token.trimmingCharacters(in: .whitespacesAndNewlines))
        reconfigureNotifiers()
    }

    // MARK: - Documentation

    /// Synthetic but realistic state for README screenshots (`--render-ui <dir> --demo`).
    func loadDemo() {
        let now = Monitor.minuteFloor(Date())
        var rng: UInt64 = 42
        func noise() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) - 0.5 }
        var smoothed = 0.6
        chart = (0..<1440).map { i in
            let t = now.addingTimeInterval(Double(i - 1439) * 60)
            let hour = Calendar.current.component(.hour, from: t)
            let power: Double = i >= 1400 ? 2.9 : (14...15).contains(hour) ? 7.5 : hour == 21 ? 3.2 : 0.6
            smoothed += (1 - exp(-1 / 3.0)) * (power - smoothed)
            let expected = 31 + 3.6 * smoothed
            return MinuteSample(timestamp: t, dieMax: expected + 3 + noise() * 1.5, dieAvg: expected + noise(), ssd: 33, battery: 27,
                                power: power, cpuCores: power / 3, thermalState: 0, expectedDie: expected)
        }
        let opened = now.addingTimeInterval(-40 * 60)
        live = LiveState(dieMax: 44, dieAvg: 41.5, ssd: 33, battery: 27.2, power: 2.9, cpuCores: 1.1, pressure: .nominal,
                         expectedDie: 41.4, band: 3, learning: false, learningProgress: 1,
                         topProcesses: [ProcessUsage(pid: 4127, name: "appstoreagent", path: "/appstoreagent", cores: 0.98),
                                        ProcessUsage(pid: 812, name: "WindowServer", path: "/WindowServer", cores: 0.06),
                                        ProcessUsage(pid: 1170, name: "node", path: "/node", cores: 0.04)],
                         openIncidents: [Incident(key: "process:/appstoreagent", kind: .runawayProcess, severity: .warning,
                                                  title: L("%@ is running away", "appstoreagent"),
                                                  lines: [L("Using %@ cores on average for %@", Format.cores(0.98), Format.duration(1800)), L("Usually close to idle")],
                                                  programs: ["/appstoreagent"], openedAt: opened, lastAbnormalAt: now)],
                         recentIncidents: [], fit: nil, lastHeartbeat: now)
    }

    // MARK: - Helpers

    private func refreshLive() {
        guard let (temps, power, cpuCores, level, _) = readings.last else { return }
        live.dieMax = temps.dieMax
        live.dieAvg = temps.dieAvg
        live.ssd = temps.ssd
        live.battery = temps.battery
        live.power = power
        live.cpuCores = cpuCores
        live.pressure = level
        live.fit = thermal.fit
        live.band = thermal.band(config.detection)
        live.expectedDie = thermal.currentExpected
        let now = Date()
        live.learning = isLearning(now: now)
        if let first = store.firstSampleDate() {
            live.learningProgress = min(1, now.timeIntervalSince(first) / (config.detection.learningHours * 3600))
        }
        live.openIncidents = tracker.open.values.sorted { $0.openedAt < $1.openedAt }
        live.recentIncidents = Array(tracker.history.suffix(20).reversed())
    }

    private func reloadChart() {
        chart = store.samples(since: Date().addingTimeInterval(-24 * 3600))
    }

    private func savePersisted() {
        guard let data = try? smolderJSONEncoder.encode(persisted) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    static func minuteFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}
