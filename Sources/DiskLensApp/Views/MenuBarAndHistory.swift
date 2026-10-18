import SwiftUI
import AppKit
import DiskLensCore

/// Menu-bar extra (Pro): measured free space, last scan, reclaimable estimate, quick actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let v = model.volume {
                HStack(spacing: 12) {
                    UsageRing(used: v.usedBytes, total: v.totalBytes).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ByteFormat.gb(v.availableBytes)) free").font(.headline.monospacedDigit())
                        Text("of \(ByteFormat.gb(v.totalBytes)) · +\(ByteFormat.gb(v.purgeableBytes)) purgeable").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Free space unavailable").foregroundStyle(Theme.muted)
            }
            Divider()
            LabeledContent("Last scan", value: model.scan.map { $0.manifest.finishedAt.formatted(date: .abbreviated, time: .shortened) } ?? "never")
            LabeledContent("Reclaimable (estimate)", value: model.recommendations.isEmpty ? "—" : ByteFormat.gb(model.reclaimableEstimate))
            if model.settings.schedule.frequency != .off {
                LabeledContent("Schedule", value: "\(model.settings.schedule.frequency.label), from \(String(format: "%02d:00", model.settings.schedule.preferredHour))")
            }
            if model.isScanning, let p = model.progress {
                ProgressView(value: Double(p.rootIndex) / Double(max(1, p.rootCount))) { Text("Scanning… \(p.filesVisited.formatted()) files").font(.caption) }
            }
            Divider()
            HStack {
                Button(model.isScanning ? "Scanning…" : "Scan Now") { model.startScan() }.disabled(model.isScanning)
                Button("Open DiskLens") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300)
    }
}

/// Reports pane header: export buttons (Pro) and scan history (Pro).
struct ExportAndHistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unlocked = model.license.isEnabled(.reportExport)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Export & history").font(.title3.bold())
                if !unlocked { ProBadge() }
                Spacer()
                Button { model.export(markdown: true) } label: { Label("Export Markdown…", systemImage: "doc.richtext") }
                    .disabled(model.scan == nil)
                Button { model.export(markdown: false) } label: { Label("Export JSON…", systemImage: "curlybraces") }
                    .disabled(model.scan == nil)
            }
            if unlocked {
                if model.history.isEmpty {
                    Text("No scans recorded yet.").foregroundStyle(Theme.muted)
                } else {
                    HistoryChart(entries: Array(model.history.prefix(30)))
                        .frame(height: 120)
                    VStack(spacing: 0) {
                        ForEach(model.history.prefix(12)) { h in
                            HStack {
                                Text(h.finishedAt.formatted(date: .abbreviated, time: .shortened)).frame(width: 170, alignment: .leading)
                                Text("scanned \(ByteFormat.gb(h.scannedAllocated))").monospacedDigit().frame(width: 150, alignment: .leading)
                                Text("free \(h.availableBytes.map(ByteFormat.gb) ?? "n/a")").monospacedDigit().frame(width: 120, alignment: .leading)
                                Text("\(h.coverageGaps) gaps · \(h.changeCount) changes").foregroundStyle(Theme.muted)
                                Spacer()
                            }
                            .font(.caption)
                            .padding(.vertical, 4)
                            Divider().opacity(0.3)
                        }
                    }
                }
            } else {
                LockedFeatureCard(feature: .reportExport, trigger: .reportExport,
                                  detail: "Export Markdown or JSON reports (paths and sizes only) and browse \(model.history.count) recorded scan\(model.history.count == 1 ? "" : "s") over time. Change detection against the previous scan stays free in the Scan Manifest.")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }
}

/// Free space and scanned size over time (measured values only).
struct HistoryChart: View {
    var entries: [ScanHistoryEntry]
    var body: some View {
        let pts = entries.sorted { $0.finishedAt < $1.finishedAt }
        let all = pts.map(\.scannedAllocated) + pts.compactMap(\.availableBytes)
        let lo = Double(all.min() ?? 0) * 0.9, hi = max(Double(all.max() ?? 1) * 1.05, lo + 1)
        Canvas { ctx, size in
            guard pts.count > 1 else { return }
            let t0 = pts.first!.finishedAt.timeIntervalSince1970, t1 = pts.last!.finishedAt.timeIntervalSince1970
            func x(_ d: Date) -> CGFloat { CGFloat((d.timeIntervalSince1970 - t0) / max(1, t1 - t0)) * (size.width - 8) + 4 }
            func y(_ v: Int64) -> CGFloat { size.height - 4 - CGFloat((Double(v) - lo) / (hi - lo)) * (size.height - 22) }
            for (vals, color) in [(pts.map { ($0.finishedAt, $0.scannedAllocated) }, Theme.accent),
                                  (pts.compactMap { p in p.availableBytes.map { (p.finishedAt, $0) } }, Theme.good)] where vals.count > 1 {
                var path = Path()
                path.move(to: CGPoint(x: x(vals[0].0), y: y(vals[0].1)))
                for v in vals.dropFirst() { path.addLine(to: CGPoint(x: x(v.0), y: y(v.1))) }
                ctx.stroke(path, with: .color(color), lineWidth: 2)
                for v in vals { ctx.fill(Path(ellipseIn: CGRect(x: x(v.0) - 2.5, y: y(v.1) - 2.5, width: 5, height: 5)), with: .color(color)) }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                Label("Scanned", systemImage: "circle.fill").foregroundStyle(Theme.accent)
                Label("Free space", systemImage: "circle.fill").foregroundStyle(Theme.good)
            }
            .font(.caption2)
        }
        .accessibilityLabel("Chart of scanned size and free space over \(entries.count) scans")
    }
}
