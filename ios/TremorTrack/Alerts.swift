// Local notifications on the iPhone, e.g. "check your watch strap". Local notifications need no push server
// and no paid developer account. Shown as banners even while the app is open.
import UserNotifications

@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    func install() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Decides when repeated refusals from the watch mean the strap is loose or the watch is off the wrist.
/// Only live windows count: backfilled all-day windows are hours old by the time they arrive.
struct StrapMonitor {
    /// shortcut: 3 noisy windows in a row (30 s) for a loose strap; 6 flat windows (1 min) before asking whether the
    /// watch is on the wrist, because a very still wrist with no tremor can also read as flat. Tune on real wearers.
    static let noisyInARow = 3, flatInARow = 6
    static let cooldown: TimeInterval = 30 * 60

    private var noisy = 0, flat = 0
    private var lastAlert = Date.distantPast

    /// Returns the alert to show, if any.
    mutating func check(_ reason: String?, now: Date = .now) -> (title: String, body: String)? {
        noisy = reason == "motion_artefact_or_noise" ? noisy + 1 : 0
        flat = reason == "no_motion_signal" ? flat + 1 : 0
        guard now.timeIntervalSince(lastAlert) > Self.cooldown else { return nil }
        if noisy >= Self.noisyInARow {
            noisy = 0; lastAlert = now
            return ("Check your watch strap", "Your watch seems loose, so Kineon has paused readings. Tighten the strap and readings start again.")
        }
        if flat >= Self.flatInARow {
            flat = 0; lastAlert = now
            return ("Is your watch on?", "Kineon isn't picking up any movement. Check the watch is on your wrist and snug.")
        }
        return nil
    }
}
