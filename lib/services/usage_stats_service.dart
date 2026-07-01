import 'dart:io';
import 'package:flutter/services.dart';

class AppUsageEntry {
  final String packageName;
  final String appName;
  final String categoryLabel;
  final int timeMinutes;

  const AppUsageEntry({
    required this.packageName,
    required this.appName,
    required this.categoryLabel,
    required this.timeMinutes,
  });
}

class UsageStatsService {
  static const _androidChannel = MethodChannel('ktb2/usage_stats');
  static const _iosChannel     = MethodChannel('ktb2/screen_time');

  static Future<bool> hasPermission() async {
    try {
      if (Platform.isAndroid) {
        return await _androidChannel.invokeMethod<bool>('hasPermission') ?? false;
      }
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<bool>('isAuthorized') ?? false;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> requestPermission() async {
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod('requestPermission');
      } else if (Platform.isIOS) {
        await _iosChannel.invokeMethod('requestAuthorization');
      }
    } catch (_) {}
  }

  static Future<String?> getVendorId() async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<String>('getVendorId');
      }
    } catch (_) {}
    return null;
  }

  // Returns foreground-only minutes for today on iOS (only counts while the
  // app is in the foreground; stops when the device is locked or put to sleep).
  static Future<int> getIosSessionMinutes(String dateKey) async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<int>(
              'getIosSessionMinutes', {'dateKey': dateKey}) ??
            0;
      }
    } catch (_) {}
    return 0;
  }

  // Starts DeviceActivity monitoring so the KtbActivityMonitor extension fires
  // at each 5-minute threshold and writes real screen time to Firestore + App Group.
  // familyId is stored in the App Group so the extension can write to the correct
  // Firestore path without needing a Firebase SDK.
  // Returns true if monitoring started successfully, false if it failed.
  static Future<bool> startScreenTimeMonitoring({
    required int limitMinutes,
    required String dateKey,
    required String familyId,
  }) async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<bool>('startScreenTimeMonitoring', {
          'limitMinutes': limitMinutes,
          'dateKey': dateKey,
          'familyId': familyId,
        }) ?? false;
      }
    } catch (_) {}
    return false;
  }

  // Resets today's foreground accumulator to zero. Called when the parent
  // sets a new screen-time limit so the bar starts from 0 at that moment.
  static Future<void> resetIosSessionCounter(String dateKey) async {
    try {
      if (Platform.isIOS) {
        await _iosChannel.invokeMethod('resetIosSessionCounter', {'dateKey': dateKey});
      }
    } catch (_) {}
  }

  // Reads real Screen Time category data written by the DeviceActivityReport
  // extension to the shared keychain group. Returns null if the extension's
  // keychain write was sandbox-blocked (falls back to foreground timer).
  // Map keys: 'totalMinutes' (int), 'apps' (List), 'vendorId' (String).
  static Future<Map<String, dynamic>?> getIosUsageFromKeychain(String dateKey) async {
    try {
      if (Platform.isIOS) {
        final raw = await _iosChannel.invokeMethod('getIosUsageFromKeychain', {'dateKey': dateKey});
        if (raw != null) {
          return Map<String, dynamic>.from(raw as Map);
        }
      }
    } catch (_) {}
    return null;
  }

  // iOS only — stores the session start timestamp in UserDefaults so the
  // native layer can compute lock-aware elapsed time.
  // Call once when the session transitions to 'active'.
  static Future<void> startSessionTimer(int startMillis) async {
    try {
      if (Platform.isIOS) {
        await _iosChannel.invokeMethod('startSessionTimer', {'startMillis': startMillis.toDouble()});
      }
    } catch (_) {}
  }

  // iOS only — returns session elapsed minutes minus device-locked seconds.
  // The result naturally pauses while the screen is off.
  static Future<int> getSessionElapsedMinutes() async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<int>('getSessionElapsedMinutes') ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  // iOS only — clears all session timer state from UserDefaults.
  // Call when the session ends.
  static Future<void> clearSessionTimer() async {
    try {
      if (Platform.isIOS) await _iosChannel.invokeMethod('clearSessionTimer');
    } catch (_) {}
  }

  // iOS only — reads the minutes counter written by the KtbActivityMonitor extension
  // directly from the App Group. The main app relays this value to Firestore via
  // Firebase SDK (more reliable than the extension's URLSession REST call).
  static Future<int> getAppGroupMinutes(String dateKey) async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<int>('getAppGroupMinutes', {'dateKey': dateKey}) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  // iOS only — presents the native FamilyActivityPicker sheet.
  // The parent (holding the child's device) picks allowed apps; the selection is
  // stored in the App Group so applySessionRestrictions can read it later.
  // Returns true if the parent confirmed a selection, false if cancelled.
  static Future<bool> showFamilyActivityPicker() async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<bool>('showFamilyActivityPicker') ?? false;
      }
    } catch (_) {}
    return false;
  }

  // iOS only — reads the stored FamilyActivitySelection and applies
  // ManagedSettingsStore shields, blocking all apps except the allowed ones.
  static Future<bool> applySessionRestrictions() async {
    try {
      if (Platform.isIOS) {
        return await _iosChannel.invokeMethod<bool>('applySessionRestrictions') ?? false;
      }
    } catch (_) {}
    return false;
  }

  // iOS only — clears all ManagedSettings shields (call when session ends).
  static Future<void> clearSessionRestrictions() async {
    try {
      if (Platform.isIOS) {
        await _iosChannel.invokeMethod('clearSessionRestrictions');
      }
    } catch (_) {}
  }

  // Android only — returns all user-visible launcher apps installed on the device.
  // Used by the session tab so the parent (on child's device) can pick allowed apps.
  static Future<List<AppUsageEntry>> getInstalledApps() async {
    if (!Platform.isAndroid) return [];
    try {
      final raw = await _androidChannel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (raw == null) return [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return AppUsageEntry(
          packageName:   m['packageName']   as String? ?? '',
          appName:       m['appName']       as String? ?? '',
          categoryLabel: m['categoryLabel'] as String? ?? 'Other',
          timeMinutes:   0,
        );
      }).toList();
    } catch (_) {}
    return [];
  }

  // Android only — iOS shows the chart via UiKitView (DeviceActivityReport extension).
  static Future<List<AppUsageEntry>> getDailyUsage(DateTime date) async {
    if (!Platform.isAndroid) return [];
    try {
      final raw = await _androidChannel.invokeMethod<List<dynamic>>('getDailyUsage', {
        'dateMillis': date.millisecondsSinceEpoch,
      });
      if (raw == null) return [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return AppUsageEntry(
          packageName:   m['packageName']   as String? ?? '',
          appName:       m['appName']       as String? ?? '',
          categoryLabel: m['categoryLabel'] as String? ?? 'Other',
          timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
        );
      }).toList();
    } on PlatformException catch (e) {
      if (e.code == 'NO_PERMISSION') return [];
    } catch (_) {}
    return [];
  }

  /// Groups entries by category, sorted by total time descending.
  static List<MapEntry<String, int>> groupByCategory(List<AppUsageEntry> entries) {
    final map = <String, int>{};
    for (final e in entries) {
      map[e.categoryLabel] = (map[e.categoryLabel] ?? 0) + e.timeMinutes;
    }
    return map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  static String formatMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}
