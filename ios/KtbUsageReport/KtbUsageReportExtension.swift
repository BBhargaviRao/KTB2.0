import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct KtbUsageReportExtension: DeviceActivityReportExtension {
  var body: some DeviceActivityReportScene {
    KtbUsageReportScene { _ in
      Color.clear // invisible — this extension only writes data, no UI needed
    }
  }
}
