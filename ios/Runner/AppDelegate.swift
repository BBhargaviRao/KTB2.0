import Flutter
import UIKit
import SwiftUI
import FamilyControls
import DeviceActivity
import ManagedSettings

// Shared App Group — used by the KtbActivityMonitor extension to write real
// screen time minutes, and read here by the main app.
private let kGroupId   = "group.com.ktb.kidstechbalance2"
private let kRealMins  = "ktb_real_minutes_"

@available(iOS 16.0, *)
extension DeviceActivityName {
  static let ktbDaily = Self("ktb.daily")
}

// ── FamilyActivityPicker hosting ─────────────────────────────────────────────
@available(iOS 16.0, *)
class FamilyPickerVM: ObservableObject {
  // includeEntireCategory: true makes picking a whole category populate
  // applicationTokens with every app currently in it (not just an abstract
  // categoryToken) — required because .all(except:) can only exempt individual
  // ApplicationTokens. Matches ~/Desktop/Kids Tech Balance/Kids_Tech_BalanceApp.swift.
  @Published var selection          = FamilyActivitySelection(includeEntireCategory: true)
  @Published var isPickerPresented  = false
  var onConfirm: (() -> Void)?
  var onCancel:  (() -> Void)?
}

@available(iOS 16.0, *)
struct FamilyPickerScreen: View {
  @ObservedObject var vm: FamilyPickerVM

