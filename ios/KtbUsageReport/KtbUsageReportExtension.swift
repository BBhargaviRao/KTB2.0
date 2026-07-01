import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct KtbUsageReportExtension: DeviceActivityReportExtension {
  var body: some DeviceActivityReportScene {
    KtbUsageReportScene { config in
      KtbBarChart(categories: config.categories)
    }
  }
}
