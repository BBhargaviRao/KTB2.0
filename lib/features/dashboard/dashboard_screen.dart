import 'package:flutter/material.dart';
import 'package:ktb2/features/parent_login/parent_login_screen.dart';
import 'package:ktb2/features/child_login/child_login_screen.dart';

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

  static const _bg = Color(0xFFF0EEF8);
  static const _textDark = Color(0xFF1A1A2E);
  static const _textMid = Color(0xFF4A4A6A);
  static const _textLight = Color(0xFF8A8AAA);
  static const _barColor = Color(0xFFB3A9D4);

  // Returns true if the device is a tablet (iPad)
  bool get _isTablet => MediaQuery.of(context).size.shortestSide >= 600;

  void _onTabTapped(int index) {
    if (index == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => widget.role == 'parent'
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
        ),
      );
      return;
    }
    if (index == 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session feature coming soon')),
      );
      return;
    }
    setState(() => _selectedTab = index);
  }

  // Picks a value based on phone vs tablet
  double _s(double phone, double tablet) => _isTablet ? tablet : phone;

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

  @override
  Widget build(BuildContext context) {
    final hPad = _s(16.0, 32.0);   // horizontal padding
    final vGap = _s(12.0, 20.0);   // gap between cards
    final topPad = _s(24.0, 36.0); // top padding

    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
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
                    _buildTwoColumnRow(
                      left: _buildToDoCard(),
                      right: _buildJournalCard(),
                    ),
                    SizedBox(height: vGap),
                    _buildTwoColumnRow(
                      left: _buildMoodCard(),
                      right: _buildNotificationsCard(),
                    ),
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
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

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
                colors: [
                  Color(0xFF4CAF50),
                  Color(0xFFCD8B2C),
                  Color(0xFFC0392B),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarTile() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: _s(16, 24),
        vertical: _s(18, 26),
      ),
      decoration: _cardDecoration(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.calendar_month_outlined, color: _textMid, size: _s(22, 32)),
          SizedBox(width: _s(10, 16)),
          Text(
            'June 2026 — tap a day to open',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(15, 22),
              color: _textDark,
            ),
          ),
        ],
      ),
    );
  }

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

  Widget _buildToDoCard() {
    return Container(
      padding: EdgeInsets.all(_s(14, 24)),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          SizedBox(height: _s(12, 20)),
          _todoItem(label: 'Maths', blocked: false),
          SizedBox(height: _s(8, 14)),
          _todoItem(label: '10 min YouTube', blocked: false),
          SizedBox(height: _s(8, 14)),
          _todoItem(label: '15 min Poki', blocked: true),
        ],
      ),
    );
  }

  Widget _todoItem({required String label, required bool blocked}) {
    final boxSize = _s(17.0, 26.0);
    return Row(
      children: [
        if (blocked)
          Icon(Icons.tv_off_outlined, size: _s(17, 26), color: _textLight)
        else
          Container(
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
            label,
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontStyle: FontStyle.italic,
              fontSize: _s(14, 22),
              color: blocked ? _textLight : _textDark,
              decoration: blocked ? TextDecoration.lineThrough : null,
              decorationColor: _textLight,
            ),
          ),
        ),
      ],
    );
  }

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

  Widget _buildMoodCard() {
    const days = ['M', 'T', 'W', 'Th', 'F', 'S', 'Su'];
    const emojis = ['😊', '😐', '😊', '😊', null, null, null];

    return Container(
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: days
                .map((d) => Expanded(
                      child: Text(
                        d,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontStyle: FontStyle.italic,
                          fontSize: _s(10, 16),
                          color: _textLight,
                        ),
                      ),
                    ))
                .toList(),
          ),
          SizedBox(height: _s(6, 12)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(days.length, (i) {
              final emoji = emojis[i];
              final circleSize = _s(22.0, 36.0);
              if (emoji != null) {
                return Expanded(
                  child: Text(
                    emoji,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: _s(16, 26)),
                  ),
                );
              }
              return Expanded(
                child: Center(
                  child: Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _textLight.withValues(alpha: 0.35),
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
    );
  }

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

  Widget _buildTimeSpentChart() {
    final chartHeight = _s(90.0, 150.0);
    final barWidth = _s(44.0, 72.0);
    const bars = [
      ('Poki', 0.70),
      ('Mine', 0.35),
      ('Google', 0.08),
      ('YT', 0.92),
    ];

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
                    width: barWidth,
                    height: chartHeight * b.$2,
                    decoration: BoxDecoration(
                      color: _barColor,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(_s(6, 10)),
                      ),
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
        Text(
          name,
          style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontStyle: FontStyle.italic,
            fontSize: _s(14, 22),
            color: _textDark,
          ),
        ),
        Text(
          time,
          style: TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontStyle: FontStyle.italic,
            fontSize: _s(14, 22),
            color: _textMid,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: _s(8, 14)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _navItem(icon: Icons.dashboard_outlined, label: 'Dashboard', index: 0),
              _navItem(icon: Icons.send_outlined, label: 'Nudges', index: 1),
              _navItem(icon: Icons.lock_outline_rounded, label: 'Session', index: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final selected = _selectedTab == index;
    final color = selected ? _textDark : _textLight;

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
            Text(
              label,
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: _s(11, 16),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
