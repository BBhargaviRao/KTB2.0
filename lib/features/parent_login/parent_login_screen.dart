import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ParentLoginScreen extends StatefulWidget {
  final String parentName;
  final String familyId;
  final String parentAccountId;

  const ParentLoginScreen({
    super.key,
    required this.parentName,
    required this.familyId,
    required this.parentAccountId,
  });

  @override
  State<ParentLoginScreen> createState() => _ParentLoginScreenState();
}

class _ParentLoginScreenState extends State<ParentLoginScreen> {
  final Map<String, TextEditingController> _controllers = {};

  Future<void> _markNudgeOpened(String familyId, String nudgeId) async {
    final nudgeRef = FirebaseFirestore.instance
        .collection('families')
        .doc(familyId)
        .collection('nudges')
        .doc(nudgeId);

    final snap = await nudgeRef.get();

    if (!snap.exists) return;

    final data = snap.data();
    if (data == null) return;

    final openedAt = data['openedAt'];
    final notificationStatus = data['notificationStatus'];

    if (openedAt != null ||
        notificationStatus == 'opened' ||
        notificationStatus == 'answered') {
      return;
    }

    final sentAt = data['notificationSentAt'];
    final now = Timestamp.now();

    int? openLatencySeconds;

    if (sentAt is Timestamp) {
      openLatencySeconds = now.seconds - sentAt.seconds;
      if (openLatencySeconds < 0) {
        openLatencySeconds = 0;
      }
    }

    await nudgeRef.update({
      'openedAt': FieldValue.serverTimestamp(),
      'openLatencySeconds': openLatencySeconds,
    });
  }

  DocumentReference<Map<String, dynamic>> _nudgeSettingsRef() =>
      FirebaseFirestore.instance
          .collection('families').doc(widget.familyId)
          .collection('settings').doc('nudges');

