import SwiftUI
import AppKit
import DiskLensCore

/// Contextual, non-blocking upgrade sheet. Quotes only measured numbers from the current scan,
/// shows the localized StoreKit price (never a hard-coded one), and always offers "Not Now".
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    var context: PaywallContext
    @State private var message: String?
    @State private var keyText = ""
    @State private var showKeyField = false

    var license: LicenseService { model.license }
    var edition: Edition { license.edition }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: AppIcon.image).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.headline).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(context.subheadline).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("DISKLENS PRO").font(.caption.bold()).tracking(1.2).foregroundStyle(Theme.accent)
                    ForEach(Feature.allCases.filter { $0 != .cli || edition == .direct }, id: \.self) { f in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: f.symbol).foregroundStyle(Theme.accent).frame(width: 18).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.displayName).font(.callout.bold())
                                Text(f.summary).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text("ALWAYS FREE").font(.caption.bold()).tracking(1.2).foregroundStyle(Theme.good)
                    ForEach(["Full read-only scan and treemap", "Categories, largest files, search", "Every recommendation, estimate and evidence",
                             "Cleanup previews and dry runs", "All safety checks", "Move single items to the Trash",
                             "Scan manifest and change detection"], id: \.self) { t in
                        Label(t, systemImage: "checkmark").font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if license.freeAllowance.remaining > 0 && !license.state.isPaid {
                        Text("Includes one free one-click cleanup of up to \(ByteFormat.gb(FreeCleanupAllowance.capBytes)).")
                            .font(.caption).foregroundStyle(Theme.good).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                }
                .frame(width: 250, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            }
            Divider()
            if edition == .appStore { appStoreActions } else { directActions }
            if let message { Text(message).font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 14) {
                Link("Terms of Use", destination: AppLinks.terms).font(.caption)
                Link("Privacy Policy", destination: AppLinks.privacy).font(.caption)
                Spacer()
                Button("Not Now") { model.paywall = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 680)
    }

    @ViewBuilder var appStoreActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        message = nil
                        switch await license.purchasePro() {
                        case .purchased: model.paywall = nil
                        case .cancelled: break
                        case .pending: message = "Purchase pending approval (Ask to Buy or payment confirmation). Pro unlocks automatically when it is approved."
                        case .unverified(let why): message = "The App Store could not verify this purchase (\(why)). Nothing was charged twice; try Restore Purchases."
                        case .productUnavailable: message = license.productsError ?? "DiskLens Pro is not available right now."
                        case .failed(let e): message = "Purchase failed: \(e)"
                        }
                    }
                } label: {
                    if license.isPurchasing { ProgressView().controlSize(.small).frame(minWidth: 160) }
                    else if let p = license.proProduct, !p.displayPrice.isEmpty { Text("Unlock Pro — \(p.displayPrice)").frame(minWidth: 160) }
                    else { Text("Unlock Pro").frame(minWidth: 160) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(license.isPurchasing || license.state.isPaid)
                Button("Restore Purchases") {
                    Task {
                        switch await license.restorePurchases() {
                        case .success(true): model.paywall = nil
                        case .success(false): message = "No previous DiskLens Pro purchase was found for this Apple Account."
                        case .failure(let e): message = "Restore failed: \(e.localizedDescription)"
                        }
                    }
                }
            }
            Text(license.proProduct == nil
                 ? (license.productsError ?? "Loading the price from the App Store…")
                 : "One-time purchase. Shared with your Family Sharing group. Price shown in your App Store currency.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder var directActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(AppLinks.purchase) } label: { Text("Buy DiskLens Pro").frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                switch license.trial {
                case .notStarted:
                    Button("Start 7-Day Free Trial") {
                        do { try license.startTrial(); model.paywall = nil } catch { message = "Could not start the trial: \(error.localizedDescription)" }
                    }
                case .active(let exp):
                    Text("Trial active until \(exp.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Theme.good)
                case .expired:
                    Text("Your trial has ended.").font(.caption).foregroundStyle(Theme.muted)
                case .unavailable:
                    Text("Trial unavailable (Keychain locked).").font(.caption).foregroundStyle(Theme.warn)
                }
                Button("Enter License Key…") { showKeyField.toggle() }
            }
            if showKeyField {
                LicenseKeyEntry(text: $keyText) { ok, msg in message = msg; if ok { model.paywall = nil } }
            }
        }
    }
}

