#if DISKLENS_SNAPSHOTS
import SwiftUI
import AppKit
import DiskLensCore

/// `DiskLens --snapshot DIR [--demo] [--license free|trial|pro] [--appearance dark|light] [--all-sizes]`
///
/// Renders every pane of the real app — with the latest saved scan and a live analysis, or the
/// synthetic demo Mac — into PNG files using invisible offscreen windows, then exits. Used for App
/// Store screenshots and to verify the UI without taking control of the user's screen. The license
/// state is fixed in memory (the Keychain is never touched) and nothing on disk is modified.
@MainActor
enum SnapshotRunner {
    struct Size { var w: CGFloat; var h: CGFloat; var scale: CGFloat
        var label: String { "\(Int(w * scale))x\(Int(h * scale))" }
    }

    static func run(outputDir: String, demo: Bool, args: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func opt(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let edition = Edition.current
        let state: LicenseState
        switch opt("--license") ?? "free" {
        case "pro": state = .pro(source: edition == .appStore ? .appStore(productID: StoreProducts.proLifetime) : .licenseKey(edition: .pro, expires: nil))
        case "trial": state = .trial(expires: Date().addingTimeInterval(6 * 86_400))
        default: state = .free
        }
        let dark = (opt("--appearance") ?? "dark") != "light"
        let scheme: ColorScheme = dark ? .dark : .light
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let sizes: [Size] = args.contains("--all-sizes")
            ? [Size(w: 1280, h: 800, scale: 1), Size(w: 1440, h: 900, scale: 1), Size(w: 1280, h: 800, scale: 2), Size(w: 1440, h: 900, scale: 2)]
            : [Size(w: 1440, h: 900, scale: 2)]

        let model = AppModel(demo: demo, licenseOverride: .fixed(state, edition: edition))
        model.renderStaticTreemap = true
        model.showOnboarding = false
        if !demo, let s = model.scan, s.tree.count > 0 { model.duplicatesAnalyzed = false }
        Task { @MainActor in
            let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let deadline = Date().addingTimeInterval(300)
            try? await Task.sleep(for: .milliseconds(500))
            if !demo && model.scan != nil && model.recommendations.isEmpty && !model.isAnalyzing { model.analyze() }
            while !demo && (model.isAnalyzing || (model.scan != nil && model.recommendations.isEmpty)) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let suffix = dark ? "" : "-light"
            func file(_ name: String, _ size: Size) -> URL {
                dir.appendingPathComponent(sizes.count > 1 ? "\(name)\(suffix)-\(size.label).png" : "\(name)\(suffix).png")
            }
            /// Sheets and panels are rendered once at 2× regardless of --all-sizes.
            func sheet(_ name: String) -> URL { dir.appendingPathComponent("\(name)\(suffix).png") }
            for size in sizes {
                let cg = CGSize(width: size.w, height: size.h)
                for pane in Pane.allCases {
                    model.pane = pane
                    model.focus = ScanTree.root
                    if pane == .explorer, let tree = model.tree {
                        model.selection = tree.rootIDs.first.flatMap { tree.sortedChildren(of: $0).first }
                    }
                    if pane == .cleanup { model.activeRecID = model.recommendations.first(where: { $0.tier == .low })?.id }
                    await render(ContentView().environment(model).preferredColorScheme(scheme), size: cg, scale: size.scale,
                                 appearance: appearance, to: file(pane.rawValue.replacingOccurrences(of: " ", with: "-"), size))
                }
                // Zoomed-in treemap of the largest top-level folder.
                if let tree = model.tree, let home = tree.rootIDs.first,
                   let big = tree.sortedChildren(of: home).first(where: { tree.nodes[Int($0)].isDirectory }) {
                    model.pane = .explorer
                    model.zoom(into: big)
                    await render(ContentView().environment(model).preferredColorScheme(scheme), size: cg, scale: size.scale,
                                 appearance: appearance, to: file("Explorer-zoomed", size))
                    model.focus = ScanTree.root
                }
            }
            // The treemap Canvas alone, through ImageRenderer (which supports Canvas).
            if let tree = model.tree {
                for (name, focus) in [("Treemap-all", ScanTree.root), ("Treemap-home", tree.rootIDs.first ?? ScanTree.root)] {
                    let rect = CGRect(x: 0, y: 0, width: 1200, height: 760)
                    let tiles = TreemapBuilder.tiles(tree: tree, focus: focus, bounds: rect, maxDepth: 2, minTileArea: 70, headerHeight: 18, padding: 3)
                    model.ensureDominant()
                    let dom = model.dominant
                    let view = Canvas { ctx, _ in TreemapView.drawTiles(ctx, tiles: tiles, tree: tree, selection: nil, hovered: nil, hidden: [], dominant: dom) }
                        .frame(width: rect.width, height: rect.height).background(Theme.treemapBackground)
                    let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)\(suffix).png"))
                    }
                }
            }
            // Cleanup preview sheet with a typical selection (several items not in use).
            let picks = model.recommendations.filter { !$0.requiresManualReview && $0.inUseBy.allSatisfy { $0.hasPrefix("(") } }
                .sorted { $0.estimatedReclaimable > $1.estimatedReclaimable }.prefix(demo ? 5 : 6)
            model.selectedRecs = Set(picks.map(\.id))
            await render(CleanupPreviewSheet().environment(model).preferredColorScheme(scheme).background(Theme.background),
                         size: CGSize(width: 860, height: 680), scale: 2, appearance: appearance, to: sheet("Cleanup-Preview"))
            // Dry run of that plan (validations only — nothing is modified) rendered in the sheet.
            if !demo && !picks.isEmpty {
                let plan = model.makePlan()
                model.pinnedPreviewPlan = plan
                model.dryRunReport = try? model.makeExecutor().execute(plan: plan, approval: nil, dryRun: true)
                await render(CleanupPreviewSheet().environment(model).preferredColorScheme(scheme).background(Theme.background),
                             size: CGSize(width: 860, height: 680), scale: 2, appearance: appearance, to: sheet("Cleanup-DryRun"))
                model.dryRunReport = nil
                model.pinnedPreviewPlan = nil
            }
            // Paywall, quoting the measured estimate of this scan.
            let ctx = PaywallContext.from(recommendations: model.recommendations, scanDate: model.scan?.manifest.finishedAt, trigger: .cleanup)
            await render(PaywallView(context: ctx).environment(model).preferredColorScheme(scheme).background(Theme.panel),
                         size: CGSize(width: 680, height: 600), scale: 2, appearance: appearance, to: sheet("Paywall"))
            await render(LicenseSettingsView().environment(model).preferredColorScheme(scheme).background(Theme.panel),
                         size: CGSize(width: 560, height: 400), scale: 2, appearance: appearance, to: sheet("Settings-License"))
            await render(ScheduleSettingsView().environment(model).preferredColorScheme(scheme).background(Theme.panel),
                         size: CGSize(width: 560, height: 440), scale: 2, appearance: appearance, to: sheet("Settings-Schedule"))
            await render(MenuBarContent().environment(model).preferredColorScheme(scheme).background(Theme.panel),
                         size: CGSize(width: 300, height: 250), scale: 2, appearance: appearance, to: sheet("MenuBar"))
            await render(OnboardingView().environment(model).preferredColorScheme(scheme).background(Theme.panel),
                         size: CGSize(width: 560, height: 600), scale: 2, appearance: appearance, to: sheet("Onboarding"))
            print("snapshots written to \(dir.path)")
            exit(0)
        }
        app.run()
    }

    /// Renders a view in an invisible borderless window at an exact pixel size (logical size × scale).
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat, appearance: NSAppearance?, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = appearance
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // never on screen
        window.orderBack(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        } else {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

#endif
