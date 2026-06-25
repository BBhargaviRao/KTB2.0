import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI
import Foundation

extension DeviceActivityReport.Context {
  static let ktbReport = Self("KTB Usage Report")
}

struct KtbConfig {}

struct KtbUsageReportScene: DeviceActivityReportScene {
  let context: DeviceActivityReport.Context = .ktbReport
  let content: (KtbConfig) -> Color

  func makeConfiguration(
    representing data: DeviceActivityResults<DeviceActivityData>
  ) async -> KtbConfig {

    // iOS 26: ActivitySegment exposes categories, not individual apps.
    // We aggregate time per category across all segments.
    var categoryTotals: [String: Int] = [:]

    for await activityData in data {
      for await segment in activityData.activitySegments {
        for await cat in segment.categories {
          let mins = Int(cat.totalActivityDuration / 60)
          guard mins >= 1 else { continue }
          let label = cat.category.localizedDisplayName ?? "Other"
          categoryTotals[label, default: 0] += mins
        }
      }
    }

    // Convert to the same shape the Flutter side expects
    let items: [[String: Any]] = categoryTotals
      .sorted { $0.value > $1.value }
      .map { label, mins in
        [
          "packageName":   label,
          "appName":       label,
          "categoryLabel": label,
          "timeMinutes":   mins,
        ]
      }

    if let defaults = UserDefaults(suiteName: "group.com.ktb.kidstechbalance2"),
       let encoded  = try? JSONSerialization.data(withJSONObject: items) {
      defaults.set(encoded, forKey: "ktb_usage_today")
      defaults.set(Date().timeIntervalSince1970, forKey: "ktb_usage_updated_at")
    }

    return KtbConfig()
  }
}
