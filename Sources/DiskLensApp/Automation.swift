import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import DiskLensCore

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { switch self { case .system: return "Match System"; case .light: return "Light"; case .dark: return "Dark" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

/// User preferences (UserDefaults). Entitlement data never lives here — see LicenseService.
@MainActor
@Observable
final class AppSettings {
    private let d = UserDefaults.standard
    var schedule: ScanSchedule {
        didSet { d.set(schedule.frequency.rawValue, forKey: "schedule.frequency"); d.set(schedule.preferredHour, forKey: "schedule.hour") }
    }
    var menuBarEnabled: Bool { didSet { d.set(menuBarEnabled, forKey: "menuBar.enabled") } }
    var lowSpaceAlerts: Bool { didSet { d.set(lowSpaceAlerts, forKey: "lowSpace.alerts") } }
    var lowSpaceThresholdGB: Double { didSet { d.set(lowSpaceThresholdGB, forKey: "lowSpace.thresholdGB") } }
    var appearance: AppearanceSetting { didSet { d.set(appearance.rawValue, forKey: "appearance") } }

    init() {
        schedule = ScanSchedule(frequency: ScanFrequency(rawValue: d.string(forKey: "schedule.frequency") ?? "") ?? .off,
                                preferredHour: d.object(forKey: "schedule.hour") as? Int ?? 10)
        menuBarEnabled = d.object(forKey: "menuBar.enabled") as? Bool ?? true
        lowSpaceAlerts = d.object(forKey: "lowSpace.alerts") as? Bool ?? false
        lowSpaceThresholdGB = d.object(forKey: "lowSpace.thresholdGB") as? Double ?? 20
        appearance = AppearanceSetting(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
    }
}

/// Runs the Pro schedule while DiskLens (or its menu-bar extra) is running. Uses
/// NSBackgroundActivityScheduler, so macOS picks an energy-friendly moment. Scheduled work is a
/// read-only scan plus a free-space check; it never cleans anything.
@MainActor
final class BackgroundScheduler {
    private var activity: NSBackgroundActivityScheduler?

    func start(model: AppModel) {
        guard activity == nil else { return }
        let a = NSBackgroundActivityScheduler(identifier: "com.akshaykulkarni.DiskLens.scheduled-check")
        a.repeats = true
        a.interval = 15 * 60
        a.tolerance = 5 * 60
        a.qualityOfService = .utility
        a.schedule { [weak model] done in
            Task { @MainActor in
                model?.scheduledTick()
                done(.finished)
            }
        }
        activity = a
    }

    func stop() { activity?.invalidate(); activity = nil }
}

enum Notifier {
    /// Asks for notification permission (only when the user turns low-space alerts on).
    static func requestAuthorization() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func lowSpace(available: Int64, threshold: Int64, reclaimable: Int64) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Low disk space")
        var body = String(localized: "Only \(ByteFormat.gb(available)) free (your alert threshold is \(ByteFormat.gb(threshold))).")
        if reclaimable > 0 { body += " " + String(localized: "Your latest scan estimates \(ByteFormat.gb(reclaimable)) can be reclaimed safely.") }
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low-space", content: c, trigger: nil))
    }
}

/// "Open at Login" via SMAppService (the user turns it on; macOS lists it in Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
