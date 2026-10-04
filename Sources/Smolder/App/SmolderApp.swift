import SwiftUI
import AppKit

@main
struct SmolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            if let monitor = delegate.monitor {
                MenuPanel().environmentObject(monitor)
            } else {
                Text(delegate.startupError ?? "Starting…").padding()
            }
        } label: {
            MenuBarLabel(monitor: delegate.monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let monitor = delegate.monitor {
                SettingsView().environmentObject(monitor)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var monitor: Monitor?
    private(set) var startupError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Smolder --render-ui <dir>`: write PNGs of the panel with demo data, for documentation.
        if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            MainActor.assumeIsolated {
                if let demo = try? Monitor(passive: true) { UIRenderer.render(monitor: demo, to: dir) }
            }
            exit(0)
        }
    }

    override init() {
        super.init()
        if CommandLine.arguments.contains("--probe") { Probe.run(); exit(0) }
        if CommandLine.arguments.contains("--test-notify") { exit(TestNotify.run() ? 0 : 1) }
        if CommandLine.arguments.contains("--render-ui") { return }
        SingleInstance.claim()
        MainActor.assumeIsolated {
            do {
                let monitor = try Monitor()
                self.monitor = monitor
                monitor.start()
                if monitor.config.local.enabled { LocalNotifier.requestAuthorization() }
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}

struct MenuBarLabel: View {
    let monitor: Monitor?

    var body: some View {
        if let monitor {
            MenuBarLabelContent().environmentObject(monitor)
        } else {
            Image(systemName: "flame")
        }
    }
}

private struct MenuBarLabelContent: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let alert = !monitor.live.openIncidents.isEmpty
        HStack(spacing: 3) {
            Image(systemName: alert ? "flame.fill" : "flame")
            if monitor.config.general.menuBarShowsTemperature {
                Text(Format.celsius(monitor.live.dieMax)).monospacedDigit()
            }
        }
    }
}

/// One copy at a time. A copy started by our LaunchAgent wins (it is the supervised one): it asks any
/// other copy to quit. Any other second copy just exits.
enum SingleInstance {
    static let yieldNotification = Notification.Name("io.github.penntiao.smolder.yield")

    static func claim() {
        if LaunchAgent.handOverToLaunchd() { exit(0) }
        let others = { NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() } }
        if !others().isEmpty {
            guard LaunchAgent.isSupervised else { exit(0) }
            DistributedNotificationCenter.default().postNotificationName(yieldNotification, object: nil, userInfo: nil, deliverImmediately: true)
            for _ in 0..<50 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        DistributedNotificationCenter.default().addObserver(forName: yieldNotification, object: nil, queue: .main) { _ in
            if !LaunchAgent.isSupervised { NSApp.terminate(nil) }
        }
    }
}

/// `Smolder --test-notify`: send one test message to every configured destination and report each result.
enum TestNotify {
    static func run() -> Bool {
        let config = ConfigStore.load()
        Localization.shared.apply(languageCode: config.general.language)
        var notifiers: [Notifier] = []
        let token = SecretStore.get(Secrets.telegramToken) ?? ""
        if config.telegram.enabled, !token.isEmpty { notifiers.append(TelegramNotifier(botToken: token, chatID: config.telegram.chatID)) }
        if config.webhook.enabled, let url = URL(string: config.webhook.url) {
            notifiers.append(WebhookNotifier(url: url, bearerToken: SecretStore.get(Secrets.webhookBearer), sendEvents: true, sendHeartbeats: false))
        }
        if config.command.enabled, !config.command.executable.isEmpty {
            notifiers.append(CommandNotifier(executable: config.command.executable, arguments: config.command.arguments,
                                             sendEvents: config.command.sendEvents, sendHeartbeats: false))
        }
        guard !notifiers.isEmpty else { print("No destinations configured (macOS notifications are tested from Settings)."); return false }
        let event = SmolderEvent(kind: .test, severity: .info, title: L("Smolder test notification"),
                                 lines: [L("If you can read this, notifications work.")], incidentID: UUID().uuidString, startedAt: Date())
        var allOK = true
        let done = DispatchSemaphore(value: 0)
        Task {
            for n in notifiers {
                do { try await n.deliver(event); print("✓ \(n.id)") } catch { allOK = false; print("✗ \(n.id): \(error.localizedDescription)") }
            }
            done.signal()
        }
        done.wait()
        return allOK
    }
}

/// `Smolder --probe`: print what the sensors see, for bug reports.
enum Probe {
    static func run() {
        let hid = HIDTemperature(), cpu = CPULoad(), procs = ProcessSampler(), pressure = ThermalPressure()
        let smc = SMC()
        _ = cpu.sample(); _ = procs.sample()
        Thread.sleep(forTimeInterval: 3)
        let t = hid.read()
        print("Smolder \(AppInfo.version) on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("die max \(t.dieMax.map { String(format: "%.1f", $0) } ?? "–") avg \(t.dieAvg.map { String(format: "%.1f", $0) } ?? "–")  ssd \(t.ssd.map { String(format: "%.1f", $0) } ?? "–")  battery \(t.battery.map { String(format: "%.1f", $0) } ?? "–")")
        print("power \(smc?.float("PSTR").map { String(format: "%.2f W", $0) } ?? "–")  cpu \(cpu.sample().map { String(format: "%.2f cores", $0) } ?? "–")  pressure \(pressure.read())")
        for p in procs.sample().prefix(5) { print(String(format: "  %6d  %.2f  %@", p.pid, p.cores, p.name)) }
    }
}
