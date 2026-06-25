import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ktb2/features/parent_login/parent_login_screen.dart';
import 'package:ktb2/features/child_login/child_login_screen.dart';
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

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedTab = 0;
  DateTime _selectedDate = _todayDate();
  bool _todoExpanded = false;

  // Child's mood entries for the displayed week (child only)
  final Map<String, String> _moodEntries = {};

  // accountId of the child in this family (parent reads child mood via this)
  String? _childAccountId;

  // Local screen time reminder preferences (device-specific)
  List<int> _screenTimeReminders = [];

  // App usage data (Android only — loaded on initState and date change)
  List<AppUsageEntry> _usageEntries = [];
  bool _usagePermissionGranted = false;
  bool _usageLoading = false;

  // Parent: child's usage loaded from Firestore; toggle between views
  List<AppUsageEntry> _childUsageEntries = [];
  bool _childUsageLoading = false;
  bool _showChildUsage = true; // parent only — default to child's view

  // Total minutes used today: child = own device; parent = child's device (for limit bar)
  int get _usedMinutes {
    if (widget.role == 'child') {
      return _usageEntries.fold(0, (s, e) => s + e.timeMinutes);
    }
    return _childUsageEntries.fold(0, (s, e) => s + e.timeMinutes);
  }

  List<AppUsageEntry> get _activeEntries =>
      (widget.role == 'parent' && _showChildUsage) ? _childUsageEntries : _usageEntries;

  bool get _activeLoading =>
      (widget.role == 'parent' && _showChildUsage) ? _childUsageLoading : _usageLoading;

  // Cached streams — prevent stream recreation on every rebuild
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _todosStream;
  String? _todosStreamDateKey;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _settingsStream;

  // For cross-device todo notifications
  Timestamp? _lastKnownTodosUpdatedAt;
  bool _todoStreamInitialized = false;

  // For screen time limit change notifications
  int? _lastKnownScreenTimeLimit;
  bool _settingsStreamInitialized = false;

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

  @override
  void initState() {
    super.initState();
    _settingsStream = _familySettingsRef().snapshots();
    Future.microtask(_loadInitialData);
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
  }

  Future<void> _loadUsageStats(DateTime date) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final hasPermission = await UsageStatsService.hasPermission();
    if (!mounted) return;
    setState(() => _usagePermissionGranted = hasPermission);
    if (!hasPermission) return;
    setState(() => _usageLoading = true);
    final entries = await UsageStatsService.getDailyUsage(date);
    if (!mounted) return;
    setState(() {
      _usageEntries = entries;
      _usageLoading = false;
    });
    if (widget.role == 'child' && entries.isNotEmpty &&
        _dateKey(date) == _dateKey(DateTime.now())) {
      await _uploadUsageToFirestore(date, entries);
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
      final doc = await FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('accounts').doc(childId)
          .collection('usageStats').doc(_dateKey(date))
          .get();
      if (!mounted) return;
      final raw = doc.data()?['apps'] as List<dynamic>?;
      final apps = raw?.map((a) {
        final m = Map<String, dynamic>.from(a as Map);
        return AppUsageEntry(
          packageName: m['packageName'] as String? ?? '',
          appName: m['appName'] as String? ?? '',
          categoryLabel: m['categoryLabel'] as String? ?? 'Other',
          timeMinutes: (m['timeMinutes'] as num?)?.toInt() ?? 0,
        );
      }).toList() ?? [];
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
        setState(() => _childAccountId = snap.docs.first.id);
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
          // Todos are handled by StreamBuilder — no manual load needed.
          // Child: reload moods if we crossed into a different week.
          if (widget.role == 'child' && newMonday != prevMonday) {
            await _loadWeekMoods(d);
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
                SizedBox(height: vGap + 4),
                // 1 · Date bar
                _buildCalendarTile(),
                SizedBox(height: vGap),
                // 2 · Screen time bar
                _buildScreenTimeBar(),
                SizedBox(height: vGap),
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
            const _SessionPlaceholder(),
          ],
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Column(
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
    );
  }

  // ── screen time bar ───────────────────────────────────────────────────────

  Widget _buildScreenTimeBar() {
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
            });
          }
          if (limit != null) _lastKnownScreenTimeLimit = limit;
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

  // ── calendar tile ─────────────────────────────────────────────────────────

  Widget _buildCalendarTile() {
    return GestureDetector(
      onTap: _showCalendarDialog,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: _s(16, 24), vertical: _s(18, 26)),
        decoration: _cardDecoration(elevation: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.calendar_month_outlined, color: _textMid, size: _s(22, 32)),
            SizedBox(width: _s(10, 16)),
            Text(
              _formatDate(_selectedDate),
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: _s(15, 22),
                color: _textDark,
              ),
            ),
            SizedBox(width: _s(8, 12)),
            Icon(Icons.expand_more, color: _textLight, size: _s(18, 26)),
          ],
        ),
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
              stream: FirebaseFirestore.instance
                  .collection('families').doc(widget.familyId)
                  .collection('notifications')
                  .where('targetRole', isEqualTo: widget.role)
                  .orderBy('sentAt', descending: true)
                  .limit(20)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Unable to load', style: TextStyle(
                    fontSize: _s(12, 18), color: _textLight,
                    fontFamily: 'PlusJakartaSans',
                  ));
                }
                final docs = snap.data?.docs ?? [];
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

    final entries = _activeEntries;
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

    final maxTime  = entries.map((e) => e.timeMinutes).reduce((a, b) => a > b ? a : b);
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
                final label = entry.appName.length > 6
                    ? entry.appName.substring(0, 6)
                    : entry.appName;
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
    if (!hasData) {
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

class _SessionPlaceholder extends StatelessWidget {
  const _SessionPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text(
          'Session\ncoming soon',
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 20, color: Color(0xFF4A4A6A)),
        ),
      ),
    );
  }
}
