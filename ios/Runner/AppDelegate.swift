import Flutter
import UIKit
import FamilyControls
import DeviceActivity
import SwiftUI

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var reportHostingController: UIHostingController<AnyView>?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let controller = window?.rootViewController as! FlutterViewController

    FlutterMethodChannel(name: "ktb2/screen_time", binaryMessenger: controller.binaryMessenger)
      .setMethodCallHandler { [weak self] call, result in
        switch call.method {

        case "isAuthorized":
          if #available(iOS 16.0, *) {
            let status = AuthorizationCenter.shared.authorizationStatus
            result(status == .approved)
          } else {
            result(false)
          }

        case "requestAuthorization":
          if #available(iOS 16.0, *) {
            Task { @MainActor in
              do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                result(true)
              } catch {
                result(FlutterError(code: "AUTH_FAILED", message: error.localizedDescription, details: nil))
              }
            }
          } else {
            result(FlutterError(code: "UNSUPPORTED", message: "Requires iOS 16+", details: nil))
          }

        case "refreshReport":
          if #available(iOS 16.0, *) {
            DispatchQueue.main.async {
              self?.triggerReportRefresh()
              result(nil)
            }
          } else {
            result(nil)
          }

        case "getDailyUsage":
          let defaults = UserDefaults(suiteName: "group.com.ktb.kidstechbalance2")
          if let data = defaults?.data(forKey: "ktb_usage_today"),
             let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            result(apps)
          } else {
            result([String]())
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @available(iOS 16.0, *)
  @MainActor
  private func triggerReportRefresh() {
    guard AuthorizationCenter.shared.authorizationStatus == .approved else { return }

    reportHostingController?.willMove(toParent: nil)
    reportHostingController?.view.removeFromSuperview()
    reportHostingController?.removeFromParent()
    reportHostingController = nil

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let end = min(calendar.date(byAdding: .day, value: 1, to: today)!, Date())

    let filter = DeviceActivityFilter(
      segment: .daily(during: DateInterval(start: today, end: end)),
      users: .all,
      devices: .init([.iPhone, .iPad])
    )

    let reportView = DeviceActivityReport(.init("KTB Usage Report"), filter: filter)
    let hostingVC = UIHostingController(rootView: AnyView(reportView))

    // 1×1 pt invisible — just enough to trigger the extension to process data
    hostingVC.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    hostingVC.view.alpha = 0.01

    if let rootVC = window?.rootViewController {
      rootVC.addChild(hostingVC)
      rootVC.view.addSubview(hostingVC.view)
      hostingVC.didMove(toParent: rootVC)
      reportHostingController = hostingVC
    }
  }
}
