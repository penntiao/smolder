import SwiftUI

/// Editable text that is not part of `Config`. A plain ObservableObject instead of `@State`:
/// with the macOS 27 SDK `@State` is a macro whose plugin ships only with Xcode, and Smolder must
/// build with the Command Line Tools alone.
final class SettingsDraft: ObservableObject {
    @Published var token = SecretStore.get(Secrets.telegramToken) ?? ""
    @Published var bearer = SecretStore.get(Secrets.webhookBearer) ?? ""
    @Published var arguments = ""
    @Published var detectMessage: String?
    @Published var newIgnore = ""
    @Published var agentInstalled = LaunchAgent.isInstalled
    @Published var agentError: String?
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label(L("General"), systemImage: "gearshape") }
            NotificationsTab().tabItem { Label(L("Notifications"), systemImage: "bell") }
            DetectionTab().tabItem { Label(L("Detection"), systemImage: "waveform.path.ecg") }
            AboutTab().tabItem { Label(L("About"), systemImage: "info.circle") }
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var monitor: Monitor
    @StateObject private var draft = SettingsDraft()

    var body: some View {
        Form {
            Section {
                Toggle(L("Start at login and restart after a crash"), isOn: Binding(
                    get: { draft.agentInstalled },
                    set: { on in
                        do {
                            if on { try LaunchAgent.install() } else { LaunchAgent.uninstall() }
                            draft.agentError = nil
                        } catch { draft.agentError = error.localizedDescription }
                        draft.agentInstalled = LaunchAgent.isInstalled
                    }))
                if let error = draft.agentError { Text(error).foregroundStyle(.red).font(.caption) }
                Text(L("Uses a LaunchAgent, so Smolder comes back by itself if it ever crashes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Show chip temperature in the menu bar"), isOn: $monitor.config.general.menuBarShowsTemperature)
                Toggle(L("Notify when an incident resolves"), isOn: $monitor.config.general.notifyRecoveries)
                Picker(L("Language"), selection: $monitor.config.general.language) {
                    Text(L("System")).tag(String?.none)
                    Text("English").tag(String?.some("en"))
                    Text("简体中文").tag(String?.some("zh-Hans"))
                }
            }
            Section {
                LabeledContent(L("Data folder")) {
                    Button(Paths.support.path) { NSWorkspace.shared.open(Paths.support) }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @EnvironmentObject var monitor: Monitor
    @StateObject private var draft = SettingsDraft()

    var body: some View {
        Form {
            Section(L("This Mac")) {
                Toggle(L("macOS notifications"), isOn: $monitor.config.local.enabled)
            }

            Section("Telegram") {
                Toggle(L("Send to Telegram"), isOn: $monitor.config.telegram.enabled)
                SecureField(L("Bot token from @BotFather"), text: $draft.token)
                    .onSubmit { monitor.setTelegramToken(draft.token) }
                HStack {
                    TextField(L("Chat ID"), text: $monitor.config.telegram.chatID)
                    Button(L("Detect")) { detectChat() }
                }
                if let message = draft.detectMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Toggle(L("Answer /status from this chat"), isOn: $monitor.config.telegram.answerCommands)
                Text(L("Use a bot that only Smolder talks to: Telegram lets one program at a time receive a bot's messages."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Webhook")) {
                Toggle(L("POST JSON to a URL"), isOn: $monitor.config.webhook.enabled)
                TextField("https://…", text: $monitor.config.webhook.url)
                SecureField(L("Bearer token (optional)"), text: $draft.bearer).onSubmit { monitor.setWebhookBearer(draft.bearer) }
                Toggle(L("Send alerts"), isOn: $monitor.config.webhook.sendEvents)
                Toggle(L("Send heartbeats"), isOn: $monitor.config.webhook.sendHeartbeats)
            }

            Section(L("Custom command")) {
                Toggle(L("Run a command with the JSON on stdin"), isOn: $monitor.config.command.enabled)
                TextField(L("Executable, e.g. /usr/bin/ssh"), text: $monitor.config.command.executable)
                TextField(L("Arguments, one per line"), text: $draft.arguments, axis: .vertical)
                    .lineLimit(2...5)
                    .onChange(of: draft.arguments) { _, value in
                        monitor.config.command.arguments = value.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    }
                Toggle(L("Send alerts"), isOn: $monitor.config.command.sendEvents)
                Toggle(L("Send heartbeats"), isOn: $monitor.config.command.sendHeartbeats)
            }

            Section(L("Dead man's switch")) {
                Toggle(L("Ping a URL on every heartbeat"), isOn: $monitor.config.ping.enabled)
                TextField("https://hc-ping.com/…", text: $monitor.config.ping.url)
                Stepper(L("Heartbeat every %d s", Int(monitor.config.general.heartbeatSeconds)),
                        value: $monitor.config.general.heartbeatSeconds, in: 30...900, step: 30)
                Text(L("Smolder cannot report its own death. Point heartbeats at something outside this Mac (healthchecks.io, Uptime Kuma, your server) and let it alert when they stop."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(L("Send test notification")) {
                    monitor.setTelegramToken(draft.token)
                    monitor.setWebhookBearer(draft.bearer)
                    monitor.sendTest()
                }
                ForEach(monitor.live.deliveryErrors.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                    Text("\(item.key): \(item.value)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft.arguments = monitor.config.command.arguments.joined(separator: "\n") }
        .onDisappear {
            monitor.setTelegramToken(draft.token)
            monitor.setWebhookBearer(draft.bearer)
        }
    }

    private func detectChat() {
        let current = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { draft.detectMessage = L("Paste the bot token first."); return }
        monitor.setTelegramToken(current)
        draft.detectMessage = L("Looking for your latest message to the bot…")
        Task {
            do {
                if let chat = try await TelegramBot.detectChat(token: current) {
                    monitor.config.telegram.chatID = chat.id
                    draft.detectMessage = L("Found chat “%@”.", chat.title)
                } else {
                    draft.detectMessage = L("No messages yet. Send any message to your bot, then press Detect again.")
                }
            } catch {
                draft.detectMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Detection

private struct DetectionTab: View {
    @EnvironmentObject var monitor: Monitor
    @StateObject private var draft = SettingsDraft()

    var body: some View {
        Form {
            Section {
                let s = monitor.live
                if s.learning {
                    ProgressView(value: s.learningProgress) { Text(L("Learning what is normal on this Mac")) }
                    Text(L("Until then only conservative fixed rules apply: a program burning close to a full core for an hour, macOS throttling, an over-hot battery."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let fit = s.fit {
                    LabeledContent(L("Thermal model"), value: L("%@ at idle, +%@ °C per watt, %@ min lag",
                                                                 Format.celsius(fit.base), String(format: "%.1f", fit.resistance), String(format: "%.0f", fit.tau)))
                    LabeledContent(L("Learned from"), value: Format.duration(Double(fit.minutes) * 60))
                }
            }
            Section(L("Running hotter than the load explains")) {
                Toggle(L("Enabled"), isOn: $monitor.config.detection.thermalEnabled)
                Stepper(L("At least %@ above expected", String(format: "%.0f °C", monitor.config.detection.thermalMinMargin)),
                        value: $monitor.config.detection.thermalMinMargin, in: 1...15)
                Stepper(L("For %d min", monitor.config.detection.thermalSustainMinutes),
                        value: $monitor.config.detection.thermalSustainMinutes, in: 5...120, step: 5)
            }
            Section(L("Runaway programs")) {
                Toggle(L("Enabled"), isOn: $monitor.config.detection.runawayEnabled)
                Stepper(L("At least %@ cores, and %@× its usual peak", Format.cores(monitor.config.detection.runawayFloorCores), String(format: "%.1f", monitor.config.detection.runawayPeakMultiplier)),
                        value: $monitor.config.detection.runawayFloorCores, in: 0.1...4, step: 0.1)
                Stepper(L("For %d min", monitor.config.detection.runawaySustainMinutes),
                        value: $monitor.config.detection.runawaySustainMinutes, in: 5...240, step: 5)
                Toggle(L("Also watch the idle power floor"), isOn: $monitor.config.detection.powerFloorEnabled)
            }
            Section(L("Never flag these programs")) {
                ForEach(monitor.config.detection.ignoredProcesses, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button(role: .destructive) { monitor.config.detection.ignoredProcesses.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(L("Program name or full path"), text: $draft.newIgnore)
                    Button(L("Add")) {
                        let name = draft.newIgnore.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { monitor.ignore(program: name) }
                        draft.newIgnore = ""
                    }
                }
            }
            Section(L("Hard limits (never learned)")) {
                Stepper(L("Throttling for %d min", monitor.config.detection.pressureHeavyMinutes),
                        value: $monitor.config.detection.pressureHeavyMinutes, in: 1...60)
                Stepper(L("Battery at %@", Format.celsiusPrecise(monitor.config.detection.batteryCeiling)),
                        value: $monitor.config.detection.batteryCeiling, in: 30...45)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Smolder").font(.title.weight(.medium))
            Text(L("Version %@", AppInfo.version)).foregroundStyle(.secondary)
            Text(L("Catch your Mac smoldering while the lid is closed.")).multilineTextAlignment(.center)
            Link("github.com/penntiao/smolder", destination: URL(string: "https://github.com/penntiao/smolder")!)
            Text(L("MIT License")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
