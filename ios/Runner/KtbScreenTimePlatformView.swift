import Flutter
import UIKit
import DeviceActivity
import FamilyControls
import SwiftUI

@available(iOS 16.0, *)
class KtbScreenTimePlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return KtbScreenTimePlatformView(frame: frame, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

@available(iOS 16.0, *)
class KtbScreenTimePlatformView: NSObject, FlutterPlatformView {
  private let hostingController: UIHostingController<AnyView>

  init(frame: CGRect, args: Any?) {
    let hc: UIHostingController<AnyView>

    if AuthorizationCenter.shared.authorizationStatus == .approved {
      let cal = Calendar.current

      // Use date passed from Flutter, defaulting to today
      let dateMillis = (args as? [String: Any])?["dateMillis"] as? Double
      let date = dateMillis.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()

      let dayStart = cal.startOfDay(for: date)
      let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart)!
      // For today, don't request data past the current moment
      let end = cal.isDateInToday(date) ? min(dayEnd, Date()) : dayEnd

      let filter = DeviceActivityFilter(
        segment: .daily(during: DateInterval(start: dayStart, end: end)),
        users:   .all,
        devices: .init([.iPhone, .iPad])
      )
      let report = DeviceActivityReport(.init("KTB Usage Report"), filter: filter)
      hc = UIHostingController(rootView: AnyView(report))
      hc.view.frame = frame
      hc.view.backgroundColor = .clear
    } else {
      hc = UIHostingController(rootView: AnyView(Color.clear))
    }

    hostingController = hc
    super.init()
  }

  func view() -> UIView { hostingController.view }
}
