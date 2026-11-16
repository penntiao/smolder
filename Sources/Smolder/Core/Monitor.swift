import Foundation
import Combine

/// What the menu bar, the panel, heartbeats and `/status` show.
struct LiveState {
    var dieMax: Double?
    var dieAvg: Double?
    var ssd: Double?
    var battery: Double?
    var fanRPM: Double?          // fastest fan, where the Mac has fans
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
    var machine = Machine(name: nil, identifier: nil, hasLid: false, hasBattery: false, fans: 0)
    var coolingSummary = ""
    var canAcceptCooling = false
}

/// One 10-second reading of every sensor.
private struct Reading {
    var temperatures: TemperatureReading
    var power: Double?
    var cpuCores: Double?
    var pressure: PressureLevel
    var screenOn: Bool?
    var cpuPower: Double?
    var lidClosed: Bool?
    var fanRPM: Double?
    var screenHolders: Set<String>?
    var screens: ScreenState.Reading?
}

/// Persisted between launches.
private struct PersistedState: Codable {
    var openIncidents: [Incident] = []
    var history: [Incident] = []
    var fit: ThermalFit?
    var referenceFit: ThermalFit?
    var lastDriftNotice: Date?
    var cooling: CoolingBaseline?
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
    let machine: Machine
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
    private var readings: [Reading] = []
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
        machine = Machine.detect(smc: smc)
        if let data = try? Data(contentsOf: Paths.state), let state = try? JSONDecoder.smolder.decode(PersistedState.self, from: data) {
            persisted = state
        } else {
            persisted = PersistedState()
        }
        thermal = ThermalDetector(fit: persisted.fit)
        tracker = IncidentTracker(open: persisted.openIncidents, history: persisted.history)
        thermal.hasFans = machine.fans > 0
        live.machine = machine
        Localization.shared.apply(languageCode: config.general.language)
        // Re-seed the in-memory windows so a restart does not reset persistence counters to zero.
        thermal.excluded = tracker.excludedRanges
        for sample in store.samples(since: Date().addingTimeInterval(-ThermalDetector.memoryHours(config.detection) * 3600)) {
            _ = thermal.observe(sample, config: config.detection)
        }
        recentMinutes = store.samples(since: Date().addingTimeInterval(-3 * 3600))
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
        let fan = machine.fans > 0 ? (0..<machine.fans).compactMap { smc?.fanRPM($0) }.max() : nil
        let screens = ScreenState.read()
        readings.append(Reading(temperatures: temps, power: power, cpuCores: cpu.sample(), pressure: pressure.read(),
                                screenOn: screens.map { $0.builtinLit || $0.otherLit > 0 }, cpuPower: smc?.float(SMC.cpuPowerKey),
                                lidClosed: machine.hasLid ? LidState.isClosed() : nil, fanRPM: fan,
                                screenHolders: ScreenHolders.read(), screens: screens))
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