  var body: some View {
    NavigationView {
      VStack(spacing: 24) {
        Spacer()
        Image(systemName: "apps.iphone")
          .font(.system(size: 52))
          .foregroundColor(.purple)
        Text("Select Allowed Apps")
          .font(.title2).bold()
        Text("During this session the child will only be able to open the apps you choose here.")
          .multilineTextAlignment(.center)
          .foregroundColor(.secondary)
          .padding(.horizontal, 32)
        Button {
          vm.isPickerPresented = true
        } label: {
          Label("Choose Apps & Categories", systemImage: "plus.circle.fill")
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.purple)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .padding(.horizontal, 32)
        .familyActivityPicker(isPresented: $vm.isPickerPresented, selection: $vm.selection)
        if !vm.selection.applicationTokens.isEmpty || !vm.selection.categoryTokens.isEmpty {
          let appCount = vm.selection.applicationTokens.count
          let catCount = vm.selection.categoryTokens.count
          let labelText: String = appCount > 0 && catCount > 0
            ? "\(appCount) app(s) + \(catCount) category(s) selected"
            : appCount > 0
              ? "\(appCount) app(s) selected"
              : "All apps allowed (\(catCount) categories selected)"
          Label(labelText, systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
        }
        Spacer()
      }
      .navigationTitle("App Access")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { vm.onCancel?() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Confirm") {
            // Persist the selection in the App Group so the extension,
            // applySessionRestrictions (shield), and startScreenTimeMonitoring
            // (screen-time-limit progress bar) can all read it without the
            // main app open. The same session app selection now drives both
            // blocking and the limit progress bar — no separate picker.
            if let data = try? JSONEncoder().encode(vm.selection) {
              UserDefaults(suiteName: kGroupId)?.set(data, forKey: "ktb_app_selection")
            }
            vm.onConfirm?()
          }
          .bold()
          .disabled(vm.selection.applicationTokens.isEmpty && vm.selection.categoryTokens.isEmpty)
        }
      }
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {

  private static let kActiveSecs   = "ktb_active_secs_"
  private static let kFgStart      = "ktb_fg_start"

  // ── Session timer keys ────────────────────────────────────────────────────
  // ktb_sess_start_ms  : Double — session start unix ms (from Firestore)
  // ktb_sess_paused_s  : Double — total background seconds accumulated so far
  // ktb_sess_bg_ts     : Double — timestamp when app went to background (0 if fg)
  private static let kSessStartMs = "ktb_sess_start_ms"
  private static let kSessPausedS = "ktb_sess_paused_s"
  private static let kSessBgTs    = "ktb_sess_bg_ts"

  // ── Foreground-only accumulation ─────────────────────────────────────────
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    UserDefaults.standard.set(Date(), forKey: Self.kFgStart)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    Self.flushForegroundSeconds()
  }

  private static func flushForegroundSeconds() {
    let defaults = UserDefaults.standard
    guard let start = defaults.object(forKey: kFgStart) as? Date else { return }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let dateKey  = f.string(from: Date())
    let elapsed  = max(0, Int(Date().timeIntervalSince(start)))
    let existing = defaults.integer(forKey: kActiveSecs + dateKey)
    defaults.set(existing + elapsed, forKey: kActiveSecs + dateKey)
    defaults.removeObject(forKey: kFgStart)
  }

  private static func foregroundMinutes(dateKey: String) -> Int {
    let defaults = UserDefaults.standard
    var totalSecs = defaults.integer(forKey: kActiveSecs + dateKey)
    if let start = defaults.object(forKey: kFgStart) as? Date {
      totalSecs += max(0, Int(Date().timeIntervalSince(start)))
    }
    return totalSecs / 60
  }

  // ── Best available screen time minutes ────────────────────────────────────
  // Prefers data written by KtbActivityMonitor extension (real Screen Time).
  // Falls back to foreground-only timer if the monitor extension isn't active.
  @available(iOS 16.0, *)
  private static func bestMinutes(dateKey: String) -> Int {
    let real = UserDefaults(suiteName: kGroupId)?.integer(forKey: kRealMins + dateKey) ?? 0
    return real > 0 ? real : foregroundMinutes(dateKey: dateKey)
  }

  // ── Shared FamilyActivityPicker presentation ──────────────────────────────
  @available(iOS 16.0, *)
  @MainActor
  private func presentFamilyPicker(result: @escaping FlutterResult) {
    let vm     = FamilyPickerVM()
    let screen = FamilyPickerScreen(vm: vm)
    let hostVC = UIHostingController(rootView: screen)
    hostVC.modalPresentationStyle = .formSheet
    hostVC.isModalInPresentation  = false
    vm.onConfirm = {
      hostVC.dismiss(animated: true)
      result(true)
    }
    vm.onCancel = {
      hostVC.dismiss(animated: true)
      result(false)
    }
    var top: UIViewController? = self.window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    top?.present(hostVC, animated: true)
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let controller = window?.rootViewController as! FlutterViewController

    // Request Family Controls authorization at launch, matching the proven
    // pattern in ~/Desktop/Kids Tech Balance/Kids_Tech_BalanceApp.swift —
    // don't rely solely on a lazy request right before the picker opens.
    if #available(iOS 16.0, *) {
      Task { @MainActor in
        do {
          try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
          print("KTB: Family Controls authorization failed at launch: \(error)")
        }
      }
    }

    // ── Screen Time channel ────────────────────────────────────────────────
    FlutterMethodChannel(name: "ktb2/screen_time", binaryMessenger: controller.binaryMessenger)
      .setMethodCallHandler { call, result in
        if #available(iOS 16.0, *) {
          switch call.method {

          case "isAuthorized":
            result(AuthorizationCenter.shared.authorizationStatus == .approved)

          case "requestAuthorization":
            Task { @MainActor in
              do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                result(true)
              } catch {
                result(FlutterError(code: "AUTH_FAILED",
                                    message: error.localizedDescription,
                                    details: nil))
              }
            }

          case "getVendorId":
            result(UIDevice.current.identifierForVendor?.uuidString ?? "")

          case "getIosSessionMinutes":
            let dateKey = (call.arguments as? [String: Any])?["dateKey"] as? String ?? ""
            result(Self.bestMinutes(dateKey: dateKey))

          case "startScreenTimeMonitoring":
            // Sets up DeviceActivityCenter with threshold events.
            // The KtbActivityMonitor extension fires at each threshold and writes
            // cumulative minutes to both App Group AND Firestore REST API directly.
            let args         = call.arguments as? [String: Any]
            let limitMinutes = args?["limitMinutes"] as? Int    ?? 120
            let dateKey      = args?["dateKey"]      as? String ?? ""
            let familyId     = args?["familyId"]     as? String ?? ""

            // Store context in App Group so the extension can read it without SDK.
            let grp = UserDefaults(suiteName: kGroupId)
            grp?.set(limitMinutes, forKey: "ktb_limit_\(dateKey)")
            if !familyId.isEmpty { grp?.set(familyId, forKey: "ktb_family_id") }

            let center = DeviceActivityCenter()
            center.stopMonitoring([.ktbDaily])

            // Clear the App Group session counter so the extension starts from 0
            // for this session (prevents stale data from a previous session leaking in).
            grp?.removeObject(forKey: kRealMins + dateKey)
            grp?.removeObject(forKey: "ktb_last_interval_clear")

            // Read the same session app selection used for ManagedSettings
            // blocking (ktb_app_selection) — whatever apps were most recently
            // chosen when a KTB Session was set up are automatically what
            // counts toward the screen-time limit too, no separate picker.
            // Non-empty tokens are required on iOS 26+ for threshold events
            // to fire — empty sets don't trigger the extension. ManagedSettings
            // (not DeviceActivityMonitor) handles app blocking; DeviceActivity
            // Monitor never auto-blocks apps on threshold.
            var appTokens: Set<ApplicationToken>      = []
            var catTokens: Set<ActivityCategoryToken> = []
            if let selData = grp?.data(forKey: "ktb_app_selection"),
               let sel     = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selData) {
              appTokens = sel.applicationTokens
              catTokens = sel.categoryTokens
            }

            // No session has ever been set up on this device yet — nothing to
            // monitor. Fail clearly instead of silently starting a no-op
            // monitor with empty tokens (which iOS 26+ never fires anyway).
            if appTokens.isEmpty && catTokens.isEmpty {
              UserDefaults(suiteName: kGroupId)?.set(
                "err:no ktb_app_selection yet", forKey: "ktb_monitor_status")
              result(false)
              return
            }

            // 1-minute thresholds up to limitMinutes + 30, capped at 360 min —
            // gives the parent's dashboard near-live updates instead of waiting
            // up to 5 minutes. DeviceActivityCenter only supports a limited
            // number of events per monitored activity, so the step size widens
            // automatically for longer sessions to stay under that cap while
            // still using true 1-minute steps for shorter ones.
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            let maxMin = min(limitMinutes + 30, 360)
            let maxEvents = 20
            let step = max(1, Int(ceil(Double(maxMin) / Double(maxEvents))))
            for min in stride(from: step, through: maxMin, by: step) {
              let name = DeviceActivityEvent.Name("ktb_min_\(min)")
              events[name] = DeviceActivityEvent(
                applications: appTokens,
                categories:   catTokens,
                webDomains:   [],
                threshold:    DateComponents(minute: min)
              )
            }

            // Start the interval NOW so thresholds count usage from session
            // start, not from midnight. A midnight-to-midnight schedule means
            // events that were already crossed earlier in the day never re-fire,
            // making the extension appear silent if the child already used the
            // device before the session began.
            let nowComps = Calendar.current.dateComponents(
              [.hour, .minute, .second], from: Date())
            let schedule = DeviceActivitySchedule(
              intervalStart: nowComps,
              intervalEnd:   DateComponents(hour: 23, minute: 59, second: 59),
              repeats: false
            )

            do {
              try center.startMonitoring(.ktbDaily, during: schedule, events: events)
              // Write success marker so getIosSessionMinutes can surface it.
              UserDefaults(suiteName: kGroupId)?.set("ok", forKey: "ktb_monitor_status")
              result(true)
            } catch {
              UserDefaults(suiteName: kGroupId)?.set(
                "err:\(error.localizedDescription)", forKey: "ktb_monitor_status")
              result(false)
            }

          case "resetIosSessionCounter":
            let dateKey = (call.arguments as? [String: Any])?["dateKey"] as? String ?? ""
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.kActiveSecs + dateKey)
            // Also clear any monitor data so the bar resets cleanly.
            UserDefaults(suiteName: kGroupId)?.removeObject(forKey: kRealMins + dateKey)
            if defaults.object(forKey: Self.kFgStart) != nil {
              defaults.set(Date(), forKey: Self.kFgStart)
            }
            result(nil)

