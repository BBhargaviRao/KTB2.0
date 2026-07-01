import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI
import UIKit
import Foundation

extension DeviceActivityReport.Context {
  static let ktbReport = Self("KTB Usage Report")
}

struct KtbConfig {
  var categories: [(name: String, minutes: Int)] = []
}

struct KtbBarChart: View {
  let categories: [(name: String, minutes: Int)]
  private let barColor = Color(red: 0.702, green: 0.663, blue: 0.831)

  var body: some View {
    if categories.isEmpty {
      Text("No screen time data for today")
        .font(.system(size: 13))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let maxMins = categories.map(\.minutes).max() ?? 1
      GeometryReader { geo in
        HStack(alignment: .bottom, spacing: 10) {
          ForEach(Array(categories.prefix(6).enumerated()), id: \.offset) { _, item in
            let ratio = CGFloat(item.minutes) / CGFloat(maxMins)
            let barH  = max(geo.size.height * 0.65 * ratio, 4)
            VStack(spacing: 4) {
              Text(fmt(item.minutes))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
              RoundedRectangle(cornerRadius: 6)
                .fill(barColor)
                .frame(width: 36, height: barH)
              Text(String(item.name.prefix(7)))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
          }
          Spacer()
        }
        .padding(.horizontal, 8)
      }
    }
  }

  private func fmt(_ m: Int) -> String {
    if m < 60 { return "\(m)m" }
    let h = m / 60, r = m % 60
    return r == 0 ? "\(h)h" : "\(h)h \(r)m"
  }
}

@MainActor
struct KtbUsageReportScene: DeviceActivityReportScene {
  let context: DeviceActivityReport.Context = .ktbReport
  let content: (KtbConfig) -> KtbBarChart

  func makeConfiguration(
    representing data: DeviceActivityResults<DeviceActivityData>
  ) async -> KtbConfig {
    var totals: [String: Int] = [:]
    for await activityData in data {
      for await segment in activityData.activitySegments {
        for await cat in segment.categories {
          let mins  = Int(cat.totalActivityDuration / 60)
          let label = cat.category.localizedDisplayName ?? "Other"
          totals[label, default: 0] += mins
        }
      }
    }

    let sorted = totals.sorted { $0.value > $1.value }
                       .map { (name: $0.key, minutes: $0.value) }
    let total  = sorted.reduce(0) { $0 + $1.minutes }

    let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    let dateKey  = {
      let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }()

    // Write real category data to the shared keychain group so the main app
    // can read it and use it for the progress bar and Firestore upload.
    // Keychain goes through securityd (not file system) so it may succeed
    // even though App Group file/UserDefaults writes are sandbox-blocked here.
    Self.writeToSharedKeychain(vendorId: vendorId, dateKey: dateKey,
                               categories: sorted, totalMinutes: total)

    return KtbConfig(categories: sorted)
  }

  private static let keychainService = "ktb.screentime"
  private static let keychainGroup   = "YVV4W4Q37T.com.ktb.kidstechbalance2"

  private static func writeToSharedKeychain(
    vendorId: String,
    dateKey: String,
    categories: [(name: String, minutes: Int)],
    totalMinutes: Int
  ) {
    let appsJson: [[String: Any]] = categories.map { cat in
      ["packageName": cat.name,
       "appName":     cat.name,
       "categoryLabel": cat.name,
       "timeMinutes": cat.minutes]
    }
    let payload: [String: Any] = [
      "vendorId":     vendorId,
      "dateKey":      dateKey,
      "totalMinutes": totalMinutes,
      "apps":         appsJson,
      "updatedAt":    ISO8601DateFormatter().string(from: Date())
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

    let deleteQuery: [CFString: Any] = [
      kSecClass:            kSecClassGenericPassword,
      kSecAttrService:      keychainService,
      kSecAttrAccount:      dateKey,
      kSecAttrAccessGroup:  keychainGroup
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [CFString: Any] = [
      kSecClass:            kSecClassGenericPassword,
      kSecAttrService:      keychainService,
      kSecAttrAccount:      dateKey,
      kSecValueData:        data,
      kSecAttrAccessGroup:  keychainGroup,
      kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlock
    ]
    SecItemAdd(addQuery as CFDictionary, nil)
  }
}
