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

  static Future<List<AppUsageEntry>> getDailyUsage(DateTime date) async {
    try {
      if (Platform.isAndroid) {
        final raw = await _androidChannel.invokeMethod<List<dynamic>>('getDailyUsage', {
          'dateMillis': date.millisecondsSinceEpoch,
        });
        if (raw == null) return [];
        return raw.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return AppUsageEntry(
            packageName: m['packageName'] as String? ?? '',
            appName:     m['appName']     as String? ?? '',
            categoryLabel: m['categoryLabel'] as String? ?? 'Other',
            timeMinutes: (m['timeMinutes'] as num?)?.toInt() ?? 0,
          );
        }).toList();
      }

      if (Platform.isIOS) {
        // Trigger the DeviceActivityReport extension to refresh data, then read
        await _iosChannel.invokeMethod('refreshReport');
        // Give the extension a moment to process (it runs out-of-process)
        await Future.delayed(const Duration(seconds: 3));
        final raw = await _iosChannel.invokeMethod<List<dynamic>>('getDailyUsage', {
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
      }
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
