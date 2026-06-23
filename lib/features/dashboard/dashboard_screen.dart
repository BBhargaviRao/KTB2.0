import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:ktb2/features/parent_login/parent_login_screen.dart';
import 'package:ktb2/features/child_login/child_login_screen.dart';

// ── Task model ────────────────────────────────────────────────────────────────

class _Task {
  String text;
  bool done;
  _Task({required this.text, this.done = false});
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

  final List<_Task> _todos = [
    _Task(text: 'Maths'),
    _Task(text: '10 min YouTube'),
    _Task(text: '15 min Poki'),
  ];

  final Map<String, String> _moodEntries = {};

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

  BoxDecoration _cardDecoration() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_s(18, 24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 2),
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
        onDateSelected: (d) {
          setState(() => _selectedDate = d);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showTodoDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _TodoDialog(
        initialTasks: _todos.map((t) => _Task(text: t.text, done: t.done)).toList(),
        onSave: (updated) => setState(() {
          _todos..clear()..addAll(updated);
          _todoExpanded = false;
        }),
      ),
    );
  }

  void _showMoodDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (_) => _MoodDialog(
        moodEntries: Map.of(_moodEntries),
        selectedDate: _selectedDate,
        onSave: (updated) => setState(() {
          _moodEntries..clear()..addAll(updated);
        }),
      ),
    );
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
                _buildScreenTimeBar(),
                SizedBox(height: vGap),
                _buildCalendarTile(),
                SizedBox(height: vGap),
                _buildTwoColumnRow(left: _buildToDoCard(), right: _buildJournalCard()),
                SizedBox(height: vGap),
                _buildTwoColumnRow(left: _buildMoodCard(), right: _buildNotificationsCard()),
                SizedBox(height: vGap),
                _buildTimeSpentChart(),
                SizedBox(height: vGap),
                _buildMostUsedCard(),
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
        Text(
          'KidTechBalance',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'InstrumentSerif',
            fontSize: _s(38, 58),
            fontWeight: FontWeight.w400,
            color: _textDark,
            height: 1.1,
            letterSpacing: -0.5,
          ),
        ),
        SizedBox(height: _s(4, 8)),
        Text(
          'Welcome ${widget.displayName},',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'InstrumentSerif',
            fontSize: _s(22, 34),
            fontStyle: FontStyle.italic,
            color: _textMid,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  // ── screen time bar ───────────────────────────────────────────────────────

  Widget _buildScreenTimeBar() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 20), _s(16, 24), _s(16, 22)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Today's screen time",
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(14, 20),
              color: _textLight,
            ),
          ),
          SizedBox(height: _s(10, 16)),
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
        ],
      ),
    );
  }

  // ── calendar tile ─────────────────────────────────────────────────────────

  Widget _buildCalendarTile() {
    final today   = _todayDate();
    final isToday = _selectedDate == today;

    String label;
    if (isToday) {
      label = 'Today — tap to change';
    } else {
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      const wdays  = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      final d = _selectedDate;
      label = '${wdays[d.weekday - 1]}, ${d.day}${_ordinalSuffix(d.day)} ${months[d.month - 1]}';
    }

    return GestureDetector(
      onTap: _showCalendarDialog,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: _s(16, 24), vertical: _s(18, 26)),
        decoration: _cardDecoration(),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.calendar_month_outlined, color: _textMid, size: _s(22, 32)),
            SizedBox(width: _s(10, 16)),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: _s(15, 22),
                color: _textDark,
              ),
            ),
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
    final sorted  = [..._todos.where((t) => !t.done), ..._todos.where((t) => t.done)];
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
                Text(
                  'To-do',
                  style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontStyle: FontStyle.italic,
                    fontSize: _s(18, 28),
                    fontWeight: FontWeight.w700,
                    color: _textDark,
                  ),
                ),
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
          child: Text(
            task.text,
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(14, 22),
              color: task.done ? _textLight : _textDark,
              decoration: task.done ? TextDecoration.lineThrough : null,
              decorationColor: _textLight,
            ),
          ),
        ),
      ],
    );
  }

  // ── journal card ──────────────────────────────────────────────────────────

  Widget _buildJournalCard() {
    return Container(
      padding: EdgeInsets.all(_s(14, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Journal',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(18, 28),
              fontWeight: FontWeight.w700,
              color: _textDark,
            ),
          ),
          SizedBox(height: _s(12, 20)),
          Text(
            'How are you feeling today?',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(14, 22),
              color: _textMid,
            ),
          ),
          SizedBox(height: _s(10, 16)),
          Text(
            '2 pending nudges',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(13, 20),
              color: _textLight,
            ),
          ),
        ],
      ),
    );
  }

  // ── mood card ─────────────────────────────────────────────────────────────

  Widget _buildMoodCard() {
    final today  = _todayDate();
    final monday = today.subtract(Duration(days: today.weekday - 1));
    const labels = ['M', 'T', 'W', 'Th', 'F', 'S', 'Su'];
    final selKey = _dateKey(_selectedDate);

    return GestureDetector(
      onTap: _showMoodDialog,
      child: Container(
        padding: EdgeInsets.all(_s(14, 24)),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mood, this week',
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontStyle: FontStyle.italic,
                fontSize: _s(15, 26),
                fontWeight: FontWeight.w700,
                color: _textDark,
              ),
            ),
            SizedBox(height: _s(12, 20)),
            Row(
              children: labels.map((l) => Expanded(
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontStyle: FontStyle.italic,
                    fontSize: _s(10, 16),
                    color: _textLight,
                  ),
                ),
              )).toList(),
            ),
            SizedBox(height: _s(6, 12)),
            Row(
              children: List.generate(7, (i) {
                final day      = monday.add(Duration(days: i));
                final key      = _dateKey(day);
                final isToday  = day == today;
                final isFuture = day.isAfter(today);
                final emoji    = _moodEntries[key];
                final size     = _s(22.0, 36.0);
                final hasRing  = key == selKey && emoji != null;

                if (emoji != null) {
                  return Expanded(
                    child: Center(
                      child: Container(
                        width: size + 6,
                        height: size + 6,
                        decoration: hasRing
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: _green, width: 2.5),
                              )
                            : null,
                        child: Center(
                          child: Text(emoji, style: TextStyle(fontSize: _s(16, 26))),
                        ),
                      ),
                    ),
                  );
                }

                if (isToday) {
                  return Expanded(
                    child: Center(
                      child: Container(
                        width: size + 4,
                        height: size + 4,
                        decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                        child: Icon(Icons.add, color: Colors.white, size: _s(14, 22)),
                      ),
                    ),
                  );
                }

                return Expanded(
                  child: Center(
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _textLight.withValues(alpha: isFuture ? 0.25 : 0.45),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
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
          Text(
            'Notifications',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(15, 26),
              fontWeight: FontWeight.w700,
              color: _textDark,
            ),
          ),
          SizedBox(height: _s(12, 20)),
          _notifItem('Alert sent to mom, 1:13'),
          SizedBox(height: _s(8, 14)),
          _notifItem('Task completion sent, 1:47'),
        ],
      ),
    );
  }

  Widget _notifItem(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.send_outlined, size: _s(13, 20), color: _textLight),
        ),
        SizedBox(width: _s(6, 10)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(13, 20),
              color: _textMid,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  // ── time spent chart ──────────────────────────────────────────────────────

  Widget _buildTimeSpentChart() {
    final chartH  = _s(90.0, 150.0);
    final barW    = _s(44.0, 72.0);
    const bars    = [('Poki', 0.70), ('Mine', 0.35), ('Google', 0.08), ('YT', 0.92)];

    return Container(
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Time spent today',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(17, 28),
              fontWeight: FontWeight.w700,
              color: _textDark,
            ),
          ),
          SizedBox(height: _s(20, 30)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: bars.map((b) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    width: barW,
                    height: chartH * b.$2,
                    decoration: BoxDecoration(
                      color: _barColor,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(_s(6, 10))),
                    ),
                  ),
                  SizedBox(height: _s(8, 12)),
                  Text(
                    b.$1,
                    style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontStyle: FontStyle.italic,
                      fontSize: _s(11, 18),
                      color: _textLight,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ── most used card ────────────────────────────────────────────────────────

  Widget _buildMostUsedCard() {
    return Container(
      padding: EdgeInsets.fromLTRB(_s(16, 24), _s(14, 22), _s(16, 24), _s(16, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Most used',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(17, 28),
              fontWeight: FontWeight.w700,
              color: _textDark,
            ),
          ),
          SizedBox(height: _s(10, 18)),
          _mostUsedRow('1. Games', '46 min'),
          SizedBox(height: _s(8, 14)),
          _mostUsedRow('2. YouTube', '26 min'),
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

  static const _textDark  = Color(0xFF1A1A2E);
  static const _textMid   = Color(0xFF4A4A6A);
  static const _textLight = Color(0xFF8A8AAA);
  static const _green     = Color(0xFF4A7C59);

  @override
  void initState() {
    super.initState();
    _selected  = widget.selectedDate;
    _viewMonth = DateTime(_selected.year, _selected.month, 1);
  }

  String _monthLabel() {
    const months = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
    return '${months[_viewMonth.month - 1]} ${_viewMonth.year}';
  }

  bool get _canGoNext {
    final today = _todayDate();
    final next  = DateTime(_viewMonth.year, _viewMonth.month + 1, 1);
    return next.year < today.year || (next.year == today.year && next.month <= today.month);
  }

  String _formatFull(DateTime d) {
    const months = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
    const wdays  = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    return '${wdays[d.weekday - 1]}, ${d.day}${_ordinalSuffix(d.day)} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final today         = _todayDate();
    final firstOfMonth  = DateTime(_viewMonth.year, _viewMonth.month, 1);
    // Sun-first display: weekday Mon=1..Sun=7 → offset Sun=0, Mon=1 .. Sat=6
    final startOffset   = firstOfMonth.weekday % 7;
    final daysInMonth   = DateUtils.getDaysInMonth(_viewMonth.year, _viewMonth.month);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Month navigation
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  color: _textMid,
                  onPressed: () => setState(() =>
                      _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1, 1)),
                ),
                Text(_monthLabel(), style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _textDark,
                )),
                IconButton(
                  icon: Icon(Icons.chevron_right,
                      color: _canGoNext ? _textMid : _textLight.withValues(alpha: 0.3)),
                  onPressed: _canGoNext
                      ? () => setState(() =>
                          _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1, 1))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Day headers
            Row(
              children: ['S','M','T','W','Th','F','S'].map((d) => Expanded(
                child: Text(d,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _textLight,
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 6),
            // Grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 2,
                crossAxisSpacing: 0,
                childAspectRatio: 1,
              ),
              itemCount: startOffset + daysInMonth,
              itemBuilder: (_, idx) {
                if (idx < startOffset) return const SizedBox.shrink();
                final day       = DateTime(_viewMonth.year, _viewMonth.month, idx - startOffset + 1);
                final isFuture  = day.isAfter(today);
                final isSel     = day == _selected;
                final isToday   = day == today;

                Color bg        = Colors.transparent;
                Color textColor = _textDark;
                bool hasBorder  = false;

                if (isSel) {
                  bg        = _green;
                  textColor = Colors.white;
                } else if (isToday) {
                  hasBorder = true;
                  textColor = _green;
                } else if (isFuture) {
                  textColor = _textLight.withValues(alpha: 0.35);
                }

                return GestureDetector(
                  onTap: isFuture ? null : () {
                    setState(() => _selected = day);
                    widget.onDateSelected(day);
                  },
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: bg,
                      shape: BoxShape.circle,
                      border: hasBorder
                          ? Border.all(color: _green, width: 1.5)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${day.day}',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 15,
                        fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w400,
                        color: textColor,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFFE8E8F0)),
            const SizedBox(height: 12),
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

  void _addTask() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _tasks.add(_Task(text: text));
      _ctrl.clear();
    });
  }

  List<_Task> get _sorted => [
    ..._tasks.where((t) => !t.done),
    ..._tasks.where((t) => t.done),
  ];

  void _save() {
    final pending = _ctrl.text.trim();
    if (pending.isNotEmpty) _tasks.add(_Task(text: pending));
    widget.onSave(_sorted);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
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
            // Task list
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.42,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _taskRow(sorted[i]),
              ),
            ),
            const SizedBox(height: 12),
            // Add task input
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
                      style: const TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 15,
                        color: _textDark,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Add a task...',
                        hintStyle: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          color: _textLight,
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _addTask(),
                      textInputAction: TextInputAction.done,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Save button
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
              child: task.done
                  ? const Icon(Icons.check, color: Colors.white, size: 14)
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              task.text,
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 15,
                color: task.done ? _textLight : _textDark,
                decoration: task.done ? TextDecoration.lineThrough : null,
                decorationColor: _textLight,
              ),
            ),
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
    final today  = _todayDate();
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final selKey = _dateKey(widget.selectedDate);
    const dayLabels = ['M', 'T', 'W', 'Th', 'F', 'S', 'Su'];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Emoji picker bubble (shown above when active)
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
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
                    ),
                  )).toList(),
                ),
              ),
              // Triangle pointer
              Align(
                alignment: Alignment(
                  // Align with today's column position (weekday 1=Mon .. 7=Sun)
                  ((today.weekday - 1) / 3.0) - 1.0,
                  0,
                ),
                child: CustomPaint(
                  size: const Size(14, 8),
                  painter: _TrianglePainter(),
                ),
              ),
              const SizedBox(height: 4),
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
              children: dayLabels.map((l) => Expanded(
                child: Text(l,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: 13,
                    color: _textLight,
                  ),
                ),
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

                if (emoji != null) {
                  return Expanded(
                    child: Center(
                      child: Container(
                        width: size + 4,
                        height: size + 4,
                        decoration: isSel
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: _green, width: 2.5),
                              )
                            : null,
                        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
                      ),
                    ),
                  );
                }

                if (isToday) {
                  return Expanded(
                    child: Center(
                      child: GestureDetector(
                        onTap: () => setState(() => _showingPicker = !_showingPicker),
                        child: Container(
                          width: size,
                          height: size,
                          decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                          child: const Icon(Icons.add, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  );
                }

                return Expanded(
                  child: Center(
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _textLight.withValues(alpha: isFuture ? 0.2 : 0.4),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                );
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
    );
  }
}

// Small downward triangle for picker tooltip
class _TrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFF5F3FB);
    final path  = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_) => false;
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
          style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontSize: 20,
            color: Color(0xFF4A4A6A),
          ),
        ),
      ),
    );
  }
}