          case "getAppGroupMinutes":
            // Reads the real-minutes counter written by KtbActivityMonitor extension
            // to the shared App Group. The main app relays this to Firestore via
            // Firebase SDK (more reliable than the extension's URLSession REST call).
            let agDateKey = (call.arguments as? [String: Any])?["dateKey"] as? String ?? ""
            let agMins = UserDefaults(suiteName: kGroupId)?.integer(forKey: kRealMins + agDateKey) ?? 0
            result(agMins)

          case "getIosUsageFromKeychain":
            // Kept for legacy; keychain writes from extension are sandbox-blocked.
            result(nil)

          // ── Session: background-pause-aware elapsed timer ─────────────
          // Stores the session start millis and resets accumulated BG time.
          case "startSessionTimer":
            let startMs = (call.arguments as? [String: Any])?["startMillis"] as? Double ?? 0
            let ud = UserDefaults.standard
            ud.set(startMs, forKey: Self.kSessStartMs)
            ud.set(0.0,     forKey: Self.kSessPausedS)
            ud.removeObject(forKey: Self.kSessBgTs)
            result(nil)

          // Returns elapsed minutes = wall-clock − background seconds.
          // If app is currently in background, adds the ongoing BG duration too.
          case "getSessionElapsedMinutes":
            let ud      = UserDefaults.standard
            let startMs = ud.double(forKey: Self.kSessStartMs)
            guard startMs > 0 else { result(0); break }
            let wallElapsed = Date().timeIntervalSince1970 - startMs / 1000.0
            var paused      = ud.double(forKey: Self.kSessPausedS)
            let bgTs        = ud.double(forKey: Self.kSessBgTs)
            if bgTs > 0 { paused += max(0, Date().timeIntervalSince1970 - bgTs) }
            result(max(0, Int((wallElapsed - paused) / 60)))

