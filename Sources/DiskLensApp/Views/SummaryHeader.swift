import SwiftUI
import DiskLensCore

/// Top strip: measured volume figures, estimated reclaimable, measured recovered, last scan.
struct SummaryHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let v = model.volume {
                UsageRing(used: v.usedBytes, total: v.totalBytes)
                    .frame(width: 58, height: 58)
                StatCard(title: "Capacity", value: ByteFormat.gb(v.totalBytes), note: v.volumeName.isEmpty ? "measured" : "\(v.volumeName) · measured")
                StatCard(title: "Used", value: ByteFormat.gb(v.usedBytes), note: "measured (whole APFS container)")
                StatCard(title: "Available", value: ByteFormat.gb(v.availableBytes),
                         note: "+\(ByteFormat.gb(v.purgeableBytes)) purgeable (macOS)", tint: Theme.good)
            }
            StatCard(title: "Reclaimable", value: model.isAnalyzing ? "…" : ByteFormat.gb(model.reclaimableEstimate),
                     note: "ESTIMATE · tier 1 + 2", tint: Theme.accent)
            StatCard(title: "Recovered", value: ByteFormat.gb(model.recoveredBytes), note: "measured after cleanups", tint: Theme.good)
            StatCard(title: "Last scan", value: model.scan.map { $0.manifest.finishedAt.formatted(date: .abbreviated, time: .shortened) } ?? "never",
                     note: model.scan.map { String(format: "%.1f s · %@ scanned", $0.manifest.duration, ByteFormat.gb($0.tree.totalAllocated)) } ?? "")
            Spacer(minLength: 0)
            if model.isScanning, let p = model.progress {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView().controlSize(.small)
                    Text("\(p.filesVisited.formatted()) files").font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
        .background(Theme.panel)
    }
}

struct StatCard: View {
    var title: String
    var value: String
    var note: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minWidth: 128, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

struct UsageRing: View {
    var used: Int64
    var total: Int64
    var body: some View {
        let f = total > 0 ? Double(used) / Double(total) : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle().trim(from: 0, to: f)
                .stroke(AngularGradient(colors: [Theme.accent, f > 0.9 ? Theme.bad : Theme.warn], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(f * 100))%").font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk \(Int(f * 100)) percent used")
    }
}
