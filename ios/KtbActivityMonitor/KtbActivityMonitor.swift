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

        let iso = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "fields": [
                "screenTimeUsedMinutes": ["integerValue": "\(minutes)"],
                "screenTimeLastUpdatedAt": ["timestampValue": iso],
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        // Even blocking synchronously on URLSession.shared wasn't enough — the
        // whole extension PROCESS gets torn down by the OS almost immediately
        // after eventDidReachThreshold fires (confirmed: the local App Group
        // write below always lands correctly, but this REST call never did,
        // while KTB was force-quit). A background URLSession hands the
        // transfer to the OS's own upload daemon (nsurlsessiond), which owns
        // it independently of this process and keeps retrying until it
        // succeeds — the Apple-sanctioned mechanism for network work that
        // must outlive a short-lived extension. Background uploads require
        // the body as a file on disk, not in-memory Data.
        let attemptId = UUID().uuidString
        guard let tmpURL = try? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ktb_st_\(dateKey)_\(minutes)_\(attemptId)")
            try bodyData.write(to: url)
            return url
        }() else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Identifier includes a fresh UUID per attempt — reusing an identifier
        // still associated with a pending/in-flight background session (e.g.
        // if the OS redelivers the same threshold callback) silently fails to
        // register a second transfer, which would drop that retry with no
        // signal at all. A unique identifier per attempt guarantees every
        // write gets its own independent background transfer.
        let identifier = "com.ktb.kidstechbalance2.screentime.\(dateKey).\(minutes).\(attemptId)"
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = false
        config.isDiscretionary = false
        let delegate = BackgroundUploadDelegate(groupId: groupId, dateKey: dateKey, minutes: minutes)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.uploadTask(with: req, fromFile: tmpURL).resume()
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    private func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// Gives the background-session fallback a completion signal instead of
// firing blind — writes a confirmation or an error string into the App
// Group so a stalled/failed upload is visible (via Xcode's Console, or a
// future debug screen) instead of the parent's bar just silently going
// stale with no way to tell why. The OS may invoke this well after the
// extension process that created the session has been torn down — that's
// expected; background sessions are designed to survive their creator.
private final class BackgroundUploadDelegate: NSObject, URLSessionTaskDelegate {
    private let groupId: String
    private let dateKey: String
    private let minutes: Int

    init(groupId: String, dateKey: String, minutes: Int) {
        self.groupId = groupId
        self.dateKey = dateKey
        self.minutes = minutes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let defaults = UserDefaults(suiteName: groupId)
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if error == nil, let status, (200...299).contains(status) {
            defaults?.set(minutes, forKey: "ktb_last_confirmed_minutes_\(dateKey)")
            defaults?.set(Date().timeIntervalSince1970, forKey: "ktb_last_confirmed_at")
        } else {
            defaults?.set(
                "min=\(minutes) status=\(status ?? -1) err=\(error?.localizedDescription ?? "none")",
                forKey: "ktb_last_upload_error")
        }
        session.finishTasksAndInvalidate()
    }
}
