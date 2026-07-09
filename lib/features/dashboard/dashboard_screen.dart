import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ktb2/features/parent_login/parent_login_screen.dart';
import 'package:ktb2/features/child_login/child_login_screen.dart';
import 'package:ktb2/features/dashboard/session_tab.dart';
import 'package:ktb2/services/notification_service.dart';
import 'package:ktb2/services/usage_stats_service.dart';

// ── Task model ────────────────────────────────────────────────────────────────

class _Task {
  String text;
  bool done;
  String addedBy; // 'parent' | 'child'
  _Task({required this.text, this.done = false, this.addedBy = ''});
}

// ── helpers ───────────────────────────────────────────────────────────────────

DateTime _todayDate() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _ordinalSuffix(int day) {
  if (day >= 11 && day <= 13) return 'th';
  return switch (day % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
}

String _formatDate(DateTime d) {
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const wdays  = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  return '${wdays[d.weekday - 1]}, ${d.day}${_ordinalSuffix(d.day)} ${months[d.month - 1]}';
}

// ══════════════════════════════════════════════════════════════════════════════
// DashboardScreen
// ══════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  final String displayName;
  final String role;
  final String familyId;
  final String accountId;

  const DashboardScreen({
    super.key,
    required this.displayName,
    required this.role,
    required this.familyId,
    required this.accountId,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  int _selectedTab = 0;
  DateTime _selectedDate = _todayDate();
  bool _todoExpanded = false;

  // Child's mood entries for the displayed week (child only)
  final Map<String, String> _moodEntries = {};

  // accountId of the child in this family (parent reads child mood via this)
  String? _childAccountId;

  // Local screen time reminder preferences (device-specific)
  List<int> _screenTimeReminders = [];

  // App usage data (Android — loaded on initState; iOS — read from Firestore after extension)
  List<AppUsageEntry> _usageEntries = [];
  bool _usagePermissionGranted = false;
  bool _usageLoading = false;

  // iOS vendorId (identifierForVendor) — used to key Firestore iosDeviceData docs
  String? _iosVendorId;

  // Parent: child's usage loaded from Firestore; toggle between views
  List<AppUsageEntry> _childUsageEntries = [];
  bool _childUsageLoading = false;
  bool _showChildUsage = true; // parent only — default to child's view
  String? _childIosVendorId; // parent: child's vendorId for iOS data lookup

  // Live screen time minutes written by KtbActivityMonitor extension → Firestore.
  // This is the single source of truth for the bar on BOTH child and parent.
  int _firestoreScreenTimeMinutes = 0;
  // Guards against stale stream data after a session reset. Set to true when a
  // new session starts; cleared only once Firestore confirms the reset (returns 0).
  bool _sessionResetPending = false;
  // Screen-lock-aware elapsed minutes from native session timer.
  // Updated by _refreshSessionBar when App Group has no extension data yet.
  int _nativeSessionMinutes = 0;
  // Prevents restarting DeviceActivity monitoring on every settings stream event.
  // Only calls startScreenTimeMonitoring when the session+limit combination changes.
  String? _monitoringKey;
  // True once the KtbActivityMonitor extension has supplied at least one value.
  // Ensures extension data always wins over the wall-clock relay fallback.
  bool _extensionHasFired = false;

  // When an active session is running, this is the session's startTime.
  DateTime? _activeSessionStartTime;

  // Fires every 30 s while a session is active to redraw the bar.
  Timer? _sessionPollTimer;

  // Weekly screen time (dateKey → minutes) and mood for the bar chart
  Map<String, int> _weekScreenTimeMinutes = {};
  Map<String, String> _parentChartMoods = {};

  // Screen time minutes to show on the bar.
  // 1. Firestore extension data (session-specific, works for both child & parent).
  // 2. Native screen-lock-aware timer for iOS child (first ~5 min before extension fires).
  // 3. Local usage stats when no session is active.
  int get _usedMinutes {
    final cap = _lastKnownScreenTimeLimit ?? 9999;
    // Firestore value from KtbActivityMonitor is the truth for both roles.
    // It persists after session end so the bar freezes at the final value.
    if (_firestoreScreenTimeMinutes > 0) {
      return _firestoreScreenTimeMinutes.clamp(0, cap);
    }
    // Session active but extension hasn't fired yet (first ~5 min):
    if (_activeSessionStartTime != null) {
      // iOS child: use the screen-lock-aware native timer (updated by
      // _refreshSessionBar every 30 s). This correctly subtracts device-off
      // time, unlike a plain wall-clock difference.
      if (Platform.isIOS && widget.role == 'child') {
        return _nativeSessionMinutes.clamp(0, cap);
      }
      // Parent (Android) waits for first Firestore update from extension.
      return 0;
    }
    // No session, no extension data: show today's local usage.
    if (widget.role == 'child') {
      return _usageEntries.fold(0, (s, e) => s + e.timeMinutes);
    }
    return _childUsageEntries.fold(0, (s, e) => s + e.timeMinutes);
  }

  // Triggers a rebuild so _usedMinutes re-evaluates with the current clock.
  // On child iOS: also relays any App Group session minutes to Firestore via
  // Firebase SDK — more reliable than the extension's URLSession REST call.
  void _refreshSessionBar() async {
    if (!mounted || _activeSessionStartTime == null) return;
    if (Platform.isIOS && widget.role == 'child') {
      final dateKey = _dateKey(_todayDate());
      final agMins = await UsageStatsService.getAppGroupMinutes(dateKey);

      if (agMins > 0 && (agMins > _firestoreScreenTimeMinutes || !_extensionHasFired)) {
        // Extension fired — always prefer this over wall-clock relay.
        _extensionHasFired = true;
        FirebaseFirestore.instance
            .collection('families').doc(widget.familyId)
            .collection('dashboard_days').doc(dateKey)
            .set({
              'screenTimeUsedMinutes': agMins,
              'screenTimeLastUpdatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
        if (mounted) setState(() {
          _firestoreScreenTimeMinutes = agMins;
          _nativeSessionMinutes = agMins;
        });
        return;
      }

      // Extension hasn't fired yet — relay native (wall-clock) timer to Firestore
      // so the parent sees live session data even before the first 5-min threshold.
      // Once the extension fires it will overwrite this with accurate screen-on time.
      final elapsed = await UsageStatsService.getSessionElapsedMinutes();
      if (!mounted) return;
      if (elapsed > 0 && !_extensionHasFired && elapsed > _firestoreScreenTimeMinutes) {
        FirebaseFirestore.instance
            .collection('families').doc(widget.familyId)
            .collection('dashboard_days').doc(dateKey)
            .set({
              'screenTimeUsedMinutes': elapsed,
              'screenTimeLastUpdatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
        if (mounted) setState(() {
          _nativeSessionMinutes = elapsed;
          _firestoreScreenTimeMinutes = elapsed;
        });
      } else if (elapsed != _nativeSessionMinutes && mounted) {
        setState(() => _nativeSessionMinutes = elapsed);
      }
    }
    if (mounted) setState(() {});
  }

  List<AppUsageEntry> get _activeEntries =>
      (widget.role == 'parent' && _showChildUsage) ? _childUsageEntries : _usageEntries;

  bool get _activeLoading =>
      (widget.role == 'parent' && _showChildUsage) ? _childUsageLoading : _usageLoading;

  // Cached streams — prevent stream recreation on every rebuild
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _todosStream;
  String? _todosStreamDateKey;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _settingsStream;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _dashDayStream;
  String? _dashDayStreamKey;

  // For cross-device todo notifications
  Timestamp? _lastKnownTodosUpdatedAt;
  bool _todoStreamInitialized = false;

  // For screen time limit change notifications
  int? _lastKnownScreenTimeLimit;
  bool _settingsStreamInitialized = false;

  // Periodic refresh timer and limit-reached tracking
  Timer? _usageRefreshTimer;
  String? _limitReachedNotifiedDateKey; // tracks which day we already notified

  // ── Firestore refs ────────────────────────────────────────────────────────

  // Per-account daily data (mood only — child's own mood)
  DocumentReference<Map<String, dynamic>> _dailyRef(String dateKey) =>
      FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(widget.accountId)
          .collection('dailyData').doc(dateKey);

  // Family-shared daily data (todos — visible to both parent and child)
  DocumentReference<Map<String, dynamic>> _familyDailyRef(String dateKey) =>
      FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('dailyData').doc(dateKey);

  // Family-level settings (screen time limit set by parent)
  DocumentReference<Map<String, dynamic>> _familySettingsRef() =>
      FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('settings').doc('screenTime');

  // Returns a cached todos stream — avoids resubscription on every widget rebuild
  Stream<DocumentSnapshot<Map<String, dynamic>>> _getTodosStream(String dateKey) {
    if (_todosStreamDateKey != dateKey || _todosStream == null) {
      _todosStreamDateKey = dateKey;
      _todoStreamInitialized = false; // reset cross-device tracker for new date
      _lastKnownTodosUpdatedAt = null;
      _todosStream = _familyDailyRef(dateKey).snapshots();
    }
    return _todosStream!;
  }

  // Returns a cached dashboard_days stream — avoids re-subscription on every rebuild
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _getDashDayStream(String todayKey) {
    if (_dashDayStreamKey != todayKey || _dashDayStream == null) {
      _dashDayStreamKey = todayKey;
      _dashDayStream = FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('dashboard_days').doc(todayKey)
          .snapshots();
    }
    return _dashDayStream;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsStream = _familySettingsRef().snapshots();
    Future.microtask(_loadInitialData);
    _usageRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || _selectedDate != _todayDate()) return;
      if (Platform.isIOS && widget.role == 'child' && _iosVendorId != null) {
        _loadIosSessionMinutes(_selectedDate);
      } else {
        _loadUsageStats(_selectedDate);
      }
      if (widget.role == 'parent') _loadChildUsageFromFirestore(_selectedDate);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usageRefreshTimer?.cancel();
    _sessionPollTimer?.cancel();
    super.dispose();
  }

  // Refresh the session bar immediately when the child switches back to KTB
  // from other apps — picks up any App Group minutes written by the extension.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _activeSessionStartTime != null) {
      _refreshSessionBar();
    }
  }

  Future<void> _loadInitialData() async {
    await Future.wait([
      _findChildAccountId(),
      if (widget.role == 'child') _loadWeekMoods(_todayDate()),
      _loadUsageStats(_todayDate()),
    ]);
    if (widget.role == 'parent') {
      await _loadChildUsageFromFirestore(_todayDate());
    }
    await _loadWeekData();
  }

  Future<void> _loadUsageStats(DateTime date) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final hasPermission = await UsageStatsService.hasPermission();
    if (!mounted) return;
    setState(() => _usagePermissionGranted = hasPermission);
    if (!hasPermission) return;

    // iOS: chart renders via UiKitView extension. For the progress bar,
    // we use a session timer (time since app was first opened today) as
    // a proxy for screen time — the DeviceActivityReport extension is
    // sandboxed by Apple and cannot write data to the main app.
    if (Platform.isIOS) {
      _iosVendorId ??= await UsageStatsService.getVendorId();
      final vid = _iosVendorId;
      if (vid != null && vid.isNotEmpty && widget.role == 'child') {
        _registerIosVendorId(vid);
        if (_dateKey(date) == _dateKey(_todayDate())) {
          // Today: use live platform channel data (keychain or foreground timer).
          await _loadIosSessionMinutes(date);
        } else {
          // Past day: read what was uploaded to Firestore that day.
          await _loadIosPastDayFromFirestore(vid, date);
        }
      }
      return;
    }

    setState(() => _usageLoading = true);
    final entries = await UsageStatsService.getDailyUsage(date);
    if (!mounted) return;

    if (entries.isNotEmpty) {
      setState(() { _usageEntries = entries; _usageLoading = false; });
      if (widget.role == 'child' && _dateKey(date) == _dateKey(DateTime.now())) {
        await _uploadUsageToFirestore(date, entries);
      }
    } else {
      // UsageStats returned nothing — may be beyond the device's retention window.
      // Fall back to what was uploaded to Firestore for that day.
      final dateKey = _dateKey(date);
      try {
        final doc = await FirebaseFirestore.instance
            .collection('families').doc(widget.familyId)
            .collection('accounts').doc(widget.accountId)
            .collection('usageStats').doc(dateKey)
            .get();
        final raw = doc.data()?['apps'] as List<dynamic>?;
        final saved = raw?.map((a) {
          final m = Map<String, dynamic>.from(a as Map);
          return AppUsageEntry(
            packageName:   m['packageName']   as String? ?? '',
            appName:       m['appName']       as String? ?? '',
            categoryLabel: m['categoryLabel'] as String? ?? 'Other',
            timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
          );
        }).where((e) => e.timeMinutes > 0).toList() ?? [];
        if (mounted) setState(() { _usageEntries = saved; _usageLoading = false; });
      } catch (_) {
        if (mounted) setState(() => _usageLoading = false);
      }
    }
    if (widget.role == 'child') _checkLimitReached();
  }

  // Writes child's iOS vendorId into the family account doc so parent can look it up.
  void _registerIosVendorId(String vendorId) {
    FirebaseFirestore.instance
        .collection('families').doc(widget.familyId)
        .collection('accounts').doc(widget.accountId)
        .set({'iosVendorId': vendorId}, SetOptions(merge: true))
        .catchError((_) {});
  }

  // Loads iOS usage data. Tries the shared keychain first (written by the
  // DeviceActivityReport extension with real per-category Screen Time data).
  // Falls back to the foreground-only timer if the keychain is empty (i.e.
  // the extension's sandbox also blocks keychain writes on this device).
  // Only runs after the parent has set a screen-time limit.
  Future<void> _loadIosSessionMinutes(DateTime date) async {
    final vid = _iosVendorId;
    if (vid == null || vid.isEmpty) return;
    if (_lastKnownScreenTimeLimit == null || _lastKnownScreenTimeLimit! <= 0) {
      if (mounted) setState(() => _usageEntries = []);
      return;
    }
    final dateKey = _dateKey(date);
    try {
      // Prefer real Screen Time data from keychain (extension writes it).
      final keychainData = await UsageStatsService.getIosUsageFromKeychain(dateKey);
      if (!mounted) return;

      List<AppUsageEntry> entries;
      if (keychainData != null) {
        // Extension's keychain write succeeded — use real category data.
        final rawApps = keychainData['apps'] as List<dynamic>? ?? [];
        entries = rawApps.map((a) {
          final m = Map<String, dynamic>.from(a as Map);
          return AppUsageEntry(
            packageName:   m['packageName']   as String? ?? '',
            appName:       m['appName']       as String? ?? '',
            categoryLabel: m['categoryLabel'] as String? ?? 'Other',
            timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
          );
        }).where((e) => e.timeMinutes > 0).toList();
        if (entries.isEmpty) {
          final total = (keychainData['totalMinutes'] as num?)?.toInt() ?? 0;
          entries = [AppUsageEntry(
            packageName: 'com.apple.total', appName: 'iPad Screen Time',
            categoryLabel: 'Screen Time', timeMinutes: total)];
        }
      } else {
        // Fallback: foreground-only timer (counts only while KTB app is open).
        final minutes = await UsageStatsService.getIosSessionMinutes(dateKey);
        if (!mounted) return;
        entries = [AppUsageEntry(
          packageName: 'com.apple.total', appName: 'iPad Screen Time',
          categoryLabel: 'Screen Time', timeMinutes: minutes)];
      }

      setState(() => _usageEntries = entries);
      if (widget.role == 'child') _checkLimitReached();
      _uploadIosUsageToFirestore(vid, dateKey, entries);
    } catch (_) {}
  }

  // Reads a past day's iOS usage from Firestore (uploaded each day while live).
  Future<void> _loadIosPastDayFromFirestore(String vendorId, DateTime date) async {
    final dateKey = _dateKey(date);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('iosDeviceData').doc(vendorId)
          .collection('usageStats').doc(dateKey)
          .get();
      if (!mounted) return;
      final raw = doc.data()?['apps'] as List<dynamic>?;
      final entries = raw?.map((a) {
        final m = Map<String, dynamic>.from(a as Map);
        return AppUsageEntry(
          packageName:   m['packageName']   as String? ?? '',
          appName:       m['appName']       as String? ?? '',
          categoryLabel: m['categoryLabel'] as String? ?? 'Other',
          timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
        );
      }).where((e) => e.timeMinutes > 0).toList() ?? [];
      setState(() => _usageEntries = entries);
    } catch (_) {}
  }

  Future<void> _uploadIosUsageToFirestore(
      String vendorId, String dateKey, List<AppUsageEntry> apps) async {
    final totalMinutes = apps.fold(0, (s, e) => s + e.timeMinutes);
    try {
      await FirebaseFirestore.instance
          .collection('iosDeviceData').doc(vendorId)
          .collection('usageStats').doc(dateKey)
          .set({
            'apps': apps.map((e) => {
              'packageName': e.packageName,
              'appName': e.appName,
              'categoryLabel': e.categoryLabel,
              'timeMinutes': e.timeMinutes,
            }).toList(),
            'totalMinutes': totalMinutes,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    } catch (_) {}
  }

  void _checkLimitReached() {
    final todayKey = _dateKey(_todayDate());
    if (_limitReachedNotifiedDateKey == todayKey) return; // already notified today
    final limit = _lastKnownScreenTimeLimit;
    if (limit == null || limit <= 0) return;
    if (_usedMinutes >= limit) {
      _limitReachedNotifiedDateKey = todayKey;
      // Notify the child immediately
      NotificationService.showLimitReached(isParent: false);
      // Write to Firestore so the parent's stream picks it up
      _familySettingsRef().set({
        'limitReachedAt': FieldValue.serverTimestamp(),
        'limitReachedDateKey': todayKey,
      }, SetOptions(merge: true)).catchError((_) {});
    }
  }

  Future<void> _uploadUsageToFirestore(DateTime date, List<AppUsageEntry> entries) async {
    final totalMinutes = entries.fold(0, (s, e) => s + e.timeMinutes);
    try {
      await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(widget.accountId)
          .collection('usageStats').doc(_dateKey(date))
          .set({
            'apps': entries.map((e) => {
              'packageName': e.packageName,
              'appName': e.appName,
              'categoryLabel': e.categoryLabel,
              'timeMinutes': e.timeMinutes,
            }).toList(),
            'totalMinutes': totalMinutes,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      print('Failed to upload usage stats: $e');
    }
  }

  Future<void> _loadChildUsageFromFirestore(DateTime date) async {
    if (widget.role != 'parent') return;
    final childId = _childAccountId;
    if (childId == null) return;
    if (mounted) setState(() => _childUsageLoading = true);
    try {
      // Always re-read the child account doc to get the latest iosVendorId —
      // it may have been registered after this parent session started.
      final accountDoc = await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(childId)
          .get();
      final freshVendorId = accountDoc.data()?['iosVendorId'] as String?;
      if (freshVendorId != null && freshVendorId.isNotEmpty) {
        _childIosVendorId = freshVendorId;
      }

      List<AppUsageEntry> apps = [];

      // A child's account may carry a stale iosVendorId from earlier testing on a
      // different platform. Don't trust its mere presence — try the iOS path but
      // fall back to the Android path if it has no data for this date.
      if (_childIosVendorId != null && _childIosVendorId!.isNotEmpty) {
        // iOS child — read from iosDeviceData (uploaded by DeviceActivityReport extension)
        final doc = await FirebaseFirestore.instance
            .collection('iosDeviceData').doc(_childIosVendorId)
            .collection('usageStats').doc(_dateKey(date))
            .get();
        final data = doc.data();
        apps = (data?['apps'] as List<dynamic>?)?.map((a) {
          final m = Map<String, dynamic>.from(a as Map);
          return AppUsageEntry(
            packageName:   m['packageName']   as String? ?? '',
            appName:       m['appName']       as String? ?? '',
            categoryLabel: m['categoryLabel'] as String? ?? 'Other',
            timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
          );
        }).toList() ?? [];
      }

      if (apps.isEmpty) {
        // Android child — read from families/.../usageStats/
        final doc = await FirebaseFirestore.instance
            .collection('families').doc(widget.familyId)
            .collection('accounts').doc(childId)
            .collection('usageStats').doc(_dateKey(date))
            .get();
        final raw = doc.data()?['apps'] as List<dynamic>?;
        apps = raw?.map((a) {
          final m = Map<String, dynamic>.from(a as Map);
          return AppUsageEntry(
            packageName:   m['packageName']   as String? ?? '',
            appName:       m['appName']       as String? ?? '',
            categoryLabel: m['categoryLabel'] as String? ?? 'Other',
            timeMinutes:   (m['timeMinutes']  as num?)?.toInt() ?? 0,
          );
        }).toList() ?? [];
      }

      if (!mounted) return;
      setState(() { _childUsageEntries = apps; _childUsageLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _childUsageLoading = false);
    }
  }

  // Parent: queries child account in this family.
  // Child: sets self.
  Future<void> _findChildAccountId() async {
    if (widget.role == 'child') {
      if (mounted) setState(() => _childAccountId = widget.accountId);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts')
          .where('role', isEqualTo: 'child')
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty && mounted) {
        final doc = snap.docs.first;
        final iosVid = doc.data()['iosVendorId'] as String?;
        setState(() {
          _childAccountId = doc.id;
          _childIosVendorId = iosVid;
        });
      }
    } catch (_) {}
  }

  // Loads mood entries for the week (child only — reads own account)
  Future<void> _loadWeekMoods(DateTime anyDayInWeek) async {
    if (widget.role != 'child') return;
    final monday = anyDayInWeek.subtract(Duration(days: anyDayInWeek.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(widget.accountId)
          .collection('dailyData')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: _dateKey(monday))
          .where(FieldPath.documentId, isLessThanOrEqualTo: _dateKey(sunday))
          .get();
      if (!mounted) return;
      setState(() {
        for (final doc in snap.docs) {
          final mood = doc.data()['mood'] as String?;
          if (mood != null) _moodEntries[doc.id] = mood;
        }
      });
    } catch (_) {}
  }

  Future<void> _loadWeekData() async {
    await Future.wait([
      _loadWeekScreenTime(),
      if (widget.role == 'parent') _loadParentChartMoods(_selectedDate),
    ]);
  }

  Future<void> _loadWeekScreenTime() async {
    final monday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final today = _todayDate();
    final childAccountId = widget.role == 'child' ? widget.accountId : _childAccountId;
    final iosVid = widget.role == 'child' ? _iosVendorId : _childIosVendorId;

    final futures = List.generate(7, (i) async {
      final day = monday.add(Duration(days: i));
      if (day.isAfter(today)) return MapEntry(_dateKey(day), 0);
      final key = _dateKey(day);

      if (iosVid != null && iosVid.isNotEmpty) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('iosDeviceData').doc(iosVid)
              .collection('usageStats').doc(key).get();
          final total = doc.data()?['totalMinutes'] as int?;
          if (total != null && total > 0) return MapEntry(key, total);
        } catch (_) {}
      }

      if (childAccountId != null) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('families').doc(widget.familyId)
              .collection('accounts').doc(childAccountId)
              .collection('usageStats').doc(key).get();
          final total = doc.data()?['totalMinutes'] as int?;
          if (total != null && total > 0) return MapEntry(key, total);
        } catch (_) {}
      }

      return MapEntry(key, 0);
    });

    final results = await Future.wait(futures);
    if (mounted) setState(() => _weekScreenTimeMinutes = Map.fromEntries(results));
  }

  Future<void> _loadParentChartMoods(DateTime anyDayInWeek) async {
    if (widget.role != 'parent' || _childAccountId == null) return;
    final monday = anyDayInWeek.subtract(Duration(days: anyDayInWeek.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(_childAccountId!)
          .collection('dailyData')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: _dateKey(monday))
          .where(FieldPath.documentId, isLessThanOrEqualTo: _dateKey(sunday))
          .get();
      if (!mounted) return;
      final moods = <String, String>{};
      for (final doc in snap.docs) {
        final mood = doc.data()['mood'] as String?;
        if (mood != null) moods[doc.id] = mood;
      }
      setState(() => _parentChartMoods = moods);
    } catch (_) {}
  }

  Future<void> _persistMood(String dateKey, String emoji) async {
    try {
      await _dailyRef(dateKey).set({
        'mood': emoji,
        'moodUpdatedAt': FieldValue.serverTimestamp(),
        'dateKey': dateKey,
        'updatedByRole': widget.role,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ── palette ───────────────────────────────────────────────────────────────
  static const _bg        = Color(0xFFF0EEF8);
  static const _textDark  = Color(0xFF1A1A2E);
  static const _textMid   = Color(0xFF4A4A6A);
  static const _textLight = Color(0xFF8A8AAA);
  static const _barColor  = Color(0xFFB3A9D4);
  static const _green     = Color(0xFF4A7C59);

  bool   get _isTablet => MediaQuery.of(context).size.shortestSide >= 600;
  double _s(double phone, double tablet) => _isTablet ? tablet : phone;

  void _onTabTapped(int index) => setState(() => _selectedTab = index);

  BoxDecoration _cardDecoration({double elevation = 1}) => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_s(18, 24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07 * elevation),
            blurRadius: 14 * elevation,
            offset: Offset(0, 3 * elevation),
          ),
        ],
      );

  // ── dialogs ───────────────────────────────────────────────────────────────

  void _showCalendarDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _CalendarDialog(
        selectedDate: _selectedDate,
        onDateSelected: (d) async {
          Navigator.of(context).pop();
          final prevMonday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
          final newMonday  = d.subtract(Duration(days: d.weekday - 1));
          setState(() => _selectedDate = d);
          if (newMonday != prevMonday) {
            if (widget.role == 'child') await _loadWeekMoods(d);
            await _loadWeekData();
          }
          await _loadUsageStats(d);
          if (widget.role == 'parent') await _loadChildUsageFromFirestore(d);
        },
      ),
    );
  }

  Future<void> _showTodoDialog() async {
    final dateKey = _dateKey(_selectedDate);
    // Load current family todos before opening dialog
    List<_Task> initial = [];
    try {
      final doc = await _familyDailyRef(dateKey).get();
      final raw = doc.data()?['todos'] as List<dynamic>?;
      if (raw != null) {
        initial = raw.map((t) {
          final m = t as Map<String, dynamic>;
          return _Task(
            text: m['text'] as String? ?? '',
            done: m['done'] as bool? ?? false,
            addedBy: m['addedBy'] as String? ?? '',
          );
        }).toList();
      } else if (dateKey == _dateKey(_todayDate())) {
        initial = [
          _Task(text: 'Maths', addedBy: widget.role),
          _Task(text: '10 min YouTube', addedBy: widget.role),
          _Task(text: '15 min Poki', addedBy: widget.role),
        ];
      }
    } catch (_) {}

    if (!mounted) return;
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _TodoDialog(
        initialTasks: initial,
        onSave: (updated) {
          setState(() => _todoExpanded = false);
          for (final t in updated) {
            if (t.addedBy.isEmpty) t.addedBy = widget.role;
          }
          _familyDailyRef(dateKey).set({
            'todos': updated.map((t) => {
              'text': t.text,
              'done': t.done,
              'addedBy': t.addedBy,
            }).toList(),
            'todosUpdatedAt': FieldValue.serverTimestamp(),
            'updatedByRole': widget.role,
            'updatedByAccountId': widget.accountId,
            'dateKey': dateKey,
          }, SetOptions(merge: true)).then((_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('To-do list updated'),
                duration: Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ));
            }
          });
        },
      ),
    );
  }

  void _showMoodDialog() {
    if (widget.role != 'child') return; // parent views child mood — no editing
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _MoodDialog(
        moodEntries: Map.of(_moodEntries),
        selectedDate: _selectedDate,
        onSave: (updated) {
          setState(() => _moodEntries..clear()..addAll(updated));
          final todayKey = _dateKey(_todayDate());
          final emoji = updated[todayKey];
          if (emoji != null) _persistMood(todayKey, emoji);
        },
      ),
    );
  }

  void _showScreenTimeLimitDialog(int? currentLimit) {
    final isParent = widget.role == 'parent';
    showDialog(
      context: context,
      builder: (_) => _ScreenTimeLimitDialog(
        initialLimit: currentLimit ?? 120,
        initialReminders: List.of(_screenTimeReminders),
        usedMinutes: _usedMinutes,
        allowEditLimit: isParent,
        onSave: (limit, reminders) async {
          setState(() => _screenTimeReminders = reminders);
          if (isParent) {
            // Persist limit to Firestore so child sees it in real-time
            await _familySettingsRef().set({
              'screenTimeLimitMinutes': limit,
              'updatedByRole': 'parent',
              'updatedByAccountId': widget.accountId,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
          _scheduleScreenTimeReminders(limit, reminders);
        },
      ),
    );
  }

  Future<void> _scheduleScreenTimeReminders(int limitMins, List<int> reminders) async {
    await NotificationService.cancelAllReminders();
    for (int i = 0; i < reminders.length; i++) {
      final minsLeft = reminders[i];
      final minsUntilFire = limitMins - _usedMinutes - minsLeft;
      if (minsUntilFire > 0) {
        await NotificationService.scheduleReminder(
          slotIndex: i,
          title: 'Screen time reminder',
          body: '$minsLeft minutes of screen time left today.',
          delay: Duration(minutes: minsUntilFire),
        );
        // Write to notification inbox with the projected fire time
        try {
          final fireAt = DateTime.now().add(Duration(minutes: minsUntilFire));
          await FirebaseFirestore.instance
              .collection('families').doc(widget.familyId)
              .collection('notifications')
              .add({
            'title': 'Screen time reminder',
            'body': '$minsLeft minutes of screen time left today.',
            'type': 'screen_time_reminder',
            'targetRole': widget.role,
            'dateKey': _dateKey(_todayDate()),
            'sentAt': Timestamp.fromDate(fireAt),
          });
        } catch (_) {}
      }
    }
  }

  // ── dashboard page ────────────────────────────────────────────────────────

  Widget _buildDashboardPage() {
    final hPad   = _s(16.0, 32.0);
    final vGap   = _s(12.0, 20.0);
    final topPad = _s(24.0, 36.0);

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, topPad, hPad, 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildHeader(),
                SizedBox(height: vGap),
                // 1 · Weekly overview: day selector + screen time bars + mood
                _buildWeeklyOverviewChart(),
                SizedBox(height: vGap),
                // Keep screen time streams active for session tracking (hidden)
                Offstage(offstage: true, child: _buildScreenTimeBar()),
                // 3 · Adaptive layout: phone vs tablet
                if (_isTablet) ...[
                  // Tablet: To-do + Mood stacked left | Nudge right
                  // SizedBox gives a bounded height so _DashboardNudgeWidget
                  // (which uses Expanded internally) can render correctly.
                  SizedBox(
                    height: 440,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildToDoCard(),
                              SizedBox(height: vGap),
                              _buildMoodCard(),
                            ],
                          ),
                        ),
                        SizedBox(width: _s(12, 20)),
                        Expanded(
                          child: _DashboardNudgeWidget(
                            familyId: widget.familyId,
                            accountId: widget.accountId,
                            role: widget.role,
                            selectedDate: _selectedDate,
                            onViewAll: () => setState(() => _selectedTab = 1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Phone: To-do | Mood side by side
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _buildToDoCard()),
                        SizedBox(width: _s(10, 16)),
                        Expanded(child: _buildMoodCard()),
                      ],
                    ),
                  ),
                  SizedBox(height: vGap),
                  // Nudge full width — needs a finite height (Expanded inside requires bounded parent)
                  SizedBox(
                    height: 300,
                    child: _DashboardNudgeWidget(
                      familyId: widget.familyId,
                      accountId: widget.accountId,
                      role: widget.role,
                      selectedDate: _selectedDate,
                      onViewAll: () => setState(() => _selectedTab = 1),
                    ),
                  ),
                ],
                SizedBox(height: vGap),
                // 4 · Bar graph full width
                _buildTimeSpentChart(),
                SizedBox(height: vGap),
                // 5 · Most used (left) | Notifications (right)
                _buildTwoColumnRow(
                  left: _buildMostUsedCard(),
                  right: _buildNotificationsCard(),
                ),
                const SizedBox(height: 8),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Scaffold(
        backgroundColor: _bg,
        body: IndexedStack(
          index: _selectedTab,
          children: [
            _buildDashboardPage(),
            widget.role == 'parent'
                ? ParentLoginScreen(
                    parentName: widget.displayName,
                    familyId: widget.familyId,
                    parentAccountId: widget.accountId,
                  )
                : ChildLoginScreen(
                    childName: widget.displayName,
                    familyId: widget.familyId,
                    childAccountId: widget.accountId,
                  ),
            SessionTab(
              familyId:         widget.familyId,
              role:             widget.role,
              childAccountId:   _childAccountId,
              childIosVendorId: _childIosVendorId,
            ),
          ],
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Column(
          children: [
            Text('KidTechBalance',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'InstrumentSerif',
                  fontSize: _s(38, 58),
                  fontWeight: FontWeight.w400,
                  color: _textDark,
                  height: 1.1,
                  letterSpacing: -0.5,
                )),
            SizedBox(height: _s(4, 8)),
            Text('Welcome ${widget.displayName},',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'InstrumentSerif',
                  fontSize: _s(22, 34),
                  fontStyle: FontStyle.italic,
                  color: _textMid,
                  height: 1.2,
                )),
          ],
        ),
        Positioned(
          top: 0,
          right: 0,
          child: PopupMenuButton<String>(
            icon: Icon(Icons.menu_rounded, color: _textMid, size: _s(24, 34)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            color: Colors.white,
            elevation: 4,
            onSelected: (value) {
              if (value == 'calendar') _showCalendarDialog();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem<String>(
                value: 'calendar',
                child: Row(
                  children: [
                    Icon(Icons.calendar_month_outlined, color: _textMid, size: _s(20, 28)),
                    SizedBox(width: _s(10, 14)),
                    Text('Calendar', style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontStyle: FontStyle.italic,
                      fontSize: _s(14, 20),
                      color: _textDark,
                    )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── screen time bar ───────────────────────────────────────────────────────

  Widget _buildScreenTimeBar() {
    // Also listen to the dashboard_days doc written by the KtbActivityMonitor extension
    // (via Firestore REST API). This gives live minutes even when KTB is closed.
    final todayKey = _dateKey(_todayDate());
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      key: ValueKey('dashday_$todayKey'),
      stream: _selectedDate == _todayDate()
          ? _getDashDayStream(todayKey)
          : null,
      builder: (ctx, daySnap) {
        if (daySnap.connectionState == ConnectionState.active) {
          final mins = daySnap.data?.data()?['screenTimeUsedMinutes'] as int?;
          if (mins != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_sessionResetPending) {
                // Waiting for the session-start reset to propagate through Firestore.
                // Ignore stale cached values > 0 until we see the confirmed 0.
                if (mins == 0) setState(() => _sessionResetPending = false);
              } else if (mins > _firestoreScreenTimeMinutes ||
                  (mins == 0 && _firestoreScreenTimeMinutes > 0)) {
                // Only call setState when the value actually changes.
                setState(() => _firestoreScreenTimeMinutes = mins);
              }
            });
          }
        }
        return _buildSettingsStream();
      },
    );
  }

  Widget _buildSettingsStream() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _settingsStream,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.active) {
          final data  = snap.data?.data();
          final limit = data?['screenTimeLimitMinutes'] as int?;
          final updatedByRole = data?['updatedByRole'] as String?;

          // Notify child when parent changes limit (and vice versa)
          if (_settingsStreamInitialized &&
              limit != null &&
              limit != _lastKnownScreenTimeLimit &&
              updatedByRole != null &&
              updatedByRole != widget.role) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final who = updatedByRole == 'parent' ? 'Parent' : 'Child';
              final h = limit ~/ 60, m = limit % 60;
              final label = h > 0 ? (m > 0 ? '${h}h ${m}m' : '${h}h') : '${m}m';
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('$who set screen time limit to $label'),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ));
              // Reset the iOS foreground timer only when the parent sets a limit
              // for the FIRST time today (null → value). When changing an existing
              // limit mid-session the used minutes stay the same; only the
              // denominator changes so the bar recalculates automatically.
              if (Platform.isIOS && widget.role == 'child' &&
                  _lastKnownScreenTimeLimit == null) {
                UsageStatsService.resetIosSessionCounter(_dateKey(_todayDate()));
              }
            });
          }
          // Track active session start time so the screen time bar shows
          // session elapsed time instead of all-day usage.
          final sessionStartMillis = data?['activeSessionStartMillis'] as int?;
          final newStart = sessionStartMillis != null
              ? DateTime.fromMillisecondsSinceEpoch(sessionStartMillis)
              : null;
          if (newStart != _activeSessionStartTime) {
            _activeSessionStartTime = newStart;
            // Start or stop the 30-second redraw timer that keeps the bar current.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _sessionPollTimer?.cancel();
              if (newStart != null) {
                // Reset local + Firestore minutes so the bar starts at 0.
                // Mark reset pending so the stream ignores any stale cached
                // values until Firestore confirms the 0 write.
                _firestoreScreenTimeMinutes = 0;
                _nativeSessionMinutes = 0;
                _extensionHasFired = false;
                _sessionResetPending = true;
                FirebaseFirestore.instance
                    .collection('families').doc(widget.familyId)
                    .collection('dashboard_days').doc(_dateKey(_todayDate()))
                    .set({'screenTimeUsedMinutes': 0}, SetOptions(merge: true));
                // Tell the native layer the session start time so it can
                // compute lock-aware elapsed minutes without needing KTB open.
                if (Platform.isIOS && widget.role == 'child') {
                  UsageStatsService.startSessionTimer(newStart.millisecondsSinceEpoch);
                }
                _sessionPollTimer = Timer.periodic(
                    const Duration(seconds: 30), (_) => _refreshSessionBar());
                _refreshSessionBar(); // immediate first redraw
              } else {
                if (Platform.isIOS && widget.role == 'child') {
                  UsageStatsService.clearSessionTimer();
                }
                _sessionPollTimer = null;
              }
            });
          }

          if (limit != null) {
            final hadLimit = _lastKnownScreenTimeLimit != null && _lastKnownScreenTimeLimit! > 0;
            _lastKnownScreenTimeLimit = limit;
            if (widget.role == 'child') _checkLimitReached();
            if (Platform.isIOS && widget.role == 'child') {
              // Only restart DeviceActivity monitoring when the session+limit
              // combination actually changes. Restarting on every stream event
              // clears the App Group counter and prevents the extension from
              // accumulating minutes across the session.
              final activeMs = _activeSessionStartTime?.millisecondsSinceEpoch;
              final monKey = '${activeMs}_$limit';
              if (_monitoringKey != monKey && activeMs != null) {
                _monitoringKey = monKey;
                UsageStatsService.startScreenTimeMonitoring(
                  limitMinutes: limit,
                  dateKey: _dateKey(_todayDate()),
                  familyId: widget.familyId,
                ).then((ok) {
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Screen time monitoring failed to start — bar may be inaccurate'),
                      duration: Duration(seconds: 5),
                      behavior: SnackBarBehavior.floating,
                    ));
                  }
                });
              }
              if (!hadLimit && _iosVendorId != null) {
                // Limit just became available — load immediately instead of
                // waiting for the next 1-minute timer tick.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _loadIosSessionMinutes(_selectedDate);
                });
              }
            }
          }

          // Notify parent when child reaches their limit
          if (_settingsStreamInitialized && widget.role == 'parent') {
            final reachedAt = data?['limitReachedAt'] as Timestamp?;
            final reachedDateKey = data?['limitReachedDateKey'] as String?;
            final todayKey = _dateKey(_todayDate());
            if (reachedAt != null &&
                reachedDateKey == todayKey &&
                _limitReachedNotifiedDateKey != todayKey) {
              _limitReachedNotifiedDateKey = todayKey;
              NotificationService.showLimitReached(isParent: true);
            }
          }

          _settingsStreamInitialized = true;
          return _buildScreenTimeBarContent(limit);
        }
        final limit = snap.data?.data()?['screenTimeLimitMinutes'] as int?;
        return _buildScreenTimeBarContent(limit);
      },
    );
  }

  Widget _buildScreenTimeBarContent(int? limit) {
    final isParent = widget.role == 'parent';
    final hasLimit = limit != null;
    final ratio    = hasLimit ? (_usedMinutes / limit).clamp(0.0, 1.0) : 0.0;

    final Color progressColor;
    if (ratio < 0.6) {
      progressColor = const Color(0xFF4CAF50);
    } else if (ratio < 0.85) {
      progressColor = const Color(0xFFCD8B2C);
    } else {
      progressColor = const Color(0xFFC0392B);
    }

    String rightLabel;
    if (hasLimit) {
      rightLabel = '$_usedMinutes / $limit min';
    } else {
      rightLabel = isParent ? 'Tap to set limit' : 'No limit set yet';
    }

    return GestureDetector(
      onTap: () => _showScreenTimeLimitDialog(limit),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 20), _s(16, 24), _s(16, 22)),
        decoration: _cardDecoration(elevation: 1.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Today's screen time",
                    style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontStyle: FontStyle.italic,
                      fontSize: _s(14, 20),
                      color: _textLight,
                    )),
                Text(rightLabel,
                  style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontStyle: FontStyle.italic,
                    fontSize: _s(12, 18),
                    color: _textLight,
                  ),
                ),
              ],
            ),
            SizedBox(height: _s(10, 16)),
            if (hasLimit)
              Stack(children: [
                Container(
                  height: _s(16, 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8E4F3),
                    borderRadius: BorderRadius.circular(_s(8, 12)),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: ratio,
                  child: Container(
                    height: _s(16, 24),
                    decoration: BoxDecoration(
                      color: progressColor,
                      borderRadius: BorderRadius.circular(_s(8, 12)),
                    ),
                  ),
                ),
              ])
            else
              Container(
                height: _s(16, 24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_s(8, 12)),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4CAF50), Color(0xFFCD8B2C), Color(0xFFC0392B)],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            if (!isParent && hasLimit) ...[
              SizedBox(height: _s(6, 10)),
              Text('Limit set by your parent  •  Tap to set reminders',
                style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontStyle: FontStyle.italic,
                  fontSize: _s(11, 16),
                  color: _textLight,
                )),
            ],
          ],
        ),
      ),
    );
  }

  // ── weekly overview chart ─────────────────────────────────────────────────

  void _onDayBarTapped(DateTime day) async {
    final prevMonday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final newMonday  = day.subtract(Duration(days: day.weekday - 1));
    final weekChanged = prevMonday != newMonday;
    setState(() => _selectedDate = day);
    if (weekChanged) {
      if (widget.role == 'child') await _loadWeekMoods(day);
      await _loadWeekData();
    }
    await _loadUsageStats(day);
    if (widget.role == 'parent') await _loadChildUsageFromFirestore(day);
  }

  Widget _buildWeeklyOverviewChart() {
    final monday = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final today  = _todayDate();
    final endDay = monday.add(const Duration(days: 6));
    const dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

    final weekLabel = monday.month == endDay.month
        ? '${months[monday.month - 1]} ${monday.day}–${endDay.day}'
        : '${months[monday.month - 1]} ${monday.day} – ${months[endDay.month - 1]} ${endDay.day}';

    final values = List.generate(7, (i) {
      final key = _dateKey(monday.add(Duration(days: i)));
      return _weekScreenTimeMinutes[key] ?? 0;
    });
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final moods  = widget.role == 'child' ? _moodEntries : _parentChartMoods;

    final chartH  = _s(72.0, 112.0);
    final labelH  = _s(16.0, 22.0);
    final letterH = _s(18.0, 26.0);
    final moodH   = _s(20.0, 28.0);

    final nextMonday = monday.add(const Duration(days: 7));
    final canGoNext  = nextMonday.isBefore(today) || nextMonday == today;

    return Container(
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(12, 18), _s(16, 24), _s(12, 18)),
      decoration: _cardDecoration(elevation: 1.5),
      child: Column(
        children: [
          // Week navigation header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () => _onDayBarTapped(
                    _selectedDate.subtract(const Duration(days: 7))),
                child: Icon(Icons.chevron_left, color: _textMid, size: _s(22, 32)),
              ),
              Text(weekLabel, style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: _s(13, 20),
                fontWeight: FontWeight.w600,
                color: _textDark,
              )),
              GestureDetector(
                onTap: canGoNext
                    ? () {
                        final next = _selectedDate.add(const Duration(days: 7));
                        _onDayBarTapped(next.isAfter(today) ? today : next);
                      }
                    : null,
                child: Icon(Icons.chevron_right,
                    color: canGoNext
                        ? _textMid
                        : _textLight.withValues(alpha: 0.25),
                    size: _s(22, 32)),
              ),
            ],
          ),
          SizedBox(height: _s(8, 12)),
          // Bar columns
          SizedBox(
            height: labelH + chartH + letterH + moodH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(7, (i) {
                final day      = monday.add(Duration(days: i));
                final key      = _dateKey(day);
                final mins     = values[i];
                final isSelDay = day == _selectedDate;
                final isToday  = day == today;
                final isFuture = day.isAfter(today);
                final ratio    = (!isFuture && maxVal > 0)
                    ? (mins / maxVal).clamp(0.04, 1.0)
                    : 0.04;
                final barH     = isFuture ? 2.0 : chartH * ratio;
                final moodEmoji = moods[key];

                final barColor = isFuture
                    ? _textLight.withValues(alpha: 0.15)
                    : isSelDay
                        ? const Color(0xFF7C6FCD)
                        : isToday
                            ? _barColor
                            : _barColor.withValues(alpha: 0.55);

                return Expanded(
                  child: GestureDetector(
                    onTap: isFuture ? null : () => _onDayBarTapped(day),
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      children: [
                        // Screen time label — only shown on selected day
                        SizedBox(
                          height: labelH,
                          child: mins > 0 && isSelDay
                              ? Center(child: Text(
                                  UsageStatsService.formatMinutes(mins),
                                  style: TextStyle(
                                    fontFamily: 'PlusJakartaSans',
                                    fontStyle: FontStyle.italic,
                                    fontSize: _s(8, 12),
                                    color: _textMid,
                                  )))
                              : null,
                        ),
                        // Bar grows from bottom
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: barH,
                              margin: EdgeInsets.symmetric(horizontal: _s(3, 5)),
                              decoration: BoxDecoration(
                                color: barColor,
                                borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(_s(4, 7))),
                              ),
                            ),
                          ),
                        ),
                        // Day letter
                        SizedBox(
                          height: letterH,
                          child: Center(child: Text(dayLetters[i], style: TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: _s(11, 16),
                            fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                            color: isToday
                                ? _textDark
                                : isFuture
                                    ? _textLight.withValues(alpha: 0.3)
                                    : _textMid,
                          ))),
                        ),
                        // Mood emoji
                        SizedBox(
                          height: moodH,
                          child: moodEmoji != null
                              ? Center(child: Text(moodEmoji,
                                  style: TextStyle(fontSize: _s(13, 20))))
                              : null,
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ── two-column row ────────────────────────────────────────────────────────

  Widget _buildTwoColumnRow({required Widget left, required Widget right}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          SizedBox(width: _s(12, 20)),
          Expanded(child: right),
        ],
      ),
    );
  }

  // ── to-do card ────────────────────────────────────────────────────────────

  Widget _buildToDoCard() {
    final dateKey = _dateKey(_selectedDate);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _getTodosStream(dateKey),
      builder: (ctx, snap) {
        // Detect when OTHER party updated the todo list
        if (snap.hasData && snap.data!.exists) {
          final data = snap.data!.data()!;
          final updatedAt = data['todosUpdatedAt'] as Timestamp?;
          final updatedByRole = data['updatedByRole'] as String?;

          if (_todoStreamInitialized &&
              updatedAt != null &&
              _lastKnownTodosUpdatedAt != null &&
              updatedAt.millisecondsSinceEpoch > _lastKnownTodosUpdatedAt!.millisecondsSinceEpoch &&
              updatedByRole != null &&
              updatedByRole != widget.role) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final who = updatedByRole == 'parent' ? 'Parent' : 'Child';
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('$who updated the to-do list'),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ));
            });
          }
          if (updatedAt != null) _lastKnownTodosUpdatedAt = updatedAt;
        }
        if (!_todoStreamInitialized && snap.connectionState == ConnectionState.active) {
          _todoStreamInitialized = true;
        }

        List<_Task> tasks = [];
        if (snap.hasData && snap.data!.exists) {
          final raw = snap.data!.data()?['todos'] as List<dynamic>?;
          tasks = raw?.map((t) {
            final m = t as Map<String, dynamic>;
            return _Task(
              text: m['text'] as String? ?? '',
              done: m['done'] as bool? ?? false,
              addedBy: m['addedBy'] as String? ?? '',
            );
          }).toList() ?? [];
        } else if (snap.connectionState != ConnectionState.waiting &&
            dateKey == _dateKey(_todayDate())) {
          tasks = [
            _Task(text: 'Maths', addedBy: widget.role),
            _Task(text: '10 min YouTube', addedBy: widget.role),
            _Task(text: '15 min Poki', addedBy: widget.role),
          ];
        }
        return _buildToDoCardContent(tasks);
      },
    );
  }

  Widget _buildToDoCardContent(List<_Task> todos) {
    final sorted  = [...todos.where((t) => !t.done), ...todos.where((t) => t.done)];
    final hasMore = sorted.length > 3;
    final count   = _todoExpanded ? sorted.length : math.min(3, sorted.length);
    final visible = sorted.sublist(0, count);

    return GestureDetector(
      onTap: _showTodoDialog,
      child: Container(
        padding: EdgeInsets.all(_s(14, 24)),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('To-do', style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontStyle: FontStyle.italic,
                  fontSize: _s(18, 28),
                  fontWeight: FontWeight.w700,
                  color: _textDark,
                )),
                if (hasMore)
                  GestureDetector(
                    onTap: () => setState(() => _todoExpanded = !_todoExpanded),
                    child: Icon(
                      _todoExpanded ? Icons.expand_less : Icons.add,
                      size: _s(20, 28),
                      color: _textMid,
                    ),
                  ),
              ],
            ),
            SizedBox(height: _s(12, 20)),
            ...visible.map((t) => Padding(
              padding: EdgeInsets.only(bottom: _s(8, 14)),
              child: _todoWidgetRow(t),
            )),
          ],
        ),
      ),
    );
  }

  Widget _todoWidgetRow(_Task task) {
    final boxSize = _s(17.0, 26.0);
    return Row(
      children: [
        task.done
            ? Icon(Icons.check_box, size: boxSize, color: _green)
            : Container(
                width: boxSize,
                height: boxSize,
                decoration: BoxDecoration(
                  border: Border.all(color: _textLight, width: 1.5),
                  borderRadius: BorderRadius.circular(_s(3, 5)),
                ),
              ),
        SizedBox(width: _s(8, 14)),
        Expanded(
          child: Text(task.text, style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontStyle: FontStyle.italic,
            fontSize: _s(14, 22),
            color: task.done ? _textLight : _textDark,
            decoration: task.done ? TextDecoration.lineThrough : null,
            decorationColor: _textLight,
          )),
        ),
      ],
    );
  }

  // ── mood card ─────────────────────────────────────────────────────────────

  Widget _buildMoodCard() {
    if (widget.role == 'parent') return _buildParentMoodCard();
    return _buildChildMoodCard();
  }

  // Parent sees child's mood in real-time via StreamBuilder
  Widget _buildParentMoodCard() {
    if (_childAccountId == null) {
      return Container(
        padding: EdgeInsets.all(_s(14, 24)),
        decoration: _cardDecoration(),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final today   = _todayDate();
    final monday  = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final sunday  = monday.add(const Duration(days: 6));
    final curMonday = today.subtract(Duration(days: today.weekday - 1));
    final isCurrentWeek = monday == curMonday;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('parent_mood_${_childAccountId}_${_dateKey(monday)}'),
      stream: FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(_childAccountId)
          .collection('dailyData')
          .where(FieldPath.documentId, isGreaterThanOrEqualTo: _dateKey(monday))
          .where(FieldPath.documentId, isLessThanOrEqualTo: _dateKey(sunday))
          .snapshots(),
      builder: (ctx, snap) {
        final Map<String, String> moods = {};
        if (snap.hasData) {
          for (final doc in snap.data!.docs) {
            final m = doc.data()['mood'] as String?;
            if (m != null) moods[doc.id] = m;
          }
        }
        return _buildMoodCardUI(
          title: isCurrentWeek ? "Child's mood, this week" : "Child's mood, ${_formatDate(monday)}",
          moods: moods,
          onTap: null, // parent is read-only
        );
      },
    );
  }

  // Child sees and edits their own mood
  Widget _buildChildMoodCard() {
    final today   = _todayDate();
    final monday  = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final curMonday = today.subtract(Duration(days: today.weekday - 1));
    final isCurrentWeek = monday == curMonday;

    return _buildMoodCardUI(
      title: isCurrentWeek ? 'Mood, this week' : 'Mood, ${_formatDate(monday)}',
      moods: _moodEntries,
      onTap: _showMoodDialog,
    );
  }

  Widget _buildMoodCardUI({
    required String title,
    required Map<String, String> moods,
    required VoidCallback? onTap,
  }) {
    final today   = _todayDate();
    final monday  = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final selKey  = _dateKey(_selectedDate);

    // 2-row grid: row 1 = Mon–Thu, row 2 = Fri–Sun
    // Each circle shows day letter inside; emoji replaces the letter when set
    const dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final circleSize = _isTablet ? 38.0 : 30.0;
    final fontSize   = _isTablet ? 13.0 : 10.0;
    final emojiSize  = _isTablet ? 20.0 : 16.0;

    Widget dayCircle(int i) {
      final day      = monday.add(Duration(days: i));
      final key      = _dateKey(day);
      final isToday  = day == today;
      final isFuture = day.isAfter(today);
      final emoji    = moods[key];
      final hasRing  = key == selKey && emoji != null;

      Color bg        = Colors.transparent;
      Color border    = _textLight.withValues(alpha: isFuture ? 0.2 : 0.4);
      double borderW  = 1.2;

      if (isToday && onTap != null && emoji == null) {
        bg     = _green;
        border = _green;
        borderW = 0;
      }
      if (hasRing) borderW = 2.2;

      return Expanded(
        child: Center(
          child: Container(
            width: circleSize,
            height: circleSize,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: hasRing ? _green : border,
                width: borderW,
              ),
            ),
            child: Center(
              child: emoji != null
                  ? Text(emoji, style: TextStyle(fontSize: emojiSize))
                  : isToday && onTap != null
                      ? Icon(Icons.add, color: Colors.white, size: circleSize * 0.45)
                      : Text(
                          dayLetters[i],
                          style: TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                            color: isFuture ? _textLight.withValues(alpha: 0.3) : _textLight,
                          ),
                        ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(_s(10, 20)),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(12, 22),
              fontWeight: FontWeight.w700,
              color: _textDark,
            )),
            SizedBox(height: _s(8, 14)),
            // Row 1: Mon–Thu
            Row(children: List.generate(4, dayCircle)),
            SizedBox(height: _s(6, 10)),
            // Row 2: Fri–Sun (3 circles + 1 spacer to keep alignment)
            Row(children: [
              ...List.generate(3, (i) => dayCircle(4 + i)),
              const Expanded(child: SizedBox()),
            ]),
          ],
        ),
      ),
    );
  }

  // ── notifications card ────────────────────────────────────────────────────

  Widget _buildNotificationsCard() {
    return Container(
      padding: EdgeInsets.all(_s(14, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notifications', style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontStyle: FontStyle.italic,
            fontSize: _s(15, 26),
            fontWeight: FontWeight.w700,
            color: _textDark,
          )),
          SizedBox(height: _s(10, 18)),
          SizedBox(
            height: _s(110.0, 180.0),
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              key: ValueKey('notifs_${_dateKey(_selectedDate)}'),
              stream: FirebaseFirestore.instance
                  .collection('families').doc(widget.familyId)
                  .collection('notifications')
                  .where('targetRole', isEqualTo: widget.role)
                  .limit(50)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Unable to load', style: TextStyle(
                    fontSize: _s(12, 18), color: _textLight,
                    fontFamily: 'PlusJakartaSans',
                  ));
                }
                // Filter by sentAt date in Dart so older docs without a dateKey
                // field are still shown when the user browses past days.
                final sel = _selectedDate;
                final docs = (snap.data?.docs ?? [])
                    .where((doc) {
                      final ts = doc.data()['sentAt'] as Timestamp?;
                      if (ts == null) return false;
                      final dt = ts.toDate();
                      return dt.year == sel.year &&
                             dt.month == sel.month &&
                             dt.day == sel.day;
                    })
                    .toList()
                  ..sort((a, b) {
                    final ta = (a.data()['sentAt'] as Timestamp?)?.seconds ?? 0;
                    final tb = (b.data()['sentAt'] as Timestamp?)?.seconds ?? 0;
                    return tb.compareTo(ta);
                  });
                if (docs.isEmpty) {
                  return Center(child: Text('No notifications yet', style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: _s(12, 18),
                    color: _textLight,
                  )));
                }
                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => SizedBox(height: _s(7, 12)),
                  itemBuilder: (_, i) {
                    final d = docs[i].data();
                    final title = d['title'] as String? ?? '';
                    final body  = d['body']  as String? ?? '';
                    final ts    = d['sentAt'] as Timestamp?;
                    final time  = ts != null ? _fmtNotifTime(ts.toDate()) : '';
                    return _notifItem(title, body, time);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmtNotifTime(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final m = dt.minute.toString().padLeft(2, '0');
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      return '$h:$m $ampm';
    }
    return '${dt.month}/${dt.day}';
  }

  Widget _notifItem(String title, String body, String time) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.notifications_outlined, size: _s(13, 20), color: _textLight),
        ),
        SizedBox(width: _s(6, 10)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: _s(12, 19),
                    fontWeight: FontWeight.w600,
                    color: _textDark,
                    height: 1.3,
                  ))),
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(time, style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: _s(10, 15),
                      color: _textLight,
                    )),
                  ],
                ],
              ),
              if (body.isNotEmpty) Text(body, style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: _s(11, 17),
                color: _textMid,
                height: 1.3,
              )),
            ],
          ),
        ),
      ],
    );
  }

  // ── time spent chart ──────────────────────────────────────────────────────

  Widget _buildUsageToggle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _toggleChip("Child's", _showChildUsage,
            () => setState(() => _showChildUsage = true)),
        SizedBox(width: _s(4, 6)),
        _toggleChip('Mine', !_showChildUsage,
            () => setState(() => _showChildUsage = false)),
      ],
    );
  }

  Widget _toggleChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: _s(10, 16), vertical: _s(4, 6)),
        decoration: BoxDecoration(
          color: active ? _barColor : const Color(0xFFE8E4F3),
          borderRadius: BorderRadius.circular(_s(20, 30)),
        ),
        child: Text(label, style: TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontStyle: FontStyle.italic,
          fontSize: _s(11, 17),
          fontWeight: FontWeight.w700,
          color: active ? Colors.white : _textMid,
        )),
      ),
    );
  }

  Widget _buildTimeSpentChart() {
    final chartH   = _s(90.0, 150.0);
    final barW     = _s(36.0, 58.0);
    final isParent = widget.role == 'parent';

    Widget titleRow = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('Time spent today', style: TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontStyle: FontStyle.italic,
          fontSize: _s(17, 28),
          fontWeight: FontWeight.w700,
          color: _textDark,
        )),
        if (isParent) _buildUsageToggle(),
      ],
    );

    // For child's Firestore view (parent seeing child data), no local permission needed.
    final showingFirestoreData = isParent && _showChildUsage;
    final nativeSupported = Platform.isAndroid || Platform.isIOS;
    final needsUnsupportedMsg = !showingFirestoreData && !nativeSupported;
    final needsPermission = !showingFirestoreData && nativeSupported && !_usagePermissionGranted;

    if (needsUnsupportedMsg) {
      return Container(
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleRow,
          SizedBox(height: _s(14, 22)),
          Text('Screen time data is not available on this device.',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic,
              fontSize: _s(13, 20), color: _textLight)),
        ]),
      );
    }

    if (_activeLoading) {
      return Container(
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleRow,
          SizedBox(height: _s(20, 30)),
          Center(child: SizedBox(width: _s(20, 32), height: _s(20, 32),
            child: CircularProgressIndicator(strokeWidth: 2, color: _barColor))),
        ]),
      );
    }

    if (needsPermission) {
      return Container(
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleRow,
          SizedBox(height: _s(12, 20)),
          Text('Usage access permission is required to show app usage.',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic,
              fontSize: _s(12, 19), color: _textLight)),
          SizedBox(height: _s(10, 16)),
          GestureDetector(
            onTap: () async {
              await UsageStatsService.requestPermission();
              await _loadUsageStats(_selectedDate);
            },
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: _s(14, 22), vertical: _s(7, 11)),
              decoration: BoxDecoration(
                color: _barColor,
                borderRadius: BorderRadius.circular(_s(8, 12)),
              ),
              child: Text('Grant Access', style: TextStyle(
                fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic,
                fontSize: _s(12, 19), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ]),
      );
    }

    // ── iOS: embed the DeviceActivityReport extension as a platform view ─────
    if (Platform.isIOS) {
      return Container(
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titleRow,
            SizedBox(height: _s(16, 24)),
            SizedBox(
              height: chartH + _s(30, 46),
              child: UiKitView(
                key: ValueKey(_selectedDate.millisecondsSinceEpoch),
                viewType: 'ktb_screen_time_chart',
                layoutDirection: TextDirection.ltr,
                creationParams: {
                  'dateMillis': _selectedDate.millisecondsSinceEpoch,
                },
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
          ],
        ),
      );
    }

    // ── Android ───────────────────────────────────────────────────────────────
    // Aggregate sessions by package so each app gets one bar.
    final Map<String, int> _pkgTotals = {};
    final Map<String, String> _pkgNames = {};
    for (final e in _activeEntries) {
      _pkgTotals[e.packageName] = (_pkgTotals[e.packageName] ?? 0) + e.timeMinutes;
      _pkgNames[e.packageName] = e.appName;
    }
    final entries = (_pkgTotals.entries
        .map((kv) => AppUsageEntry(
              packageName: kv.key,
              appName: _pkgNames[kv.key] ?? kv.key,
              categoryLabel: 'Other',
              timeMinutes: kv.value,
            ))
        .toList()
      ..sort((a, b) => b.timeMinutes.compareTo(a.timeMinutes)));
    if (entries.isEmpty) {
      return Container(
        padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleRow,
          SizedBox(height: _s(14, 22)),
          Text(
            showingFirestoreData
                ? "Child hasn't opened the app yet today, or their data hasn't synced."
                : 'No app usage recorded yet for this day.',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic,
              fontSize: _s(13, 20), color: _textLight)),
        ]),
      );
    }

    final maxTime   = entries.map((e) => e.timeMinutes).reduce((a, b) => a > b ? a : b);
    final displayed = entries.take(6).toList();

    return Container(
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleRow,
          SizedBox(height: _s(20, 30)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: displayed.map((entry) {
                final ratio = maxTime > 0 ? entry.timeMinutes / maxTime : 0.0;
                // For iOS total-time entries use a short readable label.
                // For regular app names take the first word (max 8 chars).
                final label = entry.packageName == 'com.apple.total'
                    ? 'Screen\nTime'
                    : (() {
                        final words = entry.appName.split(' ');
                        final first = words.first;
                        return first.length <= 8 ? first : first.substring(0, 8);
                      })();
                return Padding(
                  padding: EdgeInsets.only(right: _s(10, 16)),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(UsageStatsService.formatMinutes(entry.timeMinutes),
                        style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic,
                          fontSize: _s(9, 14), color: _textMid)),
                      SizedBox(height: _s(3, 5)),
                      Container(
                        width: barW,
                        height: chartH * ratio.clamp(0.04, 1.0),
                        decoration: BoxDecoration(
                          color: _barColor,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(_s(6, 10))),
                        ),
                      ),
                      SizedBox(height: _s(8, 12)),
                      Text(label, style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontStyle: FontStyle.italic,
                        fontSize: _s(10, 16),
                        color: _textLight,
                      )),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── most used card ────────────────────────────────────────────────────────

  Widget _buildMostUsedCard() {
    Widget cardTitle = Text('Most used', style: TextStyle(
      fontFamily: 'PlusJakartaSans',
      fontStyle: FontStyle.italic,
      fontSize: _s(17, 28),
      fontWeight: FontWeight.w700,
      color: _textDark,
    ));

    final isParent = widget.role == 'parent';
    final showingFirestoreData = isParent && _showChildUsage;
    final nativeOk = Platform.isAndroid || Platform.isIOS;
    final hasData = _activeEntries.isNotEmpty &&
        (showingFirestoreData || (nativeOk && _usagePermissionGranted));

    List<Widget> rows;
    if (Platform.isIOS && _usagePermissionGranted && widget.role == 'child' && _activeEntries.isEmpty) {
      // Child's iOS data loads from Firestore after extension uploads (~25s delay)
      rows = [Text('Category data loading… check back shortly.',
          style: TextStyle(fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic, fontSize: _s(12, 19), color: _textLight))];
    } else if (!hasData) {
      final msg = !nativeOk && !showingFirestoreData
          ? 'Not available on this device.'
          : !_usagePermissionGranted && !showingFirestoreData
              ? 'Grant usage access to see categories.'
              : 'No usage data for this day.';
      rows = [Text(msg, style: TextStyle(fontFamily: 'PlusJakartaSans',
          fontStyle: FontStyle.italic, fontSize: _s(12, 19), color: _textLight))];
    } else {
      final categories = UsageStatsService.groupByCategory(_activeEntries).take(5).toList();
      rows = categories.asMap().entries.map((e) {
        final rank = e.key + 1;
        final cat  = e.value;
        return Padding(
          padding: EdgeInsets.only(bottom: _s(8, 14)),
          child: _mostUsedRow('$rank. ${cat.key}', UsageStatsService.formatMinutes(cat.value)),
        );
      }).toList();
    }

    return Container(
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cardTitle,
          SizedBox(height: _s(10, 18)),
          ...rows,
        ],
      ),
    );
  }

  Widget _mostUsedRow(String name, String time) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(name, style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic, fontSize: _s(14, 22), color: _textDark)),
        Text(time, style: TextStyle(fontFamily: 'PlusJakartaSans', fontStyle: FontStyle.italic, fontSize: _s(14, 22), color: _textMid)),
      ],
    );
  }

  // ── bottom nav ────────────────────────────────────────────────────────────

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: _s(8, 14)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _navItem(icon: Icons.dashboard_outlined, label: 'Dashboard', index: 0),
              _navItem(icon: Icons.send_outlined,      label: 'Nudges',    index: 1),
              _navItem(icon: Icons.lock_outline_rounded, label: 'Session', index: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem({required IconData icon, required String label, required int index}) {
    final selected = _selectedTab == index;
    final color    = selected ? _textDark : _textLight;
    return GestureDetector(
      onTap: () => _onTabTapped(index),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _s(24, 40), vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: _s(24, 34)),
            SizedBox(height: _s(4, 6)),
            Text(label, style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: _s(11, 16),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: color,
            )),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Calendar dialog
// ══════════════════════════════════════════════════════════════════════════════

class _CalendarDialog extends StatefulWidget {
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;

  const _CalendarDialog({required this.selectedDate, required this.onDateSelected});

  @override
  State<_CalendarDialog> createState() => _CalendarDialogState();
}

class _CalendarDialogState extends State<_CalendarDialog> {
  late DateTime _viewMonth;
  late DateTime _selected;
  bool _showMonthYearPicker = false;

  late FixedExtentScrollController _monthCtrl;
  late FixedExtentScrollController _yearCtrl;

  static const _minYear = 2020;
  static const _textDark  = Color(0xFF1A1A2E);
  static const _textMid   = Color(0xFF4A4A6A);
  static const _textLight = Color(0xFF8A8AAA);
  static const _green     = Color(0xFF4A7C59);

  static const _monthNames = [
    'January','February','March','April','May','June',
    'July','August','September','October','November','December',
  ];

  @override
  void initState() {
    super.initState();
    _selected  = widget.selectedDate;
    _viewMonth = DateTime(_selected.year, _selected.month, 1);
    final today    = _todayDate();
    final yearList = today.year - _minYear + 1;
    _monthCtrl = FixedExtentScrollController(initialItem: _viewMonth.month - 1);
    _yearCtrl  = FixedExtentScrollController(
        initialItem: (_viewMonth.year - _minYear).clamp(0, yearList - 1));
  }

  @override
  void dispose() {
    _monthCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  String _monthLabel() => '${_monthNames[_viewMonth.month - 1]} ${_viewMonth.year}';

  bool get _canGoNext {
    final today = _todayDate();
    final next  = DateTime(_viewMonth.year, _viewMonth.month + 1, 1);
    return next.year < today.year || (next.year == today.year && next.month <= today.month);
  }

  String _formatFull(DateTime d) {
    const wdays = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    return '${wdays[d.weekday - 1]}, ${d.day}${_ordinalSuffix(d.day)} ${_monthNames[d.month - 1]}';
  }

  // ── month/year picker ─────────────────────────────────────────────────────

  Widget _buildMonthYearPicker() {
    final today    = _todayDate();
    final maxYear  = today.year;
    final years    = List.generate(maxYear - _minYear + 1, (i) => _minYear + i);

    return Column(
      children: [
        SizedBox(
          height: 180,
          child: Row(
            children: [
              // Month wheel
              Expanded(
                child: ListWheelScrollView.useDelegate(
                  controller: _monthCtrl,
                  itemExtent: 44,
                  perspective: 0.003,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: (i) {
                    // Preview but don't apply until Done
                  },
                  childDelegate: ListWheelChildLoopingListDelegate(
                    children: List.generate(12, (i) => Center(
                      child: Text(_monthNames[i], style: const TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 16,
                        color: _textDark,
                      )),
                    )),
                  ),
                ),
              ),
              // Year wheel
              Expanded(
                child: ListWheelScrollView(
                  controller: _yearCtrl,
                  itemExtent: 44,
                  perspective: 0.003,
                  physics: const FixedExtentScrollPhysics(),
                  children: years.map((y) => Center(
                    child: Text('$y', style: const TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 16,
                      color: _textDark,
                    )),
                  )).toList(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              final selMonth = _monthCtrl.selectedItem % 12 + 1;
              final selYear  = _minYear + _yearCtrl.selectedItem.clamp(0, years.length - 1);
              // Clamp to today's month if future
              final today2   = _todayDate();
              DateTime target = DateTime(selYear, selMonth, 1);
              if (target.isAfter(DateTime(today2.year, today2.month, 1))) {
                target = DateTime(today2.year, today2.month, 1);
              }
              setState(() {
                _viewMonth = target;
                _showMonthYearPicker = false;
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              elevation: 0,
            ),
            child: const Text('Done', style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontWeight: FontWeight.w700,
              fontSize: 15,
            )),
          ),
        ),
      ],
    );
  }

  // ── calendar grid ─────────────────────────────────────────────────────────

  Widget _buildCalendarGrid(DateTime today) {
    const cellSize = 44.0;
    final firstOfMonth = DateTime(_viewMonth.year, _viewMonth.month, 1);
    final startOffset  = firstOfMonth.weekday % 7; // Sun=0 Mon=1 .. Sat=6
    final daysInMonth  = DateUtils.getDaysInMonth(_viewMonth.year, _viewMonth.month);

    final List<Widget> rows = [];
    int dayNum = 1;
    int week   = 0;

    while (dayNum <= daysInMonth) {
      final List<Widget> cells = [];
      for (int col = 0; col < 7; col++) {
        final idx = week * 7 + col;
        if (idx < startOffset || dayNum > daysInMonth) {
          cells.add(const SizedBox(width: cellSize, height: cellSize));
        } else {
          final day      = DateTime(_viewMonth.year, _viewMonth.month, dayNum);
          final isFuture = day.isAfter(today);
          final isSel    = day == _selected;
          final isToday  = day == today;

          Color bg        = Colors.transparent;
          Color textColor = _textDark;
          bool  hasBorder = false;

          if (isSel) {
            bg        = _green;
            textColor = Colors.white;
          } else if (isToday) {
            hasBorder = true;
            textColor = _green;
          } else if (isFuture) {
            textColor = _textLight.withValues(alpha: 0.35);
          }

          cells.add(GestureDetector(
            onTap: isFuture ? null : () {
              setState(() => _selected = day);
              widget.onDateSelected(day);
            },
            child: Container(
              width: cellSize,
              height: cellSize,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: hasBorder ? Border.all(color: _green, width: 1.8) : null,
              ),
              alignment: Alignment.center,
              child: Text('${day.day}', style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 16,
                fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w400,
                color: textColor,
              )),
            ),
          ));
          dayNum++;
        }
      }
      rows.add(Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: cells,
      ));
      week++;
    }

    return Column(
      children: rows.map((r) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: r,
      )).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = _todayDate();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Center(
        child: ConstrainedBox(
          // Caps width so it looks correct on landscape iPad
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Month/year navigation
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (!_showMonthYearPicker)
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        color: _textMid,
                        onPressed: () => setState(() =>
                            _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1, 1)),
                      )
                    else
                      const SizedBox(width: 48),
                    // Tappable month/year label
                    GestureDetector(
                      onTap: () => setState(() => _showMonthYearPicker = !_showMonthYearPicker),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_monthLabel(), style: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _textDark,
                          )),
                          const SizedBox(width: 4),
                          Icon(
                            _showMonthYearPicker ? Icons.expand_less : Icons.expand_more,
                            color: _textMid,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                    if (!_showMonthYearPicker)
                      IconButton(
                        icon: Icon(Icons.chevron_right,
                            color: _canGoNext ? _textMid : _textLight.withValues(alpha: 0.3)),
                        onPressed: _canGoNext
                            ? () => setState(() =>
                                _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1, 1))
                            : null,
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),

                if (_showMonthYearPicker)
                  _buildMonthYearPicker()
                else ...[
                  const SizedBox(height: 4),
                  // Day-of-week headers
                  Row(
                    children: ['S','M','T','W','Th','F','S'].map((d) => Expanded(
                      child: Text(d,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _textLight,
                          )),
                    )).toList(),
                  ),
                  const SizedBox(height: 6),
                  // Calendar grid
                  _buildCalendarGrid(today),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0xFFE8E8F0)),
                  const SizedBox(height: 12),
                  // Selected date label
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Selected', style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 13,
                          color: _textMid,
                        )),
                        const SizedBox(height: 4),
                        Text(_formatFull(_selected), style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: _textDark,
                        )),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// To-do dialog