          case "clearSessionTimer":
            [Self.kSessStartMs, Self.kSessPausedS, Self.kSessBgTs].forEach {
              UserDefaults.standard.removeObject(forKey: $0)
            }
            result(nil)

          // ── Session: show native FamilyActivityPicker ─────────────────
          // Presents a UIHostingController so the parent (holding the child's
          // device) can pick which apps are allowed during the session.
          // The selection is stored in the App Group UserDefaults so
          // applySessionRestrictions can read it without the app being open.
          case "showFamilyActivityPicker":
            Task { @MainActor in
              self.presentFamilyPicker(result: result)
            }

          // ── Session: apply ManagedSettings restrictions ───────────────
          case "applySessionRestrictions":
            let grp = UserDefaults(suiteName: kGroupId)
            if let data = grp?.data(forKey: "ktb_app_selection"),
               let sel  = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
              let store = ManagedSettingsStore()
              store.clearAllSettings()
              // ManagedSettings only supports allow-listing by ApplicationToken.
              // ActivityCategoryToken (from category picks) is not accepted by
              // applicationCategories.all(except:) — it only takes ApplicationToken.
              // Block everything except the specifically-selected apps. Apply this
              // unconditionally (even if applicationTokens is empty, i.e. only
              // categories were picked) — matching the proven-working reference
              // implementation in ~/Desktop/Kids Tech Balance/Models/DataModel.swift,
              // which never skips shielding based on token-set emptiness.
              store.shield.applicationCategories = .all(except: sel.applicationTokens)
              store.shield.webDomainCategories = .all()
              result(true)
            } else {
              result(false)
            }

          // ── Session: lift all restrictions ────────────────────────────
          case "clearSessionRestrictions":
            ManagedSettingsStore().clearAllSettings()
            UserDefaults(suiteName: kGroupId)?.removeObject(forKey: "ktb_app_selection")
            result(nil)

          default:
            result(FlutterMethodNotImplemented)
          }
        } else {
          result(FlutterError(code: "UNSUPPORTED", message: "Requires iOS 16+", details: nil))
        }
      }

    // ── Screen Time platform view (renders DeviceActivityReport) ──────────
    if #available(iOS 16.0, *) {
      registrar(forPlugin: "KtbScreenTime")?.register(
        KtbScreenTimePlatformViewFactory(),
        withId: "ktb_screen_time_chart"
      )
    }

    GeneratedPluginRegistrant.register(with: self)

    // Pause/resume the session timer whenever the screen locks/unlocks so that
    // getSessionElapsedMinutes subtracts device-off time from the elapsed total.
    NotificationCenter.default.addObserver(
        self, selector: #selector(sessionTimerPause),
        name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    NotificationCenter.default.addObserver(
        self, selector: #selector(sessionTimerResume),
        name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Screen locked — record timestamp so we can subtract the off-screen duration later.
  @objc private func sessionTimerPause() {
    let ud = UserDefaults.standard
    guard ud.double(forKey: Self.kSessStartMs) > 0,
          ud.double(forKey: Self.kSessBgTs) == 0 else { return }
    ud.set(Date().timeIntervalSince1970, forKey: Self.kSessBgTs)
  }

  // Screen unlocked — add the off-screen seconds to the running paused total.
  @objc private func sessionTimerResume() {
    let ud   = UserDefaults.standard
    let bgTs = ud.double(forKey: Self.kSessBgTs)
    guard bgTs > 0 else { return }
    let elapsed  = max(0, Date().timeIntervalSince1970 - bgTs)
    let existing = ud.double(forKey: Self.kSessPausedS)
    ud.set(existing + elapsed, forKey: Self.kSessPausedS)
    ud.removeObject(forKey: Self.kSessBgTs)
  }
}
