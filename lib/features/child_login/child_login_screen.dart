import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ChildLoginScreen extends StatefulWidget {
  final String childName;
  final String familyId;
  final String childAccountId;

  const ChildLoginScreen({
    super.key,
    required this.childName,
    required this.familyId,
    required this.childAccountId,
  });

  @override
  State<ChildLoginScreen> createState() => _ChildLoginScreenState();
}

class _ChildLoginScreenState extends State<ChildLoginScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _shareWithParent = {};

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
      'notificationStatus': 'opened',
      'openedAt': FieldValue.serverTimestamp(),
      'openLatencySeconds': openLatencySeconds,
    });
  }

  // ✅ Filters (same as parent screen)
  bool _showUnanswered = true; // pending
  bool _showAnswered = false; // answered

  // ✅ Streams (pending + answered)
  Stream<QuerySnapshot<Map<String, dynamic>>> _pendingChildNudgesStream() {
    return FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('nudges')
        .where('targetRole', isEqualTo: 'child')
        .where('targetAccountId', isEqualTo: widget.childAccountId)
        .where('status', isEqualTo: 'pending')
        .orderBy('scheduledFor', descending: true) // ✅ latest on top
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _answeredChildNudgesStream() {
    return FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('nudges')
        .where('targetRole', isEqualTo: 'child')
        .where('targetAccountId', isEqualTo: widget.childAccountId)
        .where('status', isEqualTo: 'answered')
        .orderBy('scheduledFor', descending: true) // ✅ latest on top
        .snapshots();
  }

  // ---------- Filters UI (pill + bottom sheet) ----------
  void _openChildFiltersSheet() {
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

  Widget _childFiltersPill() {
    final selectedCount = (_showUnanswered ? 1 : 0) + (_showAnswered ? 1 : 0);
    final label = selectedCount == 0 ? 'Filters' : 'Filters ($selectedCount)';

    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _openChildFiltersSheet,
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

  // ---------- helpers ----------
  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime _scheduledForAsDate(Map<String, dynamic> data) {
    final ts = data['scheduledFor'];
    if (ts is Timestamp) return ts.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _labelFromScheduledFor(Map<String, dynamic> data) {
    final ts = data['scheduledFor'];
    if (ts is Timestamp) {
      final dt = ts.toDate();
      return '${dt.month}/${dt.day}/${dt.year}  ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '';
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
  Widget _buildChildPendingNudgeCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final nudgeId = doc.id;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markNudgeOpened(widget.familyId, nudgeId);
    });

    final prompt = (data['prompt'] ?? '') as String;

    final ctrl = _controllers.putIfAbsent(doc.id, () => TextEditingController());
    final currentShareValue = _shareWithParent.putIfAbsent(doc.id, () => true);

    return _ChildNudgeCard(
      question: prompt,
      controller: ctrl,
      shareWithParent: currentShareValue,
      onShareChanged: (v) {
        setState(() => _shareWithParent[doc.id] = v);
      },
      onSave: () async {
        final answer = ctrl.text.trim();
        if (answer.isEmpty) return;

        final share = _shareWithParent[doc.id] ?? true;

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
          'shareWithParent': share,
          'response': {'text': answer},
          'answeredAt': FieldValue.serverTimestamp(),
          'responseLatencySeconds': responseLatencySeconds,
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      },
    );
  }

  Widget _buildChildAnsweredNudgeCardFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final prompt = (data['prompt'] ?? '') as String;
    final createdLabel = _labelFromScheduledFor(data);
    final answerText = _extractResponseText(data);
    final shareWithParent = data['shareWithParent'] == true;

    final privacyLine = shareWithParent ? 'Shared with parent ✅' : 'Not shared';

    return _ReadOnlyChildAnswerCard(
      question: prompt,
      createdAtLabel: createdLabel,
      headerLine: 'Answered ✅',
      privacyLine: privacyLine,
      answerText: answerText,
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final showPending = _showUnanswered;
    final showAnswered = _showAnswered;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFBFD7FF),
              Color(0xFFB3CCFF),
              Color(0xFFA9C3FF),
              Color(0xFF9FB9FF),
            ],
            stops: [0.0, 0.35, 0.72, 1.0],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Child Login',
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF4EA4FF),
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 26)),
              const SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'NudgeLabKids',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 46,
                      fontWeight: FontWeight.w400,
                      color: Colors.black,
                      height: 1.0,
                      letterSpacing: -0.41,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'Welcome ${widget.childName},',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 30,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),

              // ✅ Filters pill (same behavior as parent)
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              SliverToBoxAdapter(child: _childFiltersPill()),
              const SliverToBoxAdapter(child: SizedBox(height: 18)),

              // ✅ Cards list (Firestore)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                sliver: SliverToBoxAdapter(
                  child: Builder(
                    builder: (context) {
                      // no filters selected
                      if (!showPending && !showAnswered) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Select at least one filter.'),
                          ),
                        );
                      }

                      // only pending
                      if (showPending && !showAnswered) {
                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _pendingChildNudgesStream(),
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
                                  child: Text('All done for now! 🎉'),
                                ),
                              );
                            }

                            return Column(
                              children: [
                                for (int i = 0; i < docs.length; i++) ...[
                                  _buildChildPendingNudgeCardFromDoc(docs[i]),
                                  if (i != docs.length - 1)
                                    const SizedBox(height: 18),
                                ],
                              ],
                            );
                          },
                        );
                      }

                      // only answered
                      if (!showPending && showAnswered) {
                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _answeredChildNudgesStream(),
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
                                  _buildChildAnsweredNudgeCardFromDoc(docs[i]),
                                  if (i != docs.length - 1)
                                    const SizedBox(height: 18),
                                ],
                              ],
                            );
                          },
                        );
                      }

                      // BOTH selected -> merge + sort locally (latest on top)
                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _pendingChildNudgesStream(),
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
                            stream: _answeredChildNudgesStream(),
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
                                  return bdt.compareTo(adt); // desc
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
                                        ? _buildChildAnsweredNudgeCardFromDoc(
                                            all[i],
                                          )
                                        : _buildChildPendingNudgeCardFromDoc(
                                            all[i],
                                          ),
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