// ══════════════════════════════════════════════════════════════════════════════

class _TodoDialog extends StatefulWidget {
  final List<_Task> initialTasks;
  final ValueChanged<List<_Task>> onSave;

  const _TodoDialog({required this.initialTasks, required this.onSave});

  @override
  State<_TodoDialog> createState() => _TodoDialogState();
}

class _TodoDialogState extends State<_TodoDialog> {
  late List<_Task> _tasks;
  final _ctrl  = TextEditingController();
  final _focus = FocusNode();

  static const _textDark  = Color(0xFF1A1A2E);
  static const _textLight = Color(0xFF8A8AAA);
  static const _green     = Color(0xFF4A7C59);
  static const _purple    = Color(0xFF8B7BB0);

  @override
  void initState() {
    super.initState();
    _tasks = List.of(widget.initialTasks);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggle(_Task task) => setState(() => task.done = !task.done);
  void _delete(_Task task) => setState(() => _tasks.remove(task));

  List<_Task> get _sorted => [
    ..._tasks.where((t) => !t.done),
    ..._tasks.where((t) => t.done),
  ];

  void _save() {
    final pending = _ctrl.text.trim();
    if (pending.isNotEmpty) _tasks.insert(0, _Task(text: pending)); // newest at top
    widget.onSave(_sorted);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;
    final mq = MediaQuery.of(context);
    final dialogMaxH = mq.size.height - mq.viewInsets.bottom - 80;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            constraints: BoxConstraints(maxHeight: dialogMaxH),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('To-do, today', style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: _textDark,
                    )),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close, color: _textLight, size: 24),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Flexible: fills remaining space and scrolls — never overflows
                Flexible(
                  child: ListView.separated(
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _taskRow(sorted[i]),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FB),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.add, color: _textLight, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _ctrl,
                          focusNode: _focus,
                          style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 15, color: _textDark),
                          decoration: const InputDecoration(
                            hintText: 'Add a task...',
                            hintStyle: TextStyle(fontFamily: 'PlusJakartaSans', color: _textLight, fontSize: 15),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (_) {
                            final text = _ctrl.text.trim();
                            if (text.isNotEmpty) setState(() { _tasks.insert(0, _Task(text: text)); _ctrl.clear(); });
                          },
                          textInputAction: TextInputAction.done,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                    ),
                    child: const Text('SAVE', style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    )),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _taskRow(_Task task) {
    return Container(
      decoration: BoxDecoration(
        color: task.done ? const Color(0xFFEEF5EE) : const Color(0xFFF9F7FC),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _toggle(task),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: task.done ? _green : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: task.done ? _green : const Color(0xFF8B7BB0),
                  width: 1.8,
                ),
              ),
              child: task.done ? const Icon(Icons.check, color: Colors.white, size: 14) : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(task.text, style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 15,
              color: task.done ? _textLight : _textDark,
              decoration: task.done ? TextDecoration.lineThrough : null,
              decorationColor: _textLight,
            )),
          ),
          GestureDetector(
            onTap: () => _delete(task),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.delete_outline, color: Colors.red.shade200, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Mood dialog
// ══════════════════════════════════════════════════════════════════════════════

class _MoodDialog extends StatefulWidget {
  final Map<String, String> moodEntries;
  final DateTime selectedDate;
  final ValueChanged<Map<String, String>> onSave;

  const _MoodDialog({
    required this.moodEntries,
    required this.selectedDate,
    required this.onSave,
  });

  @override
  State<_MoodDialog> createState() => _MoodDialogState();
}

class _MoodDialogState extends State<_MoodDialog> {
  late Map<String, String> _entries;
  bool _showingPicker = false;

  static const _textDark  = Color(0xFF1A1A2E);
  static const _textMid   = Color(0xFF4A4A6A);
  static const _textLight = Color(0xFF8A8AAA);
  static const _green     = Color(0xFF4A7C59);
  static const _emojis    = ['😁', '🙂', '😐', '😟', '😢'];

  @override
  void initState() {
    super.initState();
    _entries = Map.of(widget.moodEntries);
  }

  void _selectEmoji(String emoji) {
    final key = _dateKey(_todayDate());
    _entries[key] = emoji;
    widget.onSave(_entries);
    setState(() => _showingPicker = false);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  String _todayName() {
    const names = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    return names[_todayDate().weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    final today   = _todayDate();
    final monday  = today.subtract(Duration(days: today.weekday - 1));
    final selKey  = _dateKey(widget.selectedDate);
    const labels  = ['M', 'T', 'W', 'Th', 'F', 'S', 'Su'];
    final todayKey = _dateKey(today);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Emoji picker bubble
                if (_showingPicker) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F3FB),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: _emojis.map((e) => GestureDetector(
                        onTap: () => _selectEmoji(e),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
                        ),
                      )).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Mood, this week', style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: _textDark,
                    )),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close, color: _textLight, size: 24),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Day labels
                Row(
                  children: labels.map((l) => Expanded(
                    child: Text(l,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 13,
                          color: _textLight,
                        )),
                  )).toList(),
                ),
                const SizedBox(height: 8),
                // Emoji row
                Row(
                  children: List.generate(7, (i) {
                    final day      = monday.add(Duration(days: i));
                    final key      = _dateKey(day);
                    final isToday  = day == today;
                    final isFuture = day.isAfter(today);
                    final emoji    = _entries[key];
                    final isSel    = key == selKey && emoji != null;
                    const size     = 40.0;

                    if (isToday) {
                      // Today: always tappable to set or change mood
                      final hasEmoji = _entries[todayKey] != null;
                      return Expanded(child: Center(child: GestureDetector(
                        onTap: () => setState(() => _showingPicker = !_showingPicker),
                        child: hasEmoji
                            ? Container(
                                width: size + 4,
                                height: size + 4,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: _green, width: 2.5),
                                ),
                                child: Center(child: Text(_entries[todayKey]!,
                                    style: const TextStyle(fontSize: 22))),
                              )
                            : Container(
                                width: size,
                                height: size,
                                decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                                child: const Icon(Icons.add, color: Colors.white, size: 20),
                              ),
                      )));
                    }

                    if (emoji != null) {
                      return Expanded(child: Center(child: Container(
                        width: size + 4,
                        height: size + 4,
                        decoration: isSel
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: _green, width: 2.5),
                              )
                            : null,
                        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                      )));
                    }

                    return Expanded(child: Center(child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _textLight.withValues(alpha: isFuture ? 0.2 : 0.4),
                          width: 1.2,
                        ),
                      ),
                    )));
                  }),
                ),
                const SizedBox(height: 16),
                Text(
                  _showingPicker
                      ? 'Tap an emoji to log today\'s mood'
                      : '${_todayName()} is today — tap + to log how you\'re feeling',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: 14,
                    color: _textMid,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Dashboard nudge widget (child only)
// ══════════════════════════════════════════════════════════════════════════════

class _DashboardNudgeWidget extends StatefulWidget {
  final String familyId;
  final String accountId;
  final String role;
  final DateTime selectedDate;
  final VoidCallback onViewAll;

  const _DashboardNudgeWidget({
    required this.familyId,
    required this.accountId,
    required this.role,
    required this.selectedDate,
    required this.onViewAll,
  });

  @override
  State<_DashboardNudgeWidget> createState() => _DashboardNudgeWidgetState();
}

class _DashboardNudgeWidgetState extends State<_DashboardNudgeWidget> {
  final _ctrl = TextEditingController();
  bool _shareWithParent = true;
  bool _saving = false;
  String? _currentNudgeId;

  CollectionReference<Map<String, dynamic>> get _nudgesRef =>
      FirebaseFirestore.instance
          .collection('families')
          .doc(widget.familyId)
          .collection('nudges');

  // ── TODAY streams — use proven existing indexes ──────────────────────────

  // Latest pending nudge already sent (scheduledFor <= now) for any role
  Stream<QuerySnapshot<Map<String, dynamic>>> _pendingTodayStream(String role) =>
      _nudgesRef
          .where('targetRole', isEqualTo: role)
          .where('targetAccountId', isEqualTo: widget.accountId)
          .where('status', isEqualTo: 'pending')
          .where('scheduledFor', isLessThanOrEqualTo: Timestamp.now())
          .orderBy('scheduledFor', descending: true)
          .limit(1)
          .snapshots();

  // Latest answered nudge for any role (answered = already sent by definition)
  Stream<QuerySnapshot<Map<String, dynamic>>> _answeredStream(String role) =>
      _nudgesRef
          .where('targetRole', isEqualTo: role)
          .where('targetAccountId', isEqualTo: widget.accountId)
          .where('status', isEqualTo: 'answered')
          .orderBy('scheduledFor', descending: true)
          .limit(1)
          .snapshots();

  // ── PAST DATE stream — uses new index (targetRole+targetAccountId+dateKey+scheduledFor) ──
  Stream<QuerySnapshot<Map<String, dynamic>>> _pastDateStream(String role) =>
      _nudgesRef
          .where('targetRole', isEqualTo: role)
          .where('targetAccountId', isEqualTo: widget.accountId)
          .where('dateKey', isEqualTo: _dateKey(widget.selectedDate))
          .orderBy('scheduledFor', descending: true)
          .limit(1)
          .snapshots();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final answer = _ctrl.text.trim();
    if (answer.isEmpty) return;
    setState(() => _saving = true);
    try {
      final data   = doc.data();
      final sentAt = data['notificationSentAt'];
      final now    = Timestamp.now();
      int? latency;
      if (sentAt is Timestamp) {
        latency = (now.seconds - sentAt.seconds).clamp(0, 99999999);
      }
      await doc.reference.update({
        'status': 'answered',
        'shareWithParent': _shareWithParent,
        'response': {'text': answer},
        'answeredAt': FieldValue.serverTimestamp(),
        if (latency != null) 'responseLatencySeconds': latency,
      });
      _ctrl.clear();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatTimestamp(dynamic ts) {
    if (ts is! Timestamp) return '';
    final dt = ts.toDate();
    const wdays = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'am' : 'pm';
    return '${wdays[dt.weekday - 1]}, ${dt.day}${_ordinalSuffix(dt.day)} ${months[dt.month - 1]}, $h:$m$ampm';
  }

  @override
  Widget build(BuildContext context) {
    final role    = widget.role;
    final isToday = widget.selectedDate == _todayDate();

    // ── Today: two-stream combine (proven existing indexes) ──────────────────
    if (isToday) {
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _pendingTodayStream(role),
        builder: (context, pendingSnap) {
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _answeredStream(role),
            builder: (context, answeredSnap) {
              final waiting = pendingSnap.connectionState == ConnectionState.waiting
                  || answeredSnap.connectionState == ConnectionState.waiting;
              if (waiting) return _loadingCard();

              final pending  = pendingSnap.data?.docs  ?? [];
              final answered = answeredSnap.data?.docs ?? [];

              QueryDocumentSnapshot<Map<String, dynamic>>? best;
              if (pending.isNotEmpty && answered.isNotEmpty) {
                final pt = (pending.first.data()['scheduledFor']  as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                final at = (answered.first.data()['scheduledFor'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                best = pt >= at ? pending.first : answered.first;
              } else if (pending.isNotEmpty) {
                best = pending.first;
              } else if (answered.isNotEmpty) {
                best = answered.first;
              }

              return _buildCard(best);
            },
          );
        },
      );
    }

    // ── Past date: single dateKey stream (new index) ──────────────────────────
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _pastDateStream(role),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loadingCard();
        // If index still building, snap.hasError is true — show loading rather
        // than a misleading empty state
        if (snap.hasError) return _loadingCard();
        final docs = snap.data?.docs ?? [];
        return _buildCard(docs.isEmpty ? null : docs.first);
      },
    );
  }

  Widget _loadingCard() {
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _gradientShell(child: const Center(
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )),
        ),
        _viewAllRow(),
      ],
    );
  }

  Widget _buildCard(QueryDocumentSnapshot<Map<String, dynamic>>? doc) {
    // ── empty state (no nudge sent yet for this date) ───────────────────────
    if (doc == null) {
      return Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _gradientShell(child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Text(
                  widget.selectedDate == _todayDate()
                      ? 'No nudge sent yet today'
                      : 'No nudge on this date',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontSize: 20,
                    fontStyle: FontStyle.italic,
                    color: Colors.black.withValues(alpha: 0.6),
                  )),
              ),
            )),
          ),
          _viewAllRow(),
        ],
      );
    }

    // ── nudge card ───────────────────────────────────────────────────────────
    final data       = doc.data();
    final question   = (data['prompt'] ?? '') as String;
    final status     = (data['status'] ?? 'pending') as String;
    final isAnswered = status == 'answered';
    final isParent   = widget.role == 'parent';
    final dateLabel  = _formatTimestamp(data['scheduledFor']);

    if (_currentNudgeId != doc.id) {
      _currentNudgeId = doc.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ctrl.clear();
      });
    }

    final answerText = isAnswered
        ? ((data['response'] as Map?)?['text'] as String? ?? '')
        : null;

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _gradientShell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── question + status pill ───────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(question, style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 17,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w400,
                          color: Colors.black,
                          height: 1.3,
                          letterSpacing: -0.2,
                        )),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          isParent
                              ? (isAnswered ? 'Answered ✅' : 'Pending…')
                              : (isAnswered ? 'Answered' : 'Today'),
                          style: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          )),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // ── answer area ──────────────────────────────────────────
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: isAnswered
                        // Read-only when answered (any role)
                        ? Text(
                            answerText!.isNotEmpty ? answerText : '...',
                            style: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              color: Colors.black,
                              height: 1.3,
                            ))
                        // Pending: editable for both parent and child
                        : TextField(
                            controller: _ctrl,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              color: Colors.black,
                              height: 1.3,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Type here...',
                              hintStyle: TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                fontSize: 15,
                                fontStyle: FontStyle.italic,
                                color: Colors.black54,
                              ),
                              border: InputBorder.none,
                              isCollapsed: true,
                            ),
                          ),
                  ),
                ),
                // ── share toggle (child only) + save button (both roles) ──
                if (!isAnswered) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // "Share with parent" only makes sense for child role
                      if (!isParent)
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() => _shareWithParent = !_shareWithParent),
                          child: Row(children: [
                            SizedBox(
                              width: 24, height: 24,
                              child: Checkbox(
                                value: _shareWithParent,
                                onChanged: (v) => setState(() => _shareWithParent = v ?? true),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                side: const BorderSide(color: Colors.black, width: 1.4),
                                fillColor: WidgetStateProperty.resolveWith((_) => Colors.white),
                                checkColor: Colors.black,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('Share with parent',
                              style: TextStyle(
                                fontFamily: 'InstrumentSerif',
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                                color: Colors.black,
                              )),
                          ]),
                        ),
                      const Spacer(),
                      SizedBox(
                        width: 110, height: 42,
                        child: ElevatedButton(
                          onPressed: _saving ? null : () => _save(doc),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.55),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                          ),
                          child: _saving
                              ? const SizedBox(width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('SAVE', style: TextStyle(
                                  fontFamily: 'PlusJakartaSans',
                                  fontSize: 14,
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.6,
                                )),
                        ),
                      ),
                    ],
                  ),
                ],
                if (dateLabel.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(dateLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: Colors.black.withValues(alpha: 0.5),
                    )),
                ],
              ],
            ),
          ),
        ),
        _viewAllRow(),
      ],
    );
  }

  Widget _gradientShell({required Widget child}) {
    final isParent = widget.role == 'parent';
    // Parent → blue palette (matching NudgeLab "My Nudges" parent tab)
    // Child  → purple/warm palette (matching NudgeLab child tab)
    final colors = isParent
        ? const [Color(0xFFD8E3FF), Color(0xFFB9C8FF), Color(0xFF8FA6FF)]
        : const [Color(0xFF9E7BFF), Color(0xFFE6A46A), Color(0xFFF2C894)];
    final borderColor = isParent
        ? const Color(0xFF8FA6FF).withValues(alpha: 0.4)
        : Colors.black.withValues(alpha: 0.14);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: borderColor, width: 1.1),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0.0, 0.6, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _viewAllRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: GestureDetector(
        onTap: widget.onViewAll,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('View more nudges',
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF4A7C59).withValues(alpha: 0.85),
              )),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_forward_ios, size: 12, color: Color(0xFF4A7C59)),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Screen Time Limit Dialog — with reminder scheduler
