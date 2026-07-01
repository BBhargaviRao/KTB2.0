import DeviceActivity
import Foundation

// DeviceActivityMonitor fires when device screen time crosses each threshold.
// On each fire we:
//   1. Write the cumulative minutes to the shared App Group (fast local read).
//   2. ALSO write directly to Firestore via REST API so the parent dashboard
//      receives live updates even when the KTB app is closed.

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let groupId       = "group.com.ktb.kidstechbalance2"
    private let keyBase       = "ktb_real_minutes_"
    private let projectId     = "ktb2-kidstechbalance"
    private let firestoreKey  = "AIzaSyBwmXPgchb0wWni_ViA-qCWONg-pVSyZP0"

    // ── Interval start ─────────────────────────────────────────────────────
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // Only clear the daily counter when the date actually changes — NOT
        // on every mid-day startMonitoring call (which also triggers this).
        let today    = todayKey()
        let clearKey = "ktb_last_interval_clear"
        let defaults = UserDefaults(suiteName: groupId)
        if defaults?.string(forKey: clearKey) != today {
            defaults?.removeObject(forKey: keyBase + today)
            defaults?.set(today, forKey: clearKey)
        }
    }

    // ── Threshold reached ──────────────────────────────────────────────────
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)

        // Event name format: "ktb_min_45" → 45 minutes of screen time used.
        let parts = event.rawValue.split(separator: "_")
        guard let last = parts.last, let minutes = Int(last) else { return }

        let dateKey  = todayKey()
        let key      = keyBase + dateKey
        let defaults = UserDefaults(suiteName: groupId)

        // 1. App Group write (read by main app when it's open)
        let current = defaults?.integer(forKey: key) ?? 0
        if minutes > current {
            defaults?.set(minutes, forKey: key)
            // Force flush so the main app process reads the updated value
            // immediately rather than getting a stale cached value.
            defaults?.synchronize()
        }

        // 2. Firestore REST write (visible to parent even when KTB is closed)
        let familyId = defaults?.string(forKey: "ktb_family_id") ?? ""
        guard !familyId.isEmpty else { return }
        writeToFirestore(minutes: max(minutes, current), dateKey: dateKey, familyId: familyId)
    }

    // ── Interval end ───────────────────────────────────────────────────────
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
    }

    // ── Firestore REST helper ──────────────────────────────────────────────
    private func writeToFirestore(minutes: Int, dateKey: String, familyId: String) {
        // PATCH families/{familyId}/dashboard_days/{dateKey} with only
        // the screen-time fields — leaves all other fields untouched.
        let urlStr = "https://firestore.googleapis.com/v1/projects/\(projectId)" +
            "/databases/(default)/documents/families/\(familyId)" +
            "/dashboard_days/\(dateKey)" +
            "?key=\(firestoreKey)" +
            "&updateMask.fieldPaths=screenTimeUsedMinutes" +
            "&updateMask.fieldPaths=screenTimeLastUpdatedAt"

        guard let url = URL(string: urlStr) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let iso = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "fields": [
                "screenTimeUsedMinutes": ["integerValue": "\(minutes)"],
                "screenTimeLastUpdatedAt": ["timestampValue": iso],
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req).resume()
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    private func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