class _ChildNudgeCard extends StatelessWidget {
  final String question;
  final TextEditingController controller;

  final bool shareWithParent;
  final ValueChanged<bool> onShareChanged;

  final VoidCallback onSave;

  const _ChildNudgeCard({
    required this.question,
    required this.controller,
    required this.shareWithParent,
    required this.onShareChanged,
    required this.onSave,
  });

  // ✅ Font change you mentioned: question + typed answer = PlusJakartaSans italic 400
  static const TextStyle _qaStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 24,
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            border: Border.all(
              color: Colors.black.withOpacity(0.18),
              width: 1.1,
            ),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFD8E3FF),
                Color(0xFFB9C8FF),
                Color(0xFF8FA6FF),
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
          child: Column(
            children: [
              // Question pill
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
                  style: _qaStyle,
                ),
              ),

              const SizedBox(height: 16),

              // Response box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: 7,
                  style: _answerStyle, // ✅ matches question font
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

              const SizedBox(height: 12),

              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    '...',
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 18,
                      color: const Color(0xFFFF6BC6).withOpacity(0.70),
                      height: 1.0,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _ShareWithParent(
                    value: shareWithParent,
                    onChanged: onShareChanged,
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 170,
                    height: 62,
                    child: ElevatedButton(
                      onPressed: onSave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.55),
                        foregroundColor: Colors.black,
                        elevation: 10,
                        shadowColor: Colors.black.withOpacity(0.25),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      child: const Text(
                        'SAVE',
                        style: TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 22,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
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

class _ReadOnlyChildAnswerCard extends StatelessWidget {
  final String question;
  final String createdAtLabel;
  final String headerLine;
  final String privacyLine;
  final String? answerText;

  const _ReadOnlyChildAnswerCard({
    required this.question,
    required this.createdAtLabel,
    required this.headerLine,
    required this.privacyLine,
    required this.answerText,
  });

  static const TextStyle _qaStyle = TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: 24,
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            border: Border.all(
              color: Colors.black.withOpacity(0.18),
              width: 1.1,
            ),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFD8E3FF),
                Color(0xFFB9C8FF),
                Color(0xFF8FA6FF),
              ],
              stops: [0.0, 0.55, 1.0],
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
                  style: _qaStyle,
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
                    const SizedBox(height: 6),
                    Text(
                      privacyLine,
                      style: TextStyle(
                        fontFamily: 'PlusJakartaSans',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(0.70),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      answerText ?? '(No answer text found)',
                      style: _answerStyle,
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

class _ShareWithParent extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ShareWithParent({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 6, bottom: 2, top: 2),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                side: BorderSide(
                  color: Colors.black.withOpacity(0.9),
                  width: 1.4,
                ),
                activeColor: Colors.transparent,
                checkColor: Colors.black,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Share this answer\nwith my parent',
              style: TextStyle(
                fontFamily: 'InstrumentSerif',
                fontSize: 18,
                fontStyle: FontStyle.italic,
                color: Colors.black,
                height: 1.05,
              ),
            ),
          ],
        ),
      ),
    );
  }
}