        let screens = readings.compactMap(\.screenOn)
        let lids = readings.compactMap(\.lidClosed)
        let screenMinute = ScreenState.minute(readings.map(\.screens), hasBuiltin: machine.hasBuiltinDisplay)
        var sample = MinuteSample(
            timestamp: start,
            dieMax: readings.compactMap(\.temperatures.dieMax).max(),
            dieAvg: Stats.mean(readings.compactMap(\.temperatures.dieAvg)),
            ssd: readings.compactMap(\.temperatures.ssd).max(),
            battery: Stats.mean(readings.compactMap(\.temperatures.battery)),
            power: Stats.mean(readings.compactMap(\.power)),
            cpuCores: Stats.mean(readings.compactMap(\.cpuCores)),
            thermalState: readings.map(\.pressure.rawValue).max() ?? 0,
            expectedDie: nil,
            screenOn: screens.isEmpty ? nil : screens.contains(true),
            cpuPower: Stats.mean(readings.compactMap(\.cpuPower)),
            lidClosed: lids.isEmpty ? nil : !lids.contains(false),
            fanRPM: Stats.mean(readings.compactMap(\.fanRPM)),
            builtinScreen: screenMinute.builtin,
            otherScreens: screenMinute.others)
        thermal.excluded = tracker.excludedRanges
        sample.expectedDie = thermal.observe(sample, config: config.detection).map { $0 + thermal.ambientOffset(at: now, config: config.detection) }

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
        store.appendScreenHolders(minute: start, seconds: ScreenHolders.seconds(readings.map(\.screenHolders)))
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
            checkDrift(newFit, excluded: excluded, now: now)
        }

        thermal.excluded = excluded
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

    /// Keeps the reference (see `DriftCheck`), judges the idle level against it, and records each finished week in the
    /// learned cooling baseline (see `CoolingBaseline`); says so when cooling got worse, or learned that it got better.
    private func checkDrift(_ fit: ThermalFit, excluded: [ClosedRange<Date>], now: Date) {
        let window = config.detection.baselineDays * 86400
        let store = self.store
        let samples: (Date, Date) -> [MinuteSample] = { from, to in store.samples(since: from).filter { $0.timestamp < to } }
        let previous = persisted.referenceFit
        let (reference, outcome) = DriftCheck.run(
            reference: previous, fallback: fit, hasLid: machine.hasLid, idleAllowance: persisted.cooling?.idleAllowance ?? 0,
            excluded: excluded, config: config.detection, now: now, window: { end in samples(end.addingTimeInterval(-window), end) })
        persisted.referenceFit = reference
        // A new reference is a new yardstick: the weeks measured against the old one do not carry over.
        if reference == nil || reference?.fittedAt != previous?.fittedAt { persisted.cooling = nil }
        if let reference, persisted.cooling == nil {
            let own = ThermalModel.loadDrift(samples(reference.fittedAt.addingTimeInterval(-window), reference.fittedAt),
                                             excluded: excluded, reference: reference)
            persisted.cooling = CoolingBaseline(since: previous?.fittedAt == reference.fittedAt ? now : reference.fittedAt,
                                                level: own?.ratio ?? 1)
        }
        guard let reference, var cooling = persisted.cooling else { return }

        switch outcome {
        case let .steady(current), let .drifted(current):
            cooling.lastIdleRise = current.base - reference.base
            cooling.idleDrifted = ThermalModel.idleDrifted(current, from: reference, allowance: cooling.idleAllowance)
        default:
            break
        }
        var events: [SmolderEvent] = []
        if case let .drifted(current) = outcome,
           persisted.lastDriftNotice.map({ now.timeIntervalSince($0) >= 7 * 86400 }) ?? true {
            persisted.lastDriftNotice = now
            events.append(driftEvent(lines: [current.roomReferenced
                ? L("At idle %@ above the room; reference %@", String(format: "%.1f°", current.base), String(format: "%.1f°", reference.base + cooling.idleAllowance))
                : L("At idle %@; reference %@", Format.celsius(current.base), Format.celsius(reference.base + cooling.idleAllowance))],
                reference: reference, now: now))
        }
        for change in cooling.catchUp(reference: reference, excluded: excluded, now: now, samples: samples) {
            switch change {
            case let .worse(week, level, band, weeks):
                events.append(driftEvent(lines: [
                    L("This week, under load, the die warmed %@ more than usual for the same load", Format.share((week.ratio ?? level) / level - 1)),
                    weeks == 0 ? L("Alert line %@ (no usual weeks learned yet)", Format.percent(band))
                               : L("Usual weeks stay within %@ (learned from %d weeks)", Format.percent(band), weeks),
                ], reference: reference, now: now))
            case let .improved(from, to):
                events.append(SmolderEvent(kind: .thermalAnomaly, severity: .info, title: L("Cooling has improved"),
                                           lines: [L("Two weeks in a row the die warmed %@ less under load than usual; that is now the usual level",
                                                     Format.share(1 - to / from)),
                                                   L("If it gets worse again, Smolder will say so")],
                                           incidentID: UUID().uuidString, startedAt: now))
            }
        }
        persisted.cooling = cooling
        if !events.isEmpty { Task { for event in events { await outbox.enqueue(event) }; await flushOutbox() } }
    }

    private func driftEvent(lines: [String], reference: ThermalFit, now: Date) -> SmolderEvent {
        var lines = lines
        switch reference.lid {
        case .closed?: lines.append(L("Only minutes with the lid closed are compared"))
        case .open?: lines.append(L("Only minutes with the lid open are compared"))
        default: break
        }
        lines.append(reference.roomReferenced ? L("The room is estimated from the battery while the Mac is idle")
                                              : L("A hotter room looks the same as worse cooling — Smolder has no ambient sensor"))
        lines.append(L("If this is the new normal (the Mac was moved, a stand taken away), send /accept or press Accept in Settings → Detection"))
        return SmolderEvent(kind: .thermalAnomaly, severity: .info, title: L("Cooling has drifted from its reference"),
                            lines: lines, incidentID: UUID().uuidString, startedAt: now)
    }

    /// `/accept` and the button in Settings: what the cooling check flagged as worse becomes the new usual level.
    @discardableResult
    func acceptCooling() -> String {
        guard var cooling = persisted.cooling else { return L("Nothing to accept: the cooling reference is still collecting data") }
        guard cooling.accept(now: Date()) else { return L("Nothing to accept: cooling is within its usual range") }
        persisted.cooling = cooling
        savePersisted()
        refreshLive()
        return L("Accepted: this is now the usual level. If it gets worse from here, Smolder will say so.")
    }

    /// One line on the long-term cooling check, for `/status` and Settings.
    var coolingSummary: String {
        guard let cooling = persisted.cooling else { return L("Cooling reference: collecting data") }
        guard let last = cooling.lastJudged else { return L("Cooling reference: learning, no week judged yet") }
        let state: String
        switch last.verdict {
        case .worse: state = L("worse than usual")
        case .better: state = L("better than usual")
        default: state = L("as usual")
        }
        return L("Cooling reference: %@ (%d weeks, alert above %@)", state, cooling.judgedWeeks, Format.percent(cooling.alertBand))
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
            let accept: @Sendable () async -> String = { [weak self] in await self?.acceptCooling() ?? "" }
            Task { await bot.start(token: token, chatID: chatID, status: status, accept: accept) }
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
        StatusSnapshot(dieMax: live.dieMax, expectedDie: live.expectedDie, ssd: live.ssd, battery: live.battery, fanRPM: live.fanRPM,
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
        temps += " · " + L("SSD %@", Format.celsius(s.ssd))
        if s.machine.hasBattery { temps += " · " + L("Battery %@", Format.celsius(s.battery)) }
        if s.machine.fans > 0 { temps += " · " + L("Fan %@", Format.rpm(s.fanRPM)) }
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
        lines.append(escape(s.coolingSummary))
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
        live.machine = Machine(name: "MacBook Air (13-inch, M4, 2025)", identifier: "Mac16,12", hasLid: true, hasBattery: true, fans: 0, hasBuiltinDisplay: true)
    }

    // MARK: - Helpers

    private func refreshLive() {
        guard let r = readings.last else { return }
        let temps = r.temperatures, power = r.power, cpuCores = r.cpuCores, level = r.pressure
        live.dieMax = temps.dieMax
        live.dieAvg = temps.dieAvg
        live.ssd = temps.ssd
        live.battery = temps.battery
        live.fanRPM = r.fanRPM
        live.power = power
        live.cpuCores = cpuCores
        live.pressure = level
        live.fit = thermal.fit
        live.band = thermal.band(config.detection)
        live.expectedDie = thermal.currentExpected(at: Date(), config: config.detection)
        let now = Date()
        live.learning = isLearning(now: now)
        if let first = store.firstSampleDate() {
            live.learningProgress = min(1, now.timeIntervalSince(first) / (config.detection.learningHours * 3600))
        }
        live.openIncidents = tracker.open.values.sorted { $0.openedAt < $1.openedAt }
        live.recentIncidents = Array(tracker.history.suffix(20).reversed())
        live.coolingSummary = coolingSummary
        live.canAcceptCooling = persisted.cooling?.canAccept ?? false
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