// ══════════════════════════════════════════════════════════════════════════════

class _ScreenTimeLimitDialog extends StatefulWidget {
  final int initialLimit;
  final List<int> initialReminders;
  final int usedMinutes;
  final bool allowEditLimit;
  final void Function(int limit, List<int> reminders) onSave;

  const _ScreenTimeLimitDialog({
    required this.initialLimit,
    required this.initialReminders,
    required this.usedMinutes,
    required this.allowEditLimit,
    required this.onSave,
  });

  @override
  State<_ScreenTimeLimitDialog> createState() => _ScreenTimeLimitDialogState();
}

class _ScreenTimeLimitDialogState extends State<_ScreenTimeLimitDialog> {
  late double _limitSlider;
  late List<int> _reminders;
  double _pendingReminder = 10; // minutes before limit for new reminder

  @override
  void initState() {
    super.initState();
    _limitSlider = widget.initialLimit.toDouble().clamp(15, 360);
    _reminders = List.of(widget.initialReminders);
  }

  int get _limitMins => _limitSlider.round();

  String _fmtMins(int m) {
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? '${h}h' : '${h}h ${rem}m';
  }

  void _addReminder() {
    final v = _pendingReminder.round();
    if (!_reminders.contains(v) && _reminders.length < 5) {
      setState(() => _reminders.add(v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final minsLeft = (_limitMins - widget.usedMinutes).clamp(0, _limitMins);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── header ────────────────────────────────────────────────────
              const Text('Today\'s Screen Time',
                style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A2E),
                )),
              const SizedBox(height: 20),

              // ── daily limit slider (parent only) ──────────────────────────
              if (widget.allowEditLimit) ...[
                Row(
                  children: [
                    const Text('Daily limit',
                      style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14,
                          fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
                    const Spacer(),
                    Text(_fmtMins(_limitMins),
                      style: const TextStyle(fontFamily: 'PlusJakartaSans',
                          fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A1A2E))),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                    activeTrackColor: const Color(0xFF4A7C59),
                    inactiveTrackColor: const Color(0xFFD0D0E0),
                    thumbColor: const Color(0xFF4A7C59),
                  ),
                  child: Slider(
                    value: _limitSlider,
                    min: 15,
                    max: 360,
                    divisions: 23,
                    onChanged: (v) => setState(() => _limitSlider = v),
                  ),
                ),
                Text('Used today: ${widget.usedMinutes} min  •  $minsLeft min left',
                  style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                      color: Color(0xFF8A8AAA))),
              ] else ...[
                Row(
                  children: [
                    const Text('Daily limit (set by parent)',
                      style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14,
                          fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
                    const Spacer(),
                    Text(_fmtMins(_limitMins),
                      style: const TextStyle(fontFamily: 'PlusJakartaSans',
                          fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A1A2E))),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Used today: ${widget.usedMinutes} min  •  $minsLeft min left',
                  style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                      color: Color(0xFF8A8AAA))),
              ],

              const SizedBox(height: 22),
              const Divider(),
              const SizedBox(height: 14),

              // ── reminders section ─────────────────────────────────────────
              const Text('Remind me when time is running out',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14,
                    fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
              const SizedBox(height: 6),
              const Text('Add multiple alerts. Each fires X minutes before your limit.',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                    color: Color(0xFF8A8AAA))),
              const SizedBox(height: 12),

              // Slider + Add button
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_pendingReminder.round()} min before limit',
                          style: const TextStyle(fontFamily: 'PlusJakartaSans',
                              fontSize: 13, fontWeight: FontWeight.w500)),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                            activeTrackColor: const Color(0xFF7B6FCF),
                            inactiveTrackColor: const Color(0xFFD0D0E0),
                            thumbColor: const Color(0xFF7B6FCF),
                          ),
                          child: Slider(
                            value: _pendingReminder,
                            min: 5,
                            max: 60,
                            divisions: 11,
                            onChanged: (v) => setState(() => _pendingReminder = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _reminders.length >= 5 ? null : _addReminder,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _reminders.length >= 5
                            ? const Color(0xFFE0E0E0)
                            : const Color(0xFF4A7C59),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),

              // Reminder chips
              if (_reminders.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _reminders.sorted().map((r) => Chip(
                    label: Text('$r min',
                      style: const TextStyle(fontFamily: 'PlusJakartaSans',
                          fontSize: 13, fontWeight: FontWeight.w600)),
                    backgroundColor: const Color(0xFFECEBF8),
                    side: BorderSide.none,
                    deleteIcon: const Icon(Icons.close, size: 14),
                    deleteIconColor: const Color(0xFF8A8AAA),
                    onDeleted: () => setState(() => _reminders.remove(r)),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                  )).toList(),
                ),
              ],

              const SizedBox(height: 22),

              // ── action buttons ────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel',
                      style: TextStyle(fontFamily: 'PlusJakartaSans',
                          color: Color(0xFF8A8AAA))),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      widget.onSave(_limitMins, _reminders);
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A7C59),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                    ),
                    child: const Text('Save',
                      style: TextStyle(fontFamily: 'PlusJakartaSans',
                          fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _SortedList on List<int> {
  List<int> sorted() => List.of(this)..sort();
}

// ══════════════════════════════════════════════════════════════════════════════
// Session placeholder
// ══════════════════════════════════════════════════════════════════════════════