  Future<void> _showNudgeWindowDialog(BuildContext context) async {
    final doc = await _nudgeSettingsRef().get();
    final data = doc.data();
    final w1 = data?['childWindow1'] as Map<String, dynamic>?;
    final w2 = data?['childWindow2'] as Map<String, dynamic>?;

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => _NudgeWindowDialog(
        initialWindow1Start: w1?['startHour'] as int? ?? 15,
        initialWindow1End: w1?['endHour'] as int? ?? 17,
        initialWindow2Start: w2?['startHour'] as int? ?? 18,
        initialWindow2End: w2?['endHour'] as int? ?? 20,
        onSave: (w1Start, w1End, w2Start, w2End) async {
          await _nudgeSettingsRef().set({
            'childWindow1': {'startHour': w1Start, 'endHour': w1End},
            'childWindow2': {'startHour': w2Start, 'endHour': w2End},
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedByRole': 'parent',
            'updatedByAccountId': widget.parentAccountId,
          }, SetOptions(merge: true));
        },
      ),
    );
  }

  bool _showChildNudges = false;

  bool _showUnanswered = true;
  bool _showAnswered = false;

  List<Color> get _bgColors => _showChildNudges
      ? const [
          Color(0xFFEFE9FF),
          Color(0xFFF4D7C8),
          Color(0xFFBFA9FF),
          Color(0xFFF0D4C7),
        ]
      : const [
          Color(0xFFBFD7FF),
          Color(0xFFB3CCFF),
          Color(0xFFA9C3FF),
          Color(0xFF9FB9FF),
        ];

  List<double> get _bgStops => _showChildNudges
      ? const [0.0, 0.38, 0.75, 1.0]
      : const [0.0, 0.35, 0.72, 1.0];

  List<Color> get _cardColors => _showChildNudges
      ? const [
          Color(0xFF9E7BFF),
          Color(0xFFE6A46A),
          Color(0xFFF2C894),
        ]
      : const [
          Color(0xFFD8E3FF),
          Color(0xFFB9C8FF),
          Color(0xFF8FA6FF),
        ];

  List<double> get _cardStops =>
      _showChildNudges ? const [0.0, 0.55, 1.0] : const [0.0, 0.6, 1.0];

  Stream<QuerySnapshot<Map<String, dynamic>>> _pendingParentStream() {
    return FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('nudges')
        .where('targetRole', isEqualTo: 'parent')
        .where('targetAccountId', isEqualTo: widget.parentAccountId)
        .where('status', isEqualTo: 'pending')
        .where('scheduledFor', isLessThanOrEqualTo: Timestamp.now())
        .orderBy('scheduledFor', descending: true)
        .snapshots();
    }

  Stream<QuerySnapshot<Map<String, dynamic>>> _answeredParentStream() {
    return FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('nudges')
        .where('targetRole', isEqualTo: 'parent')
        .where('targetAccountId', isEqualTo: widget.parentAccountId)
        .where('status', isEqualTo: 'answered')
        .orderBy('scheduledFor', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _childNudgesStream() {
    return FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('nudges')
        .where('targetRole', isEqualTo: 'child')
        .where('scheduledFor', isLessThanOrEqualTo: Timestamp.now())
        .orderBy('scheduledFor', descending: true)
        .snapshots();
    }

  void _openParentFiltersSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        bool tempUnanswered = _showUnanswered;
        bool tempAnswered = _showAnswered;

        return Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.black.withOpacity(0.10)),
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Filters',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    value: tempUnanswered,
                    onChanged: (v) =>
                        setModalState(() => tempUnanswered = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    activeColor: Colors.black,
                    checkColor: Colors.white,
                    title: const Text(
                      'Unanswered',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    value: tempAnswered,
                    onChanged: (v) =>
                        setModalState(() => tempAnswered = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    activeColor: Colors.black,
                    checkColor: Colors.white,
                    title: const Text(
                      'Answered',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _showUnanswered = tempUnanswered;
                          _showAnswered = tempAnswered;
                        });
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      child: const Text(
                        'Apply',
                        style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _parentFiltersPill() {
    if (_showChildNudges) return const SizedBox.shrink();

    final selectedCount = (_showUnanswered ? 1 : 0) + (_showAnswered ? 1 : 0);
    final label = selectedCount == 0 ? 'Filters' : 'Filters ($selectedCount)';

    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _openParentFiltersSheet,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.45),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.black.withOpacity(0.10),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: Colors.black.withOpacity(0.80),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  String _formatScheduledLabel(DateTime dt) {
    final weekday = DateFormat('EEEE').format(dt);
    final month = DateFormat('MMM').format(dt);
    final year = DateFormat('yyyy').format(dt);
    final time = DateFormat('h:mma').format(dt).toLowerCase();

    return '$weekday, ${_ordinal(dt.day)} $month $year, $time';
  }

  String? _relativeDayTag(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dt.year, dt.month, dt.day);

    final diff = today.difference(target).inDays;

    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return null;
  }

  DateTime _scheduledForAsDate(Map<String, dynamic> data) {
    final ts = data['scheduledFor'];
    if (ts is Timestamp) return ts.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String? _extractResponseText(Map<String, dynamic> data) {
    final resp = data['response'];
    if (resp is Map) {
      final t = resp['text'];
      if (t is String && t.trim().isNotEmpty) return t.trim();
    }
    return null;
  }

  Widget _buildParentPendingCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final nudgeId = doc.id;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markNudgeOpened(widget.familyId, nudgeId);
    });

    final prompt = (data['prompt'] ?? '') as String;
    final scheduledAt = _scheduledForAsDate(data);
    final createdLabel = _formatScheduledLabel(scheduledAt);
    final dayTag = _relativeDayTag(scheduledAt);

    final ctrl = _controllers.putIfAbsent(doc.id, () => TextEditingController());

    return _NudgeCard(
      question: prompt,
      createdAtLabel: createdLabel,
      dayTag: dayTag,
      controller: ctrl,
      onSave: () async {
        final answer = ctrl.text.trim();
        if (answer.isEmpty) return;

        final data = doc.data();
        final sentAt = data['notificationSentAt'];
        final now = Timestamp.now();

        int? responseLatencySeconds;

        if (sentAt is Timestamp) {
          responseLatencySeconds = now.seconds - sentAt.seconds;
          if (responseLatencySeconds < 0) {
            responseLatencySeconds = 0;
          }
        }

        await doc.reference.update({
          'status': 'answered',
          'response': {'text': answer},
          'answeredAt': FieldValue.serverTimestamp(),
          'responseLatencySeconds': responseLatencySeconds,
        });

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved')));
      },
      cardColors: _cardColors,
      cardStops: _cardStops,
    );
  }

  Widget _buildParentAnsweredCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final prompt = (data['prompt'] ?? '') as String;
    final scheduledAt = _scheduledForAsDate(data);
    final createdLabel = _formatScheduledLabel(scheduledAt);
    final dayTag = _relativeDayTag(scheduledAt);
    final answerText = _extractResponseText(data);

    return _ReadOnlyAnswerCard(
      question: prompt,
      createdAtLabel: createdLabel,
      dayTag: dayTag,
      answerText: answerText,
    );
  }

  Widget _buildChildNudgeCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final prompt = (data['prompt'] ?? '') as String;
    final scheduledAt = _scheduledForAsDate(data);
    final createdLabel = _formatScheduledLabel(scheduledAt);
    final dayTag = _relativeDayTag(scheduledAt);

    final status = (data['status'] ?? '') as String;
    final shareWithParent = data['shareWithParent'] == true;

    String? answerToShow;
    if (status == 'answered' && shareWithParent) {
      final text = _extractResponseText(data);
      if (text != null) answerToShow = text;
    }

    String privacyLine;
    if (status != 'answered') {
      privacyLine = 'Not answered yet.';
    } else if (!shareWithParent) {
      privacyLine = 'Answer not shared.';
    } else if (answerToShow == null) {
      privacyLine = 'Shared, but no answer text found.';
    } else {
      privacyLine = 'Shared by child';
    }

    return _ReadOnlyNudgeCard(
      question: prompt,
      createdAtLabel: createdLabel,
      dayTag: dayTag,
      answerText: answerToShow,
      privacyLine: privacyLine,
      emotionEmoji: data['emotionEmoji'] as String?,
      cardColors: _cardColors,
      cardStops: _cardStops,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showPending = !_showChildNudges && _showUnanswered;
    final showAnswered = !_showChildNudges && _showAnswered;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _bgColors,
            stops: _bgStops,
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'Nudges',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: MediaQuery.of(context).size.shortestSide >= 600 ? 40 : 30,
                      fontWeight: FontWeight.w400,
                      color: Colors.black,
                      height: 1.0,
                      letterSpacing: -0.41,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.black.withOpacity(0.10),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () =>
                              setState(() => _showChildNudges = false),
                          child: Text(
                            _showChildNudges ? 'My nudges' : 'My nudges ✓',
                            style: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () =>
                              setState(() => _showChildNudges = true),
                          child: Text(
                            _showChildNudges ? 'Child nudges ✓' : 'Child nudges',
                            style: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              if (_showChildNudges)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverToBoxAdapter(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                      onPressed: () => _showNudgeWindowDialog(context),
                      child: const Text(
                        'Set Delivery for Child',
                        style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C6FCD),
                        elevation: 3,
                        shadowColor: Colors.black.withOpacity(0.35),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
              SliverToBoxAdapter(child: _parentFiltersPill()),
              const SliverToBoxAdapter(child: SizedBox(height: 18)),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                sliver: SliverToBoxAdapter(
                  child: Builder(
                    builder: (context) {
                      if (_showChildNudges) {
                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _childNudgesStream(),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Text('Error: ${snapshot.error}');
                            }
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final docs = snapshot.data?.docs ?? [];
                            if (docs.isEmpty) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('No child nudges yet.'),
                                ),
                              );
                            }

                            return Column(
                              children: [
                                for (int i = 0; i < docs.length; i++) ...[
                                  _buildChildNudgeCardFromDoc(docs[i]),
                                  if (i != docs.length - 1)
                                    const SizedBox(height: 18),
                                ],
                              ],
                            );
                          },
                        );
                      }

                      if (!showPending && !showAnswered) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Select at least one filter.'),
                          ),
                        );
                      }

                      if (showPending && !showAnswered) {
                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _pendingParentStream(),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Text('Error: ${snapshot.error}');
                            }
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final docs = snapshot.data?.docs ?? [];
                            if (docs.isEmpty) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('No pending nudges 🎉'),
                                ),
                              );
                            }

                            return Column(
                              children: [
                                for (int i = 0; i < docs.length; i++) ...[
                                  _buildParentPendingCardFromDoc(docs[i]),
                                  if (i != docs.length - 1)
                                    const SizedBox(height: 18),
                                ],
                              ],
                            );
                          },
                        );
                      }

                      if (!showPending && showAnswered) {
                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _answeredParentStream(),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Text('Error: ${snapshot.error}');
                            }
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final docs = snapshot.data?.docs ?? [];
                            if (docs.isEmpty) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('No answered nudges yet.'),
                                ),
                              );
                            }

                            return Column(
                              children: [
                                for (int i = 0; i < docs.length; i++) ...[
                                  _buildParentAnsweredCardFromDoc(docs[i]),
                                  if (i != docs.length - 1)
                                    const SizedBox(height: 18),
                                ],
                              ],
                            );
                          },
                        );
                      }

                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _pendingParentStream(),
                        builder: (context, pendingSnap) {
                          if (pendingSnap.hasError) {
                            return Text('Error: ${pendingSnap.error}');
                          }
                          if (pendingSnap.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }

                          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                            stream: _answeredParentStream(),
                            builder: (context, answeredSnap) {
                              if (answeredSnap.hasError) {
                                return Text('Error: ${answeredSnap.error}');
                              }
                              if (answeredSnap.connectionState ==
                                  ConnectionState.waiting) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }

                              final pendingDocs = pendingSnap.data?.docs ?? [];
                              final answeredDocs = answeredSnap.data?.docs ?? [];

                              final all = <QueryDocumentSnapshot<Map<String, dynamic>>>[
                                ...pendingDocs,
                                ...answeredDocs,
                              ]..sort((a, b) {
                                  final adt = _scheduledForAsDate(a.data());
                                  final bdt = _scheduledForAsDate(b.data());
                                  return bdt.compareTo(adt);
                                });

                              if (all.isEmpty) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text('No nudges yet.'),
                                  ),
                                );
                              }

                              return Column(
                                children: [
                                  for (int i = 0; i < all.length; i++) ...[
                                    (all[i].data()['status'] == 'answered')
                                        ? _buildParentAnsweredCardFromDoc(all[i])
                                        : _buildParentPendingCardFromDoc(all[i]),
                                    if (i != all.length - 1)
                                      const SizedBox(height: 18),
                                  ],
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 22)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayTagPill extends StatelessWidget {
  final String label;

  const _DayTagPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.black,
        ),
      ),
    );
  }
}

