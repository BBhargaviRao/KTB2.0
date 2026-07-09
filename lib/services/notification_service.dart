import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static const _nudgeChannelId   = 'ktb_nudges';
  static const _nudgeChannelName = 'Nudges';
  static const _reminderChannelId   = 'ktb_reminders';
  static const _reminderChannelName = 'Screen Time Reminders';

  // Notification ID ranges
  static const int _fcmBannerBase  = 100;
  static const int _reminderBase   = 2000;

  static Future<void> init() async {
    tz_data.initializeTimeZones();

    // flutter_local_notifications crashes on iOS 26.x (SIGSEGV in native layer).
    // Firebase Messaging handles all iOS push delivery natively, so skip here.
    if (Platform.isIOS) return;

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _nudgeChannelId, _nudgeChannelName,
      description: 'Nudge push notifications',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _reminderChannelId, _reminderChannelName,
      description: 'Screen time limit reminders',
      importance: Importance.high,
    ));
  }

  // Show a banner immediately (used for FCM foreground messages)
  static Future<void> showNudgeBanner(String title, String body) async {
    if (Platform.isIOS) return;
    await _plugin.show(
      _fcmBannerBase + (title.hashCode.abs() % 50),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _nudgeChannelId, _nudgeChannelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  // Schedule a screen-time reminder notification in [delay] from now.
  // [slotIndex] is 0-9 so multiple reminders don't overwrite each other.
  static Future<void> scheduleReminder({
    required int slotIndex,
    required String title,
    required String body,
    required Duration delay,
  }) async {
    if (Platform.isIOS) return;
    if (delay.isNegative || delay == Duration.zero) return;

    final scheduled = tz.TZDateTime.now(tz.UTC).add(delay);

    await _plugin.zonedSchedule(
      _reminderBase + slotIndex,
      title,
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _reminderChannelId, _reminderChannelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  static const int _limitReachedId = 3000;

  // Immediate notification when screen time limit is reached
  static Future<void> showLimitReached({required bool isParent}) async {
    if (Platform.isIOS) return;
    final title = isParent ? "Child's screen time is up" : 'Screen time limit reached';
    final body  = isParent
        ? 'Your child has used their full screen time for today.'
        : 'You have used your full screen time for today.';
    await _plugin.show(
      _limitReachedId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _reminderChannelId, _reminderChannelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  // Cancel all screen-time reminders
  static Future<void> cancelAllReminders() async {
    for (int i = 0; i < 10; i++) {
      await _plugin.cancel(_reminderBase + i);
    }
  }
}
