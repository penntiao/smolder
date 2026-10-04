import SwiftUI
import Charts

struct MenuPanel: View {
    @EnvironmentObject var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
    /// Offscreen renders cannot draw native buttons; documentation screenshots leave them out.
    var showsControls = true

    var body: some View {
        let s = monitor.live
        VStack(alignment: .leading, spacing: 12) {
            header(s)
            HStack(spacing: 8) {
                Tile(label: L("Chip"), value: Format.celsius(s.dieMax),
                     note: s.expectedDie.map { L("expected %@", Format.celsius($0)) })
                Tile(label: L("SSD"), value: Format.celsius(s.ssd), note: nil)
                Tile(label: L("Battery"), value: Format.celsius(s.battery), note: nil)
            }
            TemperatureChart(samples: monitor.chart, band: s.band)
            Text(L("Power %@ · CPU %@ cores · Pressure %@", Format.watts(s.power), Format.cores(s.cpuCores ?? 0), s.pressure.label))
                .font(.caption).foregroundStyle(.secondary)

            if !s.openIncidents.isEmpty {
                Divider()
                ForEach(s.openIncidents) { IncidentRow(incident: $0, showsControls: showsControls) }
            }

            Divider()
            Text(L("Top CPU")).font(.caption).foregroundStyle(.secondary)
            ForEach(s.topProcesses.prefix(4), id: \.pid) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(Format.cores(p.cores)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
            }

            Divider()
            footer(s)
        }
        .padding(14)
        .frame(width: 340)
        .environment(\.locale, Localization.shared.locale)
    }

    @ViewBuilder private func header(_ s: LiveState) -> some View {
        HStack {
            Text("Smolder").font(.headline)
            Spacer()
            if !s.openIncidents.isEmpty {
                Badge(text: L("%d open", s.openIncidents.count), color: .orange)
            } else if s.learning {
                Badge(text: L("Learning %d%%", Int(s.learningProgress * 100)), color: .blue)
            } else if s.pressure >= .heavy {
                Badge(text: L("Throttling"), color: .orange)
            } else {
                Badge(text: L("Normal"), color: .green)
            }
        }
    }

    @ViewBuilder private func footer(_ s: LiveState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = s.deliveryErrors.first {
                Label(L("%@ delivery failing: %@", error.key, error.value), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let error = s.heartbeatError {
                Label(L("Heartbeat failing: %@", error), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let beat = s.lastHeartbeat {
                Label(L("Notifications OK · heartbeat %@", Format.clock(beat)), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsControls { HStack {
                Button(L("Settings…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button(L("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout) }
        }
    }
}

private struct Tile: View {
    var label: String
    var value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct IncidentRow: View {
    @EnvironmentObject var monitor: Monitor
    var incident: Incident
    var showsControls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(incident.title, systemImage: incident.severity == .critical ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(incident.severity == .critical ? .red : .orange)
            ForEach(incident.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(L("since %@", Format.clock(incident.openedAt))).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if showsControls, incident.kind == .runawayProcess, let path = incident.programs.first {
                    Button(L("Always ignore")) { monitor.ignore(program: (path as NSString).lastPathComponent); monitor.accept(incident) }
                }
                if showsControls { Button(L("Accept as normal")) { monitor.accept(incident) } }
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }
}

struct TemperatureChart: View {
    var samples: [MinuteSample]
    var band: Double?

    var body: some View {
        let points = samples.filter { $0.dieMax != nil }
        VStack(alignment: .leading, spacing: 4) {
        Text(band == nil ? L("Chip · 24 h") : L("Chip · 24 h · shaded = expected for the load"))
            .font(.caption2).foregroundStyle(.secondary)
        Chart {
            if let band {
                ForEach(points.filter { $0.expectedDie != nil }, id: \.timestamp) { s in
                    AreaMark(x: .value("Time", s.timestamp),
                             yStart: .value("Low", s.expectedDie! - band),
                             yEnd: .value("High", s.expectedDie! + band))
                        .foregroundStyle(.blue.opacity(0.12))
                }
            }
            ForEach(points, id: \.timestamp) { s in
                LineMark(x: .value("Time", s.timestamp), y: .value("°C", s.dieMax!))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour().locale(Localization.shared.locale)) } }
        .frame(height: 90)
        }
    }
}