class _NudgeCard extends StatelessWidget {
  final String question;
  final String createdAtLabel;
  final String? dayTag;
  final TextEditingController controller;
  final VoidCallback onSave;

  final List<Color> cardColors;
  final List<double> cardStops;

  const _NudgeCard({
    required this.question,
    required this.createdAtLabel,
    required this.dayTag,
    required this.controller,
    required this.onSave,
    required this.cardColors,
    required this.cardStops,
  });

  static const TextStyle _qaStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 22,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.15,
    letterSpacing: -0.2,
  );

  static const TextStyle _answerStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 18,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.25,
  );

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.shortestSide >= 600 ? 720 : 520),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.black.withOpacity(0.12),
              width: 1.0,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: cardColors,
              stops: cardStops,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: dayTag == null
                    ? const SizedBox.shrink()
                    : _DayTagPill(label: dayTag!),
              ),
              if (dayTag != null) const SizedBox(height: 10),
              Text(
                question,
                textAlign: TextAlign.left,
                style: _qaStyle,
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.32),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: 6,
                  style: _answerStyle,
                  decoration: const InputDecoration(
                    hintText: 'Type here...',
                    hintStyle: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 18,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w400,
                      color: Colors.black54,
                    ),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        offset: const Offset(0, 5),
                        blurRadius: 4,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: onSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.55),
                      foregroundColor: Colors.black,
                      elevation: 0, // IMPORTANT
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: const Text(
                      'SAVE',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 18,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  createdAtLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.black.withOpacity(0.65),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyNudgeCard extends StatelessWidget {
  final String question;
  final String createdAtLabel;
  final String? dayTag;
  final String? answerText;
  final String privacyLine;
  final String? emotionEmoji;

  final List<Color> cardColors;
  final List<double> cardStops;

  const _ReadOnlyNudgeCard({
    required this.question,
    required this.createdAtLabel,
    required this.dayTag,
    required this.answerText,
    required this.privacyLine,
    required this.emotionEmoji,
    required this.cardColors,
    required this.cardStops,
  });

  static const TextStyle _qaStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 22,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.15,
    letterSpacing: -0.2,
  );

  static const TextStyle _answerStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 18,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.25,
  );

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.shortestSide >= 600 ? 720 : 520),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.black.withOpacity(0.12),
              width: 1.0,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: cardColors,
              stops: cardStops,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: dayTag == null
                    ? const SizedBox.shrink()
                    : _DayTagPill(label: dayTag!),
              ),
              if (dayTag != null) const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      question,
                      textAlign: TextAlign.left,
                      style: _qaStyle,
                    ),
                  ),
                  if (emotionEmoji != null && emotionEmoji!.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(
                      emotionEmoji!,
                      style: const TextStyle(fontSize: 28),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                privacyLine,
                style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(0.70),
                ),
              ),
              if (answerText != null) ...[
                const SizedBox(height: 10),
                Text(
                  answerText!,
                  style: _answerStyle,
                ),
              ],
              const SizedBox(height: 12),
              Center(
                child: Text(
                  createdAtLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.black.withOpacity(0.65),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyAnswerCard extends StatelessWidget {
  final String question;
  final String createdAtLabel;
  final String? dayTag;
  final String? answerText;

  const _ReadOnlyAnswerCard({
    required this.question,
    required this.createdAtLabel,
    required this.dayTag,
    required this.answerText,
  });

  static const TextStyle _qaStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 22,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.15,
    letterSpacing: -0.2,
  );

  static const TextStyle _answerStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 18,
    fontStyle: FontStyle.italic,
    fontWeight: FontWeight.w400,
    color: Colors.black,
    height: 1.25,
  );

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.shortestSide >= 600 ? 720 : 520),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.44),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.black.withOpacity(0.10),
              width: 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: dayTag == null
                    ? const SizedBox.shrink()
                    : _DayTagPill(label: dayTag!),
              ),
              if (dayTag != null) const SizedBox(height: 10),
              Text(
                question,
                textAlign: TextAlign.left,
                style: _qaStyle,
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Answer ',
                    style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  const Text(
                    '✓',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                answerText ?? '(No answer text found)',
                style: _answerStyle,
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  createdAtLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.black.withOpacity(0.65),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Nudge delivery window dialog ──────────────────────────────────────────
// Lets the parent pick a 2-hour delivery window for each of the child's two
// daily nudges. Persisted to families/{familyId}/settings/nudges and read by
// the generateDailyNudges Cloud Function (childWindow1/childWindow2), so it
// stays in effect until the parent changes it again.
class _NudgeWindowDialog extends StatefulWidget {
  final int initialWindow1Start;
  final int initialWindow1End;
  final int initialWindow2Start;
  final int initialWindow2End;
  final Future<void> Function(int w1Start, int w1End, int w2Start, int w2End) onSave;

  const _NudgeWindowDialog({
    required this.initialWindow1Start,
    required this.initialWindow1End,
    required this.initialWindow2Start,
    required this.initialWindow2End,
    required this.onSave,
  });

  @override
  State<_NudgeWindowDialog> createState() => _NudgeWindowDialogState();
}

class _NudgeWindowDialogState extends State<_NudgeWindowDialog> {
  static const _purple = Color(0xFF7C6FCD);
  static const _purpleLight = Color(0xFFEDE9FF);

  late FixedExtentScrollController _hourCtrl1;
  late FixedExtentScrollController _periodCtrl1;
  late FixedExtentScrollController _hourCtrl2;
  late FixedExtentScrollController _periodCtrl2;

  late int _hour12_1; // 1-12
  late String _period1; // 'AM' | 'PM'
  late int _hour12_2;
  late String _period2;

  bool _saving = false;

  static const List<String> _hours = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12'];
  static const List<String> _periods = ['AM', 'PM'];

  @override
  void initState() {
    super.initState();
    _hour12_1 = _hour12From24(widget.initialWindow1Start);
    _period1 = widget.initialWindow1Start < 12 ? 'AM' : 'PM';
    _hour12_2 = _hour12From24(widget.initialWindow2Start);
    _period2 = widget.initialWindow2Start < 12 ? 'AM' : 'PM';

    _hourCtrl1 = FixedExtentScrollController(initialItem: _hour12_1 - 1);
    _periodCtrl1 = FixedExtentScrollController(initialItem: _period1 == 'AM' ? 0 : 1);
    _hourCtrl2 = FixedExtentScrollController(initialItem: _hour12_2 - 1);
    _periodCtrl2 = FixedExtentScrollController(initialItem: _period2 == 'AM' ? 0 : 1);
  }

  @override
  void dispose() {
    _hourCtrl1.dispose();
    _periodCtrl1.dispose();
    _hourCtrl2.dispose();
    _periodCtrl2.dispose();
    super.dispose();
  }

  static int _hour12From24(int start24) {
    final h = start24 % 12;
    return h == 0 ? 12 : h;
  }

  static int _start24From12(int hour12, String period) {
    final h = hour12 % 12;
    return period == 'AM' ? h : h + 12;
  }

  static String _fmtHour(int hour12, String period) => '$hour12:00 $period';

  String _fmtRange(int hour12, String period) {
    final start = _start24From12(hour12, period);
    final endMod = (start + 2) % 24;
    final endHour12 = _hour12From24(endMod);
    final endPeriod = endMod < 12 ? 'AM' : 'PM';
    return '${_fmtHour(hour12, period)} – ${_fmtHour(endHour12, endPeriod)}';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final w1Start = _start24From12(_hour12_1, _period1);
    final w2Start = _start24From12(_hour12_2, _period2);
    final w1End = (w1Start + 2).clamp(0, 24);
    final w2End = (w2Start + 2).clamp(0, 24);
    try {
      await widget.onSave(w1Start, w1End, w2Start, w2End);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  Widget _buildWheel<T>({
    required FixedExtentScrollController controller,
    required List<T> items,
    required ValueChanged<T> onChanged,
  }) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _purpleLight,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        ListWheelScrollView(
          controller: controller,
          itemExtent: 36,
          perspective: 0.003,
          diameterRatio: 1.3,
          physics: const FixedExtentScrollPhysics(),
          onSelectedItemChanged: (i) => onChanged(items[i]),
          children: items.map((item) => Center(
            child: Text('$item', style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _purple,
            )),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildWindowPicker({
    required String title,
    required int hour12,
    required String period,
    required FixedExtentScrollController hourCtrl,
    required FixedExtentScrollController periodCtrl,
    required ValueChanged<int> onHourChanged,
    required ValueChanged<String> onPeriodChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(
          fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w700, fontSize: 15, color: _purple)),
        const SizedBox(height: 4),
        Text(_fmtRange(hour12, period), style: TextStyle(
          fontFamily: 'PlusJakartaSans', fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 8),
        SizedBox(
          height: 130,
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildWheel<String>(
                  controller: hourCtrl,
                  items: _hours,
                  onChanged: (v) => onHourChanged(int.parse(v)),
                ),
              ),
              Expanded(
                flex: 2,
                child: _buildWheel<String>(
                  controller: periodCtrl,
                  items: _periods,
                  onChanged: onPeriodChanged,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Nudge Delivery Windows',
                    style: TextStyle(fontFamily: 'InstrumentSerif', fontSize: 24, color: _purple))),
                IconButton(
                  icon: const Icon(Icons.close, color: _purple),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              "Choose a 2-hour window for each of your child's daily nudges. "
              'This stays in effect until you change it again.',
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            _buildWindowPicker(
              title: 'First nudge window',
              hour12: _hour12_1,
              period: _period1,
              hourCtrl: _hourCtrl1,
              periodCtrl: _periodCtrl1,
              onHourChanged: (v) => setState(() => _hour12_1 = v),
              onPeriodChanged: (v) => setState(() => _period1 = v),
            ),
            const SizedBox(height: 20),
            _buildWindowPicker(
              title: 'Second nudge window',
              hour12: _hour12_2,
              period: _period2,
              hourCtrl: _hourCtrl2,
              periodCtrl: _periodCtrl2,
              onHourChanged: (v) => setState(() => _hour12_2 = v),
              onPeriodChanged: (v) => setState(() => _period2 = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save', style: TextStyle(
                        fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
