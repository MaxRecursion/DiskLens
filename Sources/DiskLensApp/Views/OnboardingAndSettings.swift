import SwiftUI
import AppKit
import DiskLensCore

enum AppLinks {
    static func url(_ key: String, fallback: String) -> URL {
        URL(string: (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback) ?? URL(string: fallback)!
    }
    // Real URLs come from Info.plist (set by release.config / Resources/Info.plist); the fallbacks
    // only apply to development builds without those keys.
    static var support: URL { url("DiskLensSupportURL", fallback: "https://www.apple.com/support/") }
    static var privacy: URL { url("DiskLensPrivacyPolicyURL", fallback: "https://www.apple.com/legal/privacy/") }
    /// Terms of Use. The App Store edition may use Apple's standard EULA (the fallback).
    static var terms: URL { url("DiskLensTermsURL", fallback: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") }
    /// Direct edition: the merchant-of-record checkout page (Paddle / Lemon Squeezy / FastSpring).
    static var purchase: URL { url("DiskLensPurchaseURL", fallback: "https://example.com/disklens/buy") }
    /// What DiskLens does on the network, per edition (shown in onboarding, Settings and About).
    static var networkStatement: String {
        Edition.current == .appStore
            ? "DiskLens collects no data and has no network access of its own; purchases go through the App Store."
            : "DiskLens collects no data. The only network request is the update check, which you can turn off; license keys are verified offline."
    }
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// First-run explanation of what DiskLens does and does not do, plus folder access.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to DiskLens").font(.title.bold())
                    Text("See where your disk space went — and reclaim it safely.").foregroundStyle(Theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                point("magnifyingglass", "Read-only scanning", "Scans read file names, sizes and dates; to find exact duplicates DiskLens also compares the contents of large files, on your Mac. Cloud-only files are never downloaded.")
                point("checkmark.shield", "You approve every removal", "Nothing is deleted without a preview of the exact paths and your explicit approval. Personal files, backups and app data are never removed automatically.")
                point("lock", "Private by design", "Scan results stay on this Mac. " + AppLinks.networkStatement)
            }
            Divider()
            if Platform.isSandboxed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose what DiskLens may scan").font(.headline)
                    Text("macOS keeps App Store apps out of your files until you grant access. Grant your Home folder for a complete picture; you can add or remove folders later in Settings.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    HStack {
                        Button {
                            model.access.requestFolder(suggested: Platform.realHome,
                                                       message: "Select your Home folder so DiskLens can measure what is using space. Nothing leaves your Mac, and nothing is removed without your approval.")
                        } label: { Label(model.access.hasHomeAccess ? "Home folder granted" : "Grant Home Folder…", systemImage: model.access.hasHomeAccess ? "checkmark.circle.fill" : "folder.badge.plus") }
                        .disabled(model.access.hasHomeAccess)
                        Button("Add Applications Folder…") {
                            model.access.requestFolder(suggested: "/Applications", message: "Optional: select /Applications to include installed apps in the scan.")
                        }
                    }
                    if !model.access.paths.isEmpty {
                        Text("Granted: " + model.access.paths.map { PathUtil.abbreviated($0) }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.good)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For complete results").font(.headline)
                    Text("macOS hides some folders (Mail, Messages, other apps' data, the Trash) unless DiskLens has Full Disk Access. Without it those folders are listed as “unknown”, never as empty.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    Button { NSWorkspace.shared.open(AppLinks.fullDiskAccessSettings) } label: {
                        Label("Open Full Disk Access Settings", systemImage: "gearshape")
                    }
                }
            }
            HStack {
                Link("Privacy Policy", destination: AppLinks.privacy).font(.caption)
                Spacer()
                Button("Not Now") { model.finishOnboarding() }
                Button {
                    model.finishOnboarding()
                    model.startScan()
                } label: { Text("Start Scan").frame(minWidth: 90) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(Platform.isSandboxed && model.access.paths.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
    }

    func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                if Platform.isSandboxed {
                    Section("Folders DiskLens may scan") {
                        if model.access.paths.isEmpty {
                            Text("No folders granted yet.").foregroundStyle(.secondary)
                        }
                        ForEach(model.access.paths, id: \.self) { p in
                            HStack {
                                Image(systemName: "folder")
                                Text(PathUtil.abbreviated(p))
                                Spacer()
                                Button("Remove") { model.access.remove(p) }
                            }
                        }
                        ForEach(model.access.unavailable, id: \.self) { p in
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text(PathUtil.abbreviated(p)).foregroundStyle(.secondary)
                                Text("unavailable").font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button("Re-grant…") { model.access.requestFolder(suggested: p, message: "Select this folder again to restore access.") }
                                Button("Remove") { model.access.remove(p) }
                            }
                        }
                        Button("Add Folder…") {
                            model.access.requestFolder(suggested: Platform.realHome, message: "Choose a folder DiskLens may scan.")
                        }
                    }
                } else {
                    Section("Scan scope") {
                        Picker("Scan", selection: $model.scope) {
                            ForEach(ScanScope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button("Open Full Disk Access Settings…") { NSWorkspace.shared.open(AppLinks.fullDiskAccessSettings) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Scanning", systemImage: "magnifyingglass") }

            Form {
                Section("Your data") {
                    Text(AppLinks.networkStatement + " Scan results (file paths and sizes), recommendations and cleanup reports are stored only on this Mac:")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PathUtil.abbreviated(model.store.directory.path)).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Delete Scan Data and Reports…", role: .destructive) { confirmReset = true }
                        .disabled(model.isScanning || model.isExecuting)
                }
                Section {
                    Link("Privacy Policy", destination: AppLinks.privacy)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "clock") }

            LicenseSettingsView()
                .tabItem { Label("License", systemImage: "checkmark.seal") }

            Form {
                @Bindable var settings = model.settings
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
        }
        .frame(width: 560, height: 440)
        .confirmationDialog("Delete DiskLens's saved scans and reports?", isPresented: $confirmReset) {
            Button("Delete", role: .destructive) { model.deleteScanData() }
        } message: {
            Text("This removes only DiskLens's own data. None of your files are affected.")
        }
    }
}

enum AboutPanel {
    @MainActor static func show() {
        let credits = NSMutableAttributedString(string: "Read-only disk analysis with an interactive treemap and evidence-based, approval-gated cleanup.\n\n\(AppLinks.networkStatement)\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "Privacy Policy", attributes: [.link: AppLinks.privacy, .font: NSFont.systemFont(ofSize: 11)]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "DiskLens"])
        NSApp.activate(ignoringOtherApps: true)
    }
}