/// Paste-a-key field shared by the paywall and Settings ▸ License (direct edition).
struct LicenseKeyEntry: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    var completion: (Bool, String?) -> Void

    var body: some View {
        HStack(alignment: .top) {
            TextField("License key", text: $text, prompt: Text(verbatim: "DLK1.…"), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4).font(.caption.monospaced()).textFieldStyle(.roundedBorder)
                .accessibilityLabel("License key")
            Button("Activate") {
                do {
                    let p = try model.license.activate(licenseKey: text)
                    text = ""
                    completion(true, "Activated \(p.edition == .team ? "Team (\(p.seats) seats)" : "Pro") license.")
                } catch let e as LicenseKeyError {
                    completion(false, e.description)
                } catch {
                    completion(false, "Could not save the license: \(error.localizedDescription)")
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// Small "PRO" capsule for locked controls.
struct ProBadge: View {
    var body: some View {
        Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.8)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.accent.opacity(0.22))).foregroundStyle(Theme.accent)
            .accessibilityLabel("Pro feature")
    }
}

/// Placeholder for a Pro-only panel: says what it does and offers the paywall, never nags.
struct LockedFeatureCard: View {
    @Environment(AppModel.self) private var model
    var feature: Feature
    var trigger: PaywallContext.Trigger
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { Text(feature.displayName).font(.callout.bold()); ProBadge() }
                Text(detail ?? feature.summary).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Learn More…") { model.showPaywall(trigger) }.controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

/// Settings ▸ License.
struct LicenseSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyText = ""
    @State private var message: String?

    var body: some View {
        let license = model.license
        Form {
            Section("Status") {
                LabeledContent("Edition", value: license.edition == .appStore ? "Mac App Store" : "Direct download")
                LabeledContent("Plan", value: planText(license))
                if !license.state.isPaid && license.freeAllowance.remaining > 0 {
                    LabeledContent("Free cleanup run", value: "1 available (up to \(ByteFormat.gb(FreeCleanupAllowance.capBytes)))")
                }
                if let p = license.licenseProblem { Text(p).font(.caption).foregroundStyle(Theme.warn) }
            }
            if license.edition == .appStore {
                Section("App Store") {
                    HStack {
                        Button(license.state.isPaid ? "Pro Unlocked" : "Upgrade to Pro…") { model.showPaywall(.settings) }
                            .disabled(license.state.isPaid)
                        Button("Restore Purchases") {
                            Task {
                                switch await license.restorePurchases() {
                                case .success(true): message = "DiskLens Pro restored."
                                case .success(false): message = "No previous purchase found for this Apple Account."
                                case .failure(let e): message = "Restore failed: \(e.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            } else {
                Section("License key") {
                    if let lic = license.activeLicense {
                        LabeledContent("License", value: "\(lic.edition == .team ? "Team · \(lic.seats) seats" : "Pro") · \(lic.licenseID.prefix(8))…")
                        if let e = lic.expiresAt { LabeledContent("Renews / expires", value: e.formatted(date: .abbreviated, time: .omitted)) }
                        Button("Deactivate on This Mac", role: .destructive) {
                            do { try license.deactivateLicense(); message = "License removed from this Mac." } catch { message = error.localizedDescription }
                        }
                    } else {
                        LicenseKeyEntry(text: $keyText) { _, msg in message = msg }
                        HStack {
                            Button("Buy a License…") { NSWorkspace.shared.open(AppLinks.purchase) }
                            if case .notStarted = license.trial {
                                Button("Start 7-Day Free Trial") { try? license.startTrial() }
                            }
                        }
                    }
                    Text("Keys are verified offline with an Ed25519 signature; nothing is sent anywhere. The key is stored in ~/Library/Application Support/DiskLens/license.dlk and shared with disklens-cli.")
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message { Text(message).font(.caption) }
        }
        .formStyle(.grouped)
    }

    func planText(_ l: LicenseService) -> String {
        switch l.state {
        case .free: return "Free"
        case .trial(let e): return "Pro trial until \(e.formatted(date: .abbreviated, time: .shortened))"
        case .pro(let s): return "Pro (\(s.label))"
        }
    }
}

/// Settings ▸ Schedule & Alerts (Pro).
struct ScheduleSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginError: String?
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        @Bindable var settings = model.settings
        let unlocked = model.license.isEnabled(.scheduling)
        Form {
            if !unlocked {
                Section { LockedFeatureCard(feature: .scheduling, trigger: .scheduling) }
            }
            Section("Background scans") {
                Picker("Scan automatically", selection: Binding(get: { settings.schedule.frequency },
                                                                set: { settings.schedule.frequency = $0 })) {
                    ForEach(ScanFrequency.allCases) { Text($0.label).tag($0) }
                }
                Picker("Preferred time", selection: Binding(get: { settings.schedule.preferredHour },
                                                            set: { settings.schedule.preferredHour = $0 })) {
                    ForEach([6, 8, 10, 12, 14, 18, 22], id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Text("Scheduled scans are read-only and run while DiskLens or its menu-bar item is running. They never clean anything.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Toggle("Open DiskLens at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription; loginOn = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme.warn) }
            }
            .disabled(!unlocked)
            Section("Menu bar & alerts") {
                Toggle("Show free space in the menu bar", isOn: $settings.menuBarEnabled)
                Toggle("Alert me when free space is low", isOn: $settings.lowSpaceAlerts)
                    .onChange(of: settings.lowSpaceAlerts) { _, on in if on { Task { _ = await Notifier.requestAuthorization() } } }
                HStack {
                    Text("Alert below")
                    Slider(value: $settings.lowSpaceThresholdGB, in: 5...100, step: 5)
                    Text("\(Int(settings.lowSpaceThresholdGB)) GB").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            .disabled(!unlocked)
        }
        .formStyle(.grouped)
    }
}

/// The app icon; in bare SwiftPM builds (no bundle icon) falls back to the repository's icon file.
enum AppIcon {
    @MainActor static var image: NSImage {
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil { return NSApp.applicationIconImage }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon-1024.png")
        return NSImage(contentsOf: repo) ?? NSApp.applicationIconImage
    }
}
