import 'package:flutter/material.dart';
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

    if (openedAt != null || notificationStatus == 'opened' || notificationStatus == 'answered') {
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
      'notificationStatus': 'opened',
      'openedAt': FieldValue.serverTimestamp(),
      'openLatencySeconds': openLatencySeconds,
    });
  }

  // ✅ Tab toggle
  bool _showChildNudges = false;

  // ✅ Parent-only multi-select filters
  bool _showUnanswered = true; // pending
  bool _showAnswered = false; // answered

  // --- Theme helpers (Parent vs Child view) ---
  List<Color> get _bgColors => _showChildNudges
      ? const [
          Color(0xFFBFD7FF),
          Color(0xFFB3CCFF),
          Color(0xFFA9C3FF),
          Color(0xFF9FB9FF),
        ]
      : const [
          Color(0xFFEFE9FF),
          Color(0xFFF4D7C8),
          Color(0xFFBFA9FF),
          Color(0xFFF0D4C7),
        ];

  List<double> get _bgStops => _showChildNudges
      ? const [0.0, 0.35, 0.72, 1.0]
      : const [0.0, 0.38, 0.75, 1.0];

  List<Color> get _cardColors => _showChildNudges
      ? const [
          Color(0xFFD8E3FF),
          Color(0xFFB9C8FF),
          Color(0xFF8FA6FF),
        ]
      : const [
          Color(0xFF9E7BFF),
          Color(0xFFE6A46A),
          Color(0xFFF2C894),
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
        .orderBy('scheduledFor', descending: true)
        .snapshots();
  }

  // ---------- Filters UI (pill + dropdown) ----------
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

  String _labelFromScheduledFor(Map<String, dynamic> data) {
    String createdLabel = '';
    final ts = data['scheduledFor'];
    if (ts is Timestamp) {
      final dt = ts.toDate();
      createdLabel =
          '${dt.month}/${dt.day}/${dt.year}  ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return createdLabel;
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

  // ---------- card builders ----------
  Widget _buildParentPendingCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final nudgeId = doc.id;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markNudgeOpened(widget.familyId, nudgeId);
    });

    final prompt = (data['prompt'] ?? '') as String;
    final createdLabel = _labelFromScheduledFor(data);

    final ctrl = _controllers.putIfAbsent(doc.id, () => TextEditingController());

    return _NudgeCard(
      question: prompt,
      createdAtLabel: createdLabel,
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
          'notificationStatus': 'answered',
          'response': {'text': answer},
          'answeredAt': FieldValue.serverTimestamp(),
          'responseLatencySeconds': responseLatencySeconds,
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      },
      cardColors: const [
        Color(0xFF9E7BFF),
        Color(0xFFE6A46A),
        Color(0xFFF2C894),
      ],
      cardStops: const [0.0, 0.6, 1.0],
    );
  }

  Widget _buildParentAnsweredCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final prompt = (data['prompt'] ?? '') as String;
    final createdLabel = _labelFromScheduledFor(data);
    final answerText = _extractResponseText(data);

    return _ReadOnlyAnswerCard(
      question: prompt,
      createdAtLabel: createdLabel,
      answerText: answerText,
      headerLine: 'Answered ✅',
      cardColors: const [
        Color(0xFF9E7BFF),
        Color(0xFFE6A46A),
        Color(0xFFF2C894),
      ],
      cardStops: const [0.0, 0.6, 1.0],
    );
  }

  Widget _buildChildNudgeCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final prompt = (data['prompt'] ?? '') as String;
    final createdLabel = _labelFromScheduledFor(data);

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
      privacyLine = 'Shared by child ✅';
    }

    return _ReadOnlyNudgeCard(
      question: prompt,
      createdAtLabel: createdLabel,
      answerText: answerToShow,
      privacyLine: privacyLine,
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
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
              SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    _showChildNudges ? 'NudgeLabKids' : 'NudgeLab',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 48,
                      fontWeight: FontWeight.w400,
                      color: Colors.black,
                      height: 1.0,
                      letterSpacing: -0.41,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 18)),
              SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'Welcome ${widget.parentName}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 32,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

class _NudgeCard extends StatelessWidget {
  final String question;
  final String createdAtLabel;
  final TextEditingController controller;
  final VoidCallback onSave;

  final List<Color> cardColors;
  final List<double> cardStops;

  const _NudgeCard({
    required this.question,
    required this.createdAtLabel,
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
        constraints: const BoxConstraints(maxWidth: 520),
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
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  question,
                  textAlign: TextAlign.center,
                  style: _qaStyle, // ✅ PlusJakartaSans italic 400
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: 6,
                  style: _answerStyle, // ✅ typed answer matches question font
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
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onSave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withOpacity(0.55),
                    foregroundColor: Colors.black,
                    elevation: 6,
                    shadowColor: Colors.black.withOpacity(0.20),
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
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                createdAtLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'InstrumentSerif',
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: Colors.black.withOpacity(0.65),
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
  final String? answerText;
  final String privacyLine;

  final List<Color> cardColors;
  final List<double> cardStops;

  const _ReadOnlyNudgeCard({
    required this.question,
    required this.createdAtLabel,
    required this.answerText,
    required this.privacyLine,
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
        constraints: const BoxConstraints(maxWidth: 520),
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
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  question,
                  textAlign: TextAlign.center,
                  style: _qaStyle, // ✅ updated
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                        style: _answerStyle, // ✅ updated
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                createdAtLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'InstrumentSerif',
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: Colors.black.withOpacity(0.65),
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
  final String? answerText;
  final String headerLine;

  final List<Color> cardColors;
  final List<double> cardStops;

  const _ReadOnlyAnswerCard({
    required this.question,
    required this.createdAtLabel,
    required this.answerText,
    required this.headerLine,
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
        constraints: const BoxConstraints(maxWidth: 520),
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
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  question,
                  textAlign: TextAlign.center,
                  style: _qaStyle, // ✅ updated
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headerLine,
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      answerText ?? '(No answer text found)',
                      style: _answerStyle, // ✅ updated
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                createdAtLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'InstrumentSerif',
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  color: Colors.black.withOpacity(0.65),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}