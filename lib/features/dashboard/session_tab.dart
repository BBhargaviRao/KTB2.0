import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:ktb2/services/usage_stats_service.dart';
import 'package:ktb2/services/notification_service.dart';

// ── palette ────────────────────────────────────────────────────────────────────
const _bg          = Color(0xFFF5F3FF);
const _textDark    = Color(0xFF2D2B55);
const _textMid     = Color(0xFF6E6A8E);
const _purple      = Color(0xFF7C6FCD);
const _purpleLight = Color(0xFFEDE9FF);
const _border      = Color(0xFFE0DDEF);
const _green       = Color(0xFF4CAF50);

// ── session statuses ───────────────────────────────────────────────────────────
// 'pending'           → parent wrote duration+tasks, child device shows app picker
// 'apps_selected'     → child confirmed apps, parent can now press Start
// 'active'            → session running
// 'override_requested'→ child requested early end, waiting for parent
// 'completed'         → ended normally or parent pressed End Early
// 'completed_override'→ ended by approved override

// ── models ─────────────────────────────────────────────────────────────────────
class _STask {
  String text;
  int durationMinutes;
  bool done;
  _STask({required this.text, this.durationMinutes = 10, this.done = false});
}

class _AppEntry {
  final String packageName;
  final String appName;
  final String categoryLabel;
  bool allowed;
  _AppEntry({
    required this.packageName,
    required this.appName,
    required this.categoryLabel,
    this.allowed = true,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// SessionTab
// ═══════════════════════════════════════════════════════════════════════════════
class SessionTab extends StatefulWidget {
  final String  familyId;
  final String  role;
  final String? childAccountId;
  final String? childIosVendorId;

  const SessionTab({
    super.key,
    required this.familyId,
    required this.role,
    this.childAccountId,
    this.childIosVendorId,
  });

  @override
  State<SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends State<SessionTab> {
  // Stream is created ONCE in initState — the key fix for the glitch where the
  // stream reset on every parent-widget rebuild.
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream;

  // Tracks which active-session popup we've shown so we don't repeat it.
  String? _shownPopupForSessionId;

  // Tracks which session we've applied iOS ManagedSettings restrictions for.
  // Prevents re-applying on every build while session is active.
  String? _appliedRestrictionsForSession;

  // Guards the "no active session" clear-restrictions call so it only fires
  // once per idle period. Unlike _appliedRestrictionsForSession, this must
  // NOT rely on having witnessed the active→ended transition: if the child's
  // app was closed when the session ended, this widget is recreated fresh on
  // next launch with _appliedRestrictionsForSession == null, so the old
  // transition check never fired and the shield was left stuck forever.
  bool _didClearOnEntry = false;

  // Tracks which session the Android blocking service is running for.
  String? _blockingServiceSessionId;

  @override
  void initState() {
    super.initState();
    _stream = FirebaseFirestore.instance
        .collection('families')
        .doc(widget.familyId)
        .collection('sessions')
        .where('dateKey', isEqualTo: _todayKey())
        .snapshots();
  }

  @override
  void didUpdateWidget(SessionTab old) {
    super.didUpdateWidget(old);
    if (old.familyId != widget.familyId) {
      setState(() {
        _stream = FirebaseFirestore.instance
            .collection('families')
            .doc(widget.familyId)
            .collection('sessions')
            .where('dateKey', isEqualTo: _todayKey())
            .snapshots();
      });
    }
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _sessions =>
      _db.collection('families').doc(widget.familyId).collection('sessions');

  // ── parent: step 1 complete → write pending session ────────────────────────
  Future<String> _writePendingSession({
    required int durationMinutes,
    required List<_STask> tasks,
  }) async {
    final ref = _sessions.doc();
    await ref.set({
      'status':          'pending',
      'durationMinutes': durationMinutes,
      'dateKey':         _todayKey(),
      'createdBy':       widget.role,
      'createdAt':       FieldValue.serverTimestamp(),
      'tasks': tasks.map((t) => {
        'text':            t.text,
        'durationMinutes': t.durationMinutes,
        'done':            false,
      }).toList(),
    });
    return ref.id;
  }

  // ── child: confirm app selection → status = apps_selected ─────────────────
  Future<void> _confirmApps(String sessionId, List<_AppEntry> apps) async {
    await _sessions.doc(sessionId).update({
      'status':      'apps_selected',
      'allowedApps': apps.where((a) =>  a.allowed).map((a) => {
        'packageName': a.packageName, 'appName': a.appName,
      }).toList(),
      'blockedApps': apps.where((a) => !a.allowed).map((a) => {
        'packageName': a.packageName, 'appName': a.appName,
      }).toList(),
    });
  }

  // ── parent: start session → status = active ────────────────────────────────
  Future<void> _startSession(String sessionId, int durationMinutes, List<dynamic> tasks) async {
    final now = DateTime.now();
    final end = now.add(Duration(minutes: durationMinutes));
    await _sessions.doc(sessionId).update({
      'status':    'active',
      'startTime': Timestamp.fromDate(now),
      'endTime':   Timestamp.fromDate(end),
    });

    // Update settings so the dashboard bar shows session progress
    await _db
        .collection('families').doc(widget.familyId)
        .collection('settings').doc('screenTime')
        .set({
          'screenTimeLimitMinutes':   durationMinutes,
          'activeSessionId':          sessionId,
          'activeSessionStartMillis': now.millisecondsSinceEpoch,
          'updatedByRole':            'parent',
        }, SetOptions(merge: true));

    // Prepend session tasks to family daily to-do list
    final dateKey  = _todayKey();
    final dailyRef = _db
        .collection('families').doc(widget.familyId)
        .collection('dailyData').doc(dateKey);
    final snap     = await dailyRef.get();
    final existing = (snap.data()?['todos'] as List<dynamic>? ?? [])
        .where((t) => (t as Map)['sessionId'] != sessionId)
        .toList();
    final sTodos = tasks.asMap().entries.map((entry) {
      final m = entry.value as Map<String, dynamic>;
      return {
        'text':      '${m['text']} (${m['durationMinutes']}m)',
        'done':      false,
        'addedBy':   'parent',
        'sessionId': sessionId,
        'taskIndex': entry.key,
      };
    }).toList();
    await dailyRef.set({
      'todos':          [...sTodos, ...existing],
      'todosUpdatedAt': FieldValue.serverTimestamp(),
      'updatedByRole':  'parent',
      'dateKey':        dateKey,
    }, SetOptions(merge: true));
  }

  // ── parent: end session ────────────────────────────────────────────────────
  Future<void> _endSession(String sessionId) async {
    await _sessions.doc(sessionId).update({
      'status':  'completed',
      'endTime': Timestamp.now(),
    });
    await _db
        .collection('families').doc(widget.familyId)
        .collection('settings').doc('screenTime')
        .set({
          'activeSessionId':          null,
          'activeSessionStartMillis': null,
        }, SetOptions(merge: true));
  }

  // ── child: request override ────────────────────────────────────────────────
  Future<void> _requestOverride(String sessionId) async {
    await _sessions.doc(sessionId).update({
      'status': 'override_requested',
      'overrideRequest': {
        'status':      'pending',
        'requestedAt': Timestamp.now(),
      },
    });
  }

  // ── parent: respond to override ───────────────────────────────────────────
  Future<void> _respondOverride(String sessionId, bool approve) async {
    if (approve) {
      await _sessions.doc(sessionId).update({
        'status': 'completed_override',
        'endTime': Timestamp.now(),
        'overrideRequest.status': 'approved',
      });
      await _db
          .collection('families').doc(widget.familyId)
          .collection('settings').doc('screenTime')
          .set({
            'activeSessionId':          null,
            'activeSessionStartMillis': null,
          }, SetOptions(merge: true));
    } else {
      await _sessions.doc(sessionId).update({
        'status': 'active',
        'overrideRequest.status': 'denied',
      });
    }
  }

  // ── iOS child: confirm native FamilyActivityPicker selection ─────────────
  // The actual app tokens are already persisted in the App Group by AppDelegate;
  // this just advances the Firestore session status so the parent can start.
  Future<void> _confirmAppsIos(String sessionId) async {
    await _sessions.doc(sessionId).update({
      'status':             'apps_selected',
      'iosNativeSelection': true,
      'allowedApps':        [],
      'blockedApps':        [],
    });
  }

  // ── cancel a pending session (before it starts) ───────────────────────────
  Future<void> _cancelPending(String sessionId) async {
    await _sessions.doc(sessionId).update({'status': 'completed'});
  }

  CollectionReference<Map<String, dynamic>> get _savedSessions =>
      _db.collection('families').doc(widget.familyId).collection('savedSessions');

  // ── parent: save a session's apps+tasks as a named, repeatable template ───
  Future<void> _saveAsTemplate(Map<String, dynamic> data) async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save this session'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Homework time'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final tasks = (data['tasks'] as List<dynamic>? ?? []).map((t) {
      final m = t as Map<String, dynamic>;
      return {'text': m['text'], 'durationMinutes': m['durationMinutes']};
    }).toList();

    await _savedSessions.add({
      'name':               name,
      'durationMinutes':    data['durationMinutes'],
      'tasks':              tasks,
      'allowedApps':        data['allowedApps'] ?? [],
      'blockedApps':        data['blockedApps'] ?? [],
      'iosNativeSelection': data['iosNativeSelection'] ?? false,
      'createdAt':          FieldValue.serverTimestamp(),
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "$name" for quick reuse')),
      );
    }
  }

  // ── parent: re-run a saved template — skips task entry + app picking ──────
  // by writing status straight to apps_selected (same state a normal session
  // reaches after the child confirms apps), reusing the saved apps/tasks.
  Future<void> _runSavedSession(Map<String, dynamic> data) async {
    final tasks = (data['tasks'] as List<dynamic>? ?? []).map((t) {
      final m = t as Map<String, dynamic>;
      return {'text': m['text'], 'durationMinutes': m['durationMinutes'], 'done': false};
    }).toList();

    await _sessions.doc().set({
      'status':             'apps_selected',
      'durationMinutes':    data['durationMinutes'],
      'dateKey':            _todayKey(),
      'createdBy':          widget.role,
      'createdAt':          FieldValue.serverTimestamp(),
      'tasks':              tasks,
      'allowedApps':        data['allowedApps'] ?? [],
      'blockedApps':        data['blockedApps'] ?? [],
      'iosNativeSelection': data['iosNativeSelection'] ?? false,
    });
  }

  Future<void> _deleteSavedSession(String id) async {
    await _savedSessions.doc(id).delete();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (ctx, snap) {
        if (snap.hasError) {
          return Scaffold(
            backgroundColor: _bg,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Could not load sessions.\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'PlusJakartaSans',
                      color: _textMid, fontSize: 13),
                ),
              ),
            ),
          );
        }

        final docs = (snap.data?.docs ?? [])
          ..sort((a, b) {
            final ta = (a.data()['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
            final tb = (b.data()['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
            return tb.compareTo(ta);
          });

        // Separate by status
        final activeDoc   = docs.where((d) => d.data()['status'] == 'active').firstOrNull;
        final pendingDoc  = docs.where((d) => d.data()['status'] == 'pending').firstOrNull;
        final appsReadyDoc= docs.where((d) => d.data()['status'] == 'apps_selected').firstOrNull;
        final overrideDoc = docs.where((d) => d.data()['status'] == 'override_requested').firstOrNull;
        final currentDoc  = overrideDoc ?? activeDoc ?? appsReadyDoc ?? pendingDoc;
        final pastDocs    = docs.where((d) => ['completed', 'completed_override'].contains(d.data()['status'])).toList();

        // Show "session started" popup on child's device once per session
        if (widget.role == 'child' && activeDoc != null &&
            _shownPopupForSessionId != activeDoc.id) {
          _shownPopupForSessionId = activeDoc.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showStartedPopup(context, activeDoc.data());
          });
        }
        // Reset popup tracker when no active session
        if (activeDoc == null && overrideDoc == null) {
          _shownPopupForSessionId = null;
        }

        // Android child: start/stop AppBlockerService when session goes active/ends.
        // Use Future.microtask (not addPostFrameCallback) so it fires even when
        // Flutter is backgrounded behind the overlay.
        // Gated on snap.hasData for the same reason as the iOS block below —
        // a fresh subscription's first placeholder build must never be read
        // as "no active session".
        if (Platform.isAndroid && widget.role == 'child' && snap.hasData) {
          final newActiveId = activeDoc?.id;
          if (newActiveId != null && _blockingServiceSessionId != newActiveId) {
            _blockingServiceSessionId = newActiveId;
            final allowedPackages = (activeDoc!.data()['allowedApps'] as List<dynamic>? ?? [])
                .map((a) => (a as Map)['packageName'] as String? ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
            Future.microtask(() async {
              final ok = await UsageStatsService.startBlockingService(
                  allowedPackages, widget.familyId, newActiveId);
              // A failed native call (permission dialog stealing focus, a
              // timing hiccup right after login, etc.) used to permanently
              // block tracking for the rest of the session with zero retry
              // and zero visibility. Clearing the guard lets the next
              // Firestore snapshot try again instead of silently giving up.
              if (!ok && mounted && _blockingServiceSessionId == newActiveId) {
                setState(() => _blockingServiceSessionId = null);
              }
            });
          } else if (newActiveId == null && overrideDoc == null &&
              _blockingServiceSessionId != null) {
            _blockingServiceSessionId = null;
            Future.microtask(() => UsageStatsService.stopBlockingService());
          }
        }

        // iOS child: apply ManagedSettings restrictions when session goes active;
        // clear them when the session ends (any terminal status).
        //
        // Gated on snap.hasData: a fresh StreamBuilder subscription (e.g. the
        // app was reopened after being closed mid-session) first builds with
        // NO data at all — snap.data is null, so activeDoc computes as null
        // even though a session is genuinely still active and Firestore just
        // hasn't delivered its first snapshot yet. Without this guard, that
        // one placeholder frame was read as "no active session" and
        // immediately cleared the shield, unlocking every blocked app until
        // the real snapshot arrived a moment later (which only reapplied the
        // shield if that follow-up actually ran — an unnecessary window of
        // full access that shouldn't exist at all).
        if (Platform.isIOS && widget.role == 'child' && snap.hasData) {
          final newActiveId = activeDoc?.id;
          if (newActiveId != null && _appliedRestrictionsForSession != newActiveId) {
            _appliedRestrictionsForSession = newActiveId;
            _didClearOnEntry = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              UsageStatsService.applySessionRestrictions();
            });
          } else if (newActiveId == null && overrideDoc == null && !_didClearOnEntry) {
            _appliedRestrictionsForSession = null;
            _didClearOnEntry = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              UsageStatsService.clearSessionRestrictions();
            });
          }
        }

        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
              children: [
                const Text('Sessions',
                    style: TextStyle(fontFamily: 'InstrumentSerif',
                        fontSize: 36, color: _textDark, height: 1.1)),
                const SizedBox(height: 4),
                const Text("Today's screen time sessions",
                    style: TextStyle(fontFamily: 'PlusJakartaSans',
                        fontSize: 14, color: _textMid)),
                const SizedBox(height: 28),

                // ── main card (status-dependent) ──────────────────────────
                if (overrideDoc != null)
                  _buildOverrideCard(overrideDoc)
                else if (activeDoc != null)
                  _ActiveCard(
                    doc: activeDoc, role: widget.role,
                    familyId: widget.familyId,
                    onEnd: () => _endSession(activeDoc.id),
                    onRequestOverride: () => _requestOverride(activeDoc.id),
                    onSaveTemplate: widget.role == 'parent'
                        ? () => _saveAsTemplate(activeDoc.data())
                        : null,
                  )
                else if (widget.role == 'parent' && appsReadyDoc != null)
                  _AppsReadyCard(
                    doc: appsReadyDoc,
                    onStart: () => _startSession(
                      appsReadyDoc.id,
                      appsReadyDoc.data()['durationMinutes'] as int? ?? 30,
                      appsReadyDoc.data()['tasks'] as List<dynamic>? ?? [],
                    ),
                    onCancel: () => _cancelPending(appsReadyDoc.id),
                  )
                else if (widget.role == 'child' && (appsReadyDoc != null))
                  _ChildWaitingCard(message: 'Waiting for parent to start the session…')
                else if (widget.role == 'child' && pendingDoc != null)
                  _ChildAppPickerCard(
                    doc: pendingDoc,
                    familyId: widget.familyId,
                    childIosVendorId: widget.childIosVendorId,
                    onConfirm: (apps) => _confirmApps(pendingDoc.id, apps),
                    onConfirmIos: () => _confirmAppsIos(pendingDoc.id),
                  )
                else if (widget.role == 'parent' && pendingDoc != null)
                  _ParentWaitingCard(
                    doc: pendingDoc,
                    onCancel: () => _cancelPending(pendingDoc.id),
                  )
                else
                  _EmptyCard(role: widget.role),

                const SizedBox(height: 14),

                // ── start button (parent, no current session) ─────────────
                if (widget.role == 'parent' && currentDoc == null)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _purple, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      onPressed: () => showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => _SessionCreatorDialog(
                          onPendingCreated: (dur, tasks) => _writePendingSession(
                            durationMinutes: dur, tasks: tasks),
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Start New Session',
                          style: TextStyle(fontFamily: 'PlusJakartaSans',
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                  ),

                // ── saved sessions (parent) — always visible, independent of
                // whether a session is currently active, so "where did my
                // saved session go" isn't a question: it lives here permanently
                // until explicitly deleted from this list (deleting only
                // removes it from here, not from that day's session history).
                if (widget.role == 'parent')
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _savedSessions.orderBy('createdAt', descending: true).snapshots(),
                    builder: (ctx, savedSnap) {
                      final saved = savedSnap.data?.docs ?? [];
                      if (saved.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Saved Sessions',
                                style: TextStyle(fontFamily: 'PlusJakartaSans',
                                    fontWeight: FontWeight.w600, fontSize: 13,
                                    color: _textMid, letterSpacing: 0.5)),
                            const SizedBox(height: 12),
                            ...saved.map((d) => _SavedSessionRow(
                                  data: d.data(),
                                  enabled: currentDoc == null,
                                  onRun: () => _runSavedSession(d.data()),
                                  onDelete: () => _deleteSavedSession(d.id),
                                )),
                          ],
                        ),
                      );
                    },
                  ),

                // ── past sessions ─────────────────────────────────────────
                if (pastDocs.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  const Text('Earlier Today',
                      style: TextStyle(fontFamily: 'PlusJakartaSans',
                          fontWeight: FontWeight.w600, fontSize: 13,
                          color: _textMid, letterSpacing: 0.5)),
                  const SizedBox(height: 12),
                  ...pastDocs.map((d) => _PastCard(doc: d)),
                ],

                if (snap.connectionState == ConnectionState.waiting && docs.isEmpty)
                  const Center(
                    child: Padding(padding: EdgeInsets.all(48),
                      child: CircularProgressIndicator(color: _purple, strokeWidth: 2)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── override card: different UI for parent vs child ────────────────────────
  Widget _buildOverrideCard(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final overrideStatus =
        (doc.data()['overrideRequest'] as Map<String, dynamic>?)?['status'] as String?
        ?? 'pending';

    if (widget.role == 'parent') {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.orange.shade200, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 22),
              const SizedBox(width: 8),
              const Expanded(child: Text('Child Requesting Early End',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w700,
                      fontSize: 15, color: _textDark))),
            ]),
            const SizedBox(height: 8),
            const Text('Your child wants to stop the session early.\nApprove or deny the request.',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: _border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: () => _respondOverride(doc.id, false),
                  child: const Text('Deny', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      color: _textMid, fontWeight: FontWeight.w500)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green, foregroundColor: Colors.white, elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: () => _respondOverride(doc.id, true),
                  child: const Text('Approve End', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ],
        ),
      );
    }

    // Child view: waiting for response
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.orange.shade200, width: 1.5),
      ),
      child: Column(children: [
        const Icon(Icons.hourglass_top_rounded, size: 48, color: Colors.orange),
        const SizedBox(height: 14),
        const Text('Waiting for Parent',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                fontSize: 16, color: _textDark)),
        const SizedBox(height: 6),
        Text(overrideStatus == 'denied'
            ? 'Your parent said no. Get back to finishing your tasks!'
            : 'Your request to end the session early\nhas been sent to your parent.',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13,
                color: overrideStatus == 'denied' ? Colors.red.shade600 : _textMid)),
      ]),
    );
  }

  void _showStartedPopup(BuildContext ctx, Map<String, dynamic> data) {
    final dur     = data['durationMinutes'] as int? ?? 0;
    // Reopening KTB mid-session re-triggers this popup (the "already shown"
    // tracker is per-widget-instance and resets on a fresh app launch), so it
    // must show the actual remaining time from endTime, not the session's
    // original total duration — otherwise a reopen at 26 minutes left still
    // announces "30 minutes" as if the session just started.
    final endTime = (data['endTime'] as Timestamp?)?.toDate();
    final remaining = endTime != null
        ? endTime.difference(DateTime.now()).inMinutes.clamp(0, dur)
        : dur;
    final isFreshStart = remaining >= dur;
    final allowed = (data['allowedApps'] as List<dynamic>? ?? [])
        .map((a) => (a as Map)['appName'] as String? ?? '').where((s) => s.isNotEmpty).toList();
    final blocked = (data['blockedApps'] as List<dynamic>? ?? [])
        .map((a) => (a as Map)['appName'] as String? ?? '').where((s) => s.isNotEmpty).toList();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Row(children: [
          const Icon(Icons.play_circle_fill_rounded, color: _green, size: 28),
          const SizedBox(width: 10),
          Text(isFreshStart ? 'Session Started!' : 'Session In Progress',
              style: const TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w700, color: _textDark, fontSize: 18)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('You have $remaining minutes of screen time left.',
              style: const TextStyle(fontFamily: 'PlusJakartaSans', color: _textMid, fontSize: 14)),
          if (allowed.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('You can use:',
                style: TextStyle(fontFamily: 'PlusJakartaSans',
                    fontWeight: FontWeight.w600, color: _textDark, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: allowed.take(8).map((nm) => _chip(nm, _green, const Color(0xFFE8F5E9))).toList()),
          ],
          if (blocked.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('These apps are locked:',
                style: TextStyle(fontFamily: 'PlusJakartaSans',
                    fontWeight: FontWeight.w600, color: _textDark, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: blocked.take(6).map((nm) => _chip(nm, Colors.red.shade400, const Color(0xFFFFEBEE))).toList()),
          ],
        ]),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(_),
            child: const Text('Got it!', style: TextStyle(fontFamily: 'PlusJakartaSans',
                fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color fg, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: fg)),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Step-1+2 creator dialog (parent side)
// ═══════════════════════════════════════════════════════════════════════════════
class _SessionCreatorDialog extends StatefulWidget {
  final Future<String> Function(int durationMinutes, List<_STask> tasks) onPendingCreated;
  const _SessionCreatorDialog({required this.onPendingCreated});

  @override
  State<_SessionCreatorDialog> createState() => _SessionCreatorDialogState();
}

// Splits into separate lines when both hours and minutes are present
// (e.g. 75 -> ['1h', '15m']) so the label stacks vertically instead of
// widening the cell — keeps every tick mark the same compact footprint.
List<String> _fmtDurationLines(int m) {
  if (m < 60) return ['${m}m'];
  final h = m ~/ 60, r = m % 60;
  return r == 0 ? ['${h}h'] : ['${h}h', '${r}m'];
}

class _SessionCreatorDialogState extends State<_SessionCreatorDialog> {
  int _duration = 30;
  final List<_STask> _tasks = [];
  final _ctrl  = TextEditingController();
  final _focus = FocusNode();
  bool _saving = false;

  @override
  void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  void _addTask() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    setState(() { _tasks.add(_STask(text: t)); _ctrl.clear(); });
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      await widget.onPendingCreated(_duration, _tasks);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskTotalMins = _tasks.fold(0, (s, t) => s + t.durationMinutes);
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Expanded(child: Text('Plan a Session',
                style: TextStyle(fontFamily: 'InstrumentSerif', fontSize: 26, color: _textDark))),
            IconButton(icon: const Icon(Icons.close, color: _textMid),
                onPressed: () => Navigator.pop(context)),
          ]),
          const SizedBox(height: 2),
          const Text("Set duration and tasks. Then hand the child's device to select apps.",
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: _textMid)),
          const SizedBox(height: 22),

          // Duration
          const Text('Duration',
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                  fontSize: 14, color: _textDark)),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: _purple,
              inactiveTrackColor: _purpleLight,
              thumbColor: _purple,
              overlayColor: _purple.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: _duration.toDouble(),
              min: 15,
              max: 120,
              divisions: 7,
              onChanged: (v) => setState(() => _duration = v.round()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [15, 30, 45, 60, 75, 90, 105, 120].map((m) {
                final on = _duration == m;
                final style = TextStyle(fontFamily: 'PlusJakartaSans',
                    fontSize: 9.5, height: 1.1,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    color: on ? _purple : _textMid);
                return Expanded(
                  child: SizedBox(
                    height: 26,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _fmtDurationLines(m)
                          .map((l) => Text(l, textAlign: TextAlign.center, style: style))
                          .toList(),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 14),

          // Tasks header
          Row(children: [
            const Expanded(child: Text('Tasks',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                    fontSize: 14, color: _textDark))),
            Text('$taskTotalMins / $_duration min',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                    color: taskTotalMins > _duration ? Colors.red : _textMid)),
          ]),
          const SizedBox(height: 10),

          if (_tasks.isNotEmpty)
            ..._tasks.asMap().entries.map((e) {
              final i = e.key; final t = e.value;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: _purpleLight, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(child: Text(t.text,
                      style: const TextStyle(fontFamily: 'PlusJakartaSans',
                          fontSize: 14, color: _textDark))),
                  GestureDetector(onTap: () => setState(() { if (t.durationMinutes > 5) t.durationMinutes -= 5; }),
                      child: const Icon(Icons.remove_circle_outline, color: _purple, size: 20)),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text('${t.durationMinutes}m',
                        style: const TextStyle(fontFamily: 'PlusJakartaSans',
                            fontWeight: FontWeight.w600, color: _purple, fontSize: 13))),
                  GestureDetector(onTap: () => setState(() => t.durationMinutes += 5),
                      child: const Icon(Icons.add_circle_outline, color: _purple, size: 20)),
                  const SizedBox(width: 6),
                  GestureDetector(onTap: () => setState(() => _tasks.removeAt(i)),
                      child: const Icon(Icons.close, color: _textMid, size: 18)),
                ]),
              );
            }),

          // Add-task row
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl, focusNode: _focus,
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14, color: _textDark),
                decoration: InputDecoration(
                  hintText: 'Add a task…',
                  hintStyle: const TextStyle(color: _textMid, fontFamily: 'PlusJakartaSans'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _purple, width: 1.5)),
                  filled: true, fillColor: Colors.white,
                ),
                onSubmitted: (_) => _addTask(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _addTask,
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: _purple, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.add, color: Colors.white),
              ),
            ),
          ]),
          const SizedBox(height: 28),

          // Actions
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel', style: TextStyle(fontFamily: 'PlusJakartaSans',
                    color: _textMid, fontWeight: FontWeight.w500)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple, foregroundColor: Colors.white, elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Next: Select Apps',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                            fontSize: 14)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Child: app picker card (shown when status == 'pending')
// ═══════════════════════════════════════════════════════════════════════════════
class _ChildAppPickerCard extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final String familyId;
  final String? childIosVendorId;
  final Future<void> Function(List<_AppEntry>) onConfirm;
  // iOS-only: called after native FamilyActivityPicker confirms (no app list).
  final Future<void> Function()? onConfirmIos;

  const _ChildAppPickerCard({
    required this.doc,
    required this.familyId,
    required this.childIosVendorId,
    required this.onConfirm,
    this.onConfirmIos,
  });

  @override
  State<_ChildAppPickerCard> createState() => _ChildAppPickerCardState();
}

class _ChildAppPickerCardState extends State<_ChildAppPickerCard> {
  // Android state
  List<_AppEntry> _apps = [];
  bool _loading = true;

  // Shared
  bool _saving = false;

  // iOS state — native FamilyActivityPicker
  bool _iosPickerLoading   = false;
  bool _iosPickerConfirmed = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      _loading = false; // no Firestore load needed; native picker handles everything
    } else {
      _loadAndroidApps();
    }
  }

  Future<void> _loadAndroidApps() async {
    final installed = await UsageStatsService.getInstalledApps();
    final result = installed.map((a) => _AppEntry(
      packageName:   a.packageName,
      appName:       a.appName,
      categoryLabel: a.categoryLabel,
      allowed:       true,
    )).toList();
    if (mounted) setState(() { _apps = result; _loading = false; });
  }

  Future<void> _launchIosPicker() async {
    setState(() { _iosPickerLoading = true; _iosPickerConfirmed = false; });
    // Family Controls authorization is required for the picker's selection to
    // actually enforce ManagedSettings shields — request it explicitly rather
    // than relying on the (currently unreachable) hidden "Grant Access" button.
    if (!await UsageStatsService.hasPermission()) {
      await UsageStatsService.requestPermission();
    }
    final confirmed = await UsageStatsService.showFamilyActivityPicker();
    if (mounted) setState(() { _iosPickerLoading = false; _iosPickerConfirmed = confirmed; });
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      if (Platform.isIOS) {
        await widget.onConfirmIos?.call();
      } else {
        await widget.onConfirm(_apps);
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dur   = widget.doc.data()['durationMinutes'] as int? ?? 0;
    final tasks = widget.doc.data()['tasks'] as List<dynamic>? ?? [];

    // ── iOS: native picker UI ────────────────────────────────────────────────
    if (Platform.isIOS) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(22),
          boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.10), blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10,
                decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            const Text('App Selection Needed',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                    fontSize: 12, color: Colors.orange, letterSpacing: 0.4)),
          ]),
          const SizedBox(height: 12),
          Text('Parent set up a ${dur}m session with ${tasks.length} task(s).',
              style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14, color: _textDark)),
          const SizedBox(height: 4),
          const Text('Choose which apps will be allowed during this session. Everything else will be blocked.',
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
          const SizedBox(height: 24),

          // Open native picker
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple, foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: _iosPickerLoading ? null : _launchIosPicker,
              icon: _iosPickerLoading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.apps_rounded, size: 20),
              label: Text(
                _iosPickerLoading
                    ? 'Opening Picker…'
                    : (_iosPickerConfirmed ? 'Re-select Apps' : 'Choose Allowed Apps'),
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600)),
            ),
          ),

          // Confirm button — only visible after picker confirmed a selection
          if (_iosPickerConfirmed) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.check_circle_rounded, color: _green, size: 18),
              const SizedBox(width: 6),
              const Text('Apps selected! Tap Confirm to continue.',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _green)),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green, foregroundColor: Colors.white, elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: _saving ? null : _confirm,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.check_rounded, size: 20),
                label: Text(_saving ? 'Confirming…' : 'Confirm App Selection',
                    style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
      );
    }

    // ── Android: installed-app list with toggles ──────────────────────────────
    return Container(
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.10), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 10, height: 10,
                  decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text('App Selection Needed',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                      fontSize: 12, color: Colors.orange, letterSpacing: 0.4)),
            ]),
            const SizedBox(height: 10),
            Text('Parent has set up a ${dur}m session with ${tasks.length} task(s).',
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14, color: _textDark)),
            const SizedBox(height: 4),
            const Text('Select which apps the child can use during this session:',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
            const SizedBox(height: 14),
            if (!_loading)
              Row(children: [
                Text('${_apps.where((a) => a.allowed).length} of ${_apps.length} allowed',
                    style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: _textMid)),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() { for (final a in _apps) a.allowed = true; }),
                  child: const Text('Allow all', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontSize: 12, color: _purple, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => setState(() { for (final a in _apps) a.allowed = false; }),
                  child: const Text('Block all', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontSize: 12, color: Colors.red, fontWeight: FontWeight.w500)),
                ),
              ]),
          ]),
        ),
        const SizedBox(height: 12),

        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator(color: _purple, strokeWidth: 2)),
          )
        else if (_apps.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text('No apps found. Ensure Usage Access permission is granted.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.38),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: _apps.length,
              itemBuilder: (_, i) {
                final app = _apps[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: app.allowed ? Colors.white : const Color(0xFFFFF5F5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: app.allowed ? _border : Colors.red.shade100),
                  ),
                  child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    leading: Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: app.allowed ? _purpleLight : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.apps_rounded, size: 18,
                          color: app.allowed ? _purple : Colors.red.shade300),
                    ),
                    title: Text(app.appName, style: TextStyle(fontFamily: 'PlusJakartaSans',
                        fontSize: 13, fontWeight: FontWeight.w500,
                        color: app.allowed ? _textDark : Colors.red.shade700)),
                    subtitle: Text(app.categoryLabel,
                        style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                    trailing: Switch.adaptive(
                      value: app.allowed,
                      onChanged: (v) => setState(() => app.allowed = v),
                      activeColor: _purple,
                    ),
                  ),
                );
              },
            ),
          ),

        // Confirm button
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _green, foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: _saving ? null : _confirm,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.check_rounded, size: 20),
              label: Text(_saving ? 'Confirming…' : 'Confirm App Selection',
                  style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Parent waiting card (status == 'pending', seen from parent device)
// ═══════════════════════════════════════════════════════════════════════════════
class _ParentWaitingCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onCancel;
  const _ParentWaitingCard({required this.doc, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final dur   = doc.data()['durationMinutes'] as int? ?? 0;
    final tasks = doc.data()['tasks'] as List<dynamic>? ?? [];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.orange.shade200, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          SizedBox(width: 8, height: 8,
              child: CircularProgressIndicator(color: Colors.orange, strokeWidth: 2)),
          SizedBox(width: 10),
          const Text("Waiting for Child's Device",
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                  fontSize: 13, color: Colors.orange)),
        ]),
        const SizedBox(height: 12),
        Text('$dur-minute session with ${tasks.length} task(s) is ready.',
            style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14, color: _textDark)),
        const SizedBox(height: 6),
        const Text('Go to the child\'s device → open KTB → Session tab → select allowed apps.\nThen come back here to start.',
            style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
        const SizedBox(height: 16),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _border),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          onPressed: onCancel,
          child: const Text('Cancel Session', style: TextStyle(fontFamily: 'PlusJakartaSans',
              color: _textMid, fontWeight: FontWeight.w500, fontSize: 13)),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Parent: apps selected, ready to start
// ═══════════════════════════════════════════════════════════════════════════════
class _AppsReadyCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  const _AppsReadyCard({required this.doc, required this.onStart, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final data          = doc.data();
    final dur           = data['durationMinutes']   as int?  ?? 0;
    final allowed       = (data['allowedApps']      as List<dynamic>? ?? []);
    final blocked       = (data['blockedApps']      as List<dynamic>? ?? []);
    final iosNative     = data['iosNativeSelection'] as bool? ?? false;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _green, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.check_circle_rounded, color: _green, size: 22),
          SizedBox(width: 8),
          Text('Apps Selected — Ready to Start!',
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w700,
                  fontSize: 14, color: _green)),
        ]),
        const SizedBox(height: 10),
        Text(
          iosNative
              ? '$dur-minute session · Apps selected via iOS Screen Time'
              : '$dur-minute session · ${allowed.length} apps allowed · ${blocked.length} blocked',
          style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _green, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow_rounded, size: 22),
            label: const Text('Start Session Now',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600, fontSize: 15)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: onCancel,
            child: const Text('Cancel', style: TextStyle(fontFamily: 'PlusJakartaSans',
                color: _textMid, fontSize: 13)),
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Child waiting card
// ═══════════════════════════════════════════════════════════════════════════════
class _ChildWaitingCard extends StatelessWidget {
  final String message;
  const _ChildWaitingCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _border),
      ),
      child: Column(children: [
        const CircularProgressIndicator(color: _purple, strokeWidth: 2),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14, color: _textMid)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Active session card with live countdown
// ═══════════════════════════════════════════════════════════════════════════════
class _ActiveCard extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final String role;
  final String familyId;
  final VoidCallback onEnd;
  final VoidCallback onRequestOverride;
  final VoidCallback? onSaveTemplate;
  const _ActiveCard({required this.doc, required this.role,
      required this.familyId,
      required this.onEnd, required this.onRequestOverride,
      this.onSaveTemplate});

  @override
  State<_ActiveCard> createState() => _ActiveCardState();
}

class _ActiveCardState extends State<_ActiveCard> {
  Timer? _timer;
  Duration _remaining = Duration.zero;
  bool _expanded = false;
  // Guards against calling onEnd() more than once from this device when the
  // countdown naturally reaches zero (as opposed to the parent ending early).
  bool _autoEndTriggered = false;

  @override
  void initState() { super.initState(); _tick(); _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick()); }

  @override
  void didUpdateWidget(_ActiveCard old) { super.didUpdateWidget(old); _tick(); }

  void _tick() {
    final end = (widget.doc.data()['endTime'] as Timestamp).toDate();
    final rem = end.difference(DateTime.now());
    final expired = rem.isNegative;
    if (mounted) setState(() => _remaining = expired ? Duration.zero : rem);
    // Time's up — automatically mark the session completed so it moves to
    // the past-sessions list instead of staying "active" indefinitely.
    if (expired && !_autoEndTriggered) {
      _autoEndTriggered = true;
      widget.onEnd();
    }
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  String get _countdown {
    if (_remaining == Duration.zero) return '00:00';
    final h = _remaining.inHours;
    final m = _remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final data     = widget.doc.data();
    final dur      = (data['durationMinutes'] as int?) ?? 0;
    final start    = (data['startTime'] as Timestamp).toDate();
    final end      = (data['endTime']   as Timestamp).toDate();
    final elapsed  = DateTime.now().difference(start).inSeconds.clamp(0, dur * 60);
    final progress = dur > 0 ? (elapsed / (dur * 60)).clamp(0.0, 1.0) : 0.0;
    final expired  = _remaining == Duration.zero;
    final accent   = expired ? Colors.orange : _purple;
    final tasks    = data['tasks']       as List<dynamic>? ?? [];
    final allowed  = data['allowedApps'] as List<dynamic>? ?? [];
    final blocked  = data['blockedApps'] as List<dynamic>? ?? [];
    final iosNative = data['iosNativeSelection'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: _purple.withValues(alpha: 0.10), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Status
            Row(children: [
              Container(width: 9, height: 9,
                  decoration: BoxDecoration(color: expired ? Colors.orange : _green, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(expired ? "Time's Up" : 'Active Session',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                      fontSize: 12, color: expired ? Colors.orange : _green, letterSpacing: 0.4)),
              const Spacer(),
              Text('${TimeOfDay.fromDateTime(start).format(context)} – ${TimeOfDay.fromDateTime(end).format(context)}',
                  style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
              if (widget.onSaveTemplate != null)
                IconButton(
                  onPressed: widget.onSaveTemplate,
                  tooltip: 'Save as reusable session',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.star_border_rounded, color: _purple, size: 18),
                ),
              const SizedBox(width: 6),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: _textMid, size: 18),
            ]),
            const SizedBox(height: 16),

            // Countdown
            Center(child: Text(_countdown, style: TextStyle(fontFamily: 'PlusJakartaSans',
                fontWeight: FontWeight.w800, fontSize: 58,
                color: expired ? Colors.orange : _textDark, letterSpacing: -2))),
            Center(child: Text(expired ? 'Session finished' : 'remaining',
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid))),
            const SizedBox(height: 18),

            // Progress bar
            ClipRRect(borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: progress, minHeight: 10,
                backgroundColor: _purpleLight, valueColor: AlwaysStoppedAnimation(accent))),
            const SizedBox(height: 18),

            // Tasks
            if (tasks.isNotEmpty) ...[
              const Text('Tasks', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w600, fontSize: 13, color: _textDark)),
              const SizedBox(height: 8),
              ...tasks.map((t) {
                final m = t as Map<String, dynamic>;
                final done = m['done'] as bool? ?? false;
                return Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
                  Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                      size: 16, color: done ? _green : _textMid),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${m['text']}', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontSize: 13, color: done ? _textMid : _textDark,
                      decoration: done ? TextDecoration.lineThrough : null))),
                  Text('${m['durationMinutes'] ?? 0}m',
                      style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                ]));
              }),
              const SizedBox(height: 12),
            ],

            // App summary — iOS sessions never populate allowedApps/blockedApps
            // in Firestore. Apple's FamilyActivityPicker/ApplicationToken never
            // exposes app names/icons to the main app process outside the
            // picker's own UI or a ShieldConfiguration extension (neither of
            // which can be used here), so there is no way to list the actual
            // apps — only acknowledge that a selection was made natively.
            if (iosNative) ...[
              const Text('APP ACCESS', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w600, fontSize: 11, color: _textMid, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              const Text(
                  "Apps were selected via iOS Screen Time. Apple doesn't allow "
                  'app names to be shown outside the picker — everything not '
                  'selected is blocked for this session.',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: _textMid)),
              const SizedBox(height: 16),
            ] else if (allowed.isNotEmpty || blocked.isNotEmpty) ...[
              if (!_expanded)
                Row(children: [
                  if (allowed.isNotEmpty) Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Allowed (${allowed.length})', style: const TextStyle(fontFamily: 'PlusJakartaSans',
                        fontWeight: FontWeight.w600, fontSize: 12, color: _green)),
                    const SizedBox(height: 3),
                    Text(allowed.take(3).map((a) => (a as Map)['appName']).join(', ') + (allowed.length > 3 ? '…' : ''),
                        style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                  ])),
                  if (blocked.isNotEmpty) Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Blocked (${blocked.length})', style: TextStyle(fontFamily: 'PlusJakartaSans',
                        fontWeight: FontWeight.w600, fontSize: 12, color: Colors.red.shade400)),
                    const SizedBox(height: 3),
                    Text(blocked.take(3).map((a) => (a as Map)['appName']).join(', ') + (blocked.length > 3 ? '…' : ''),
                        style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                  ])),
                ])
              else ...[
                const Text('APP ACCESS', style: TextStyle(fontFamily: 'PlusJakartaSans',
                    fontWeight: FontWeight.w600, fontSize: 11, color: _textMid, letterSpacing: 0.8)),
                const SizedBox(height: 8),
                if (allowed.isNotEmpty)
                  _AppChips(label: 'Allowed', apps: allowed,
                      fg: _green, bg: const Color(0xFFE8F5E9)),
                if (blocked.isNotEmpty)
                  _AppChips(label: 'Blocked', apps: blocked,
                      fg: Colors.red.shade400, bg: const Color(0xFFFFEBEE)),
              ],
              const SizedBox(height: 16),
            ],
          ]),
        ),

        // Reminders — moved here from the dashboard bar, which is now a pure
        // progress display that just navigates to this tab. There's no more
        // daily limit to set; each session's own duration is the limit.
        SizedBox(width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _purple),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => _showScreenTimeLimitDialog(
                context, widget.familyId, widget.role),
            child: const Text('Add Reminders', style: TextStyle(
                fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600, color: _purple)),
          )),
        const SizedBox(height: 10),

        // Action buttons
        if (widget.role == 'parent')
          SizedBox(width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: widget.onEnd,
              child: const Text('End Session Early', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w500, color: _textMid)),
            ))
        else
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.orange.shade200),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: widget.onRequestOverride,
              icon: const Icon(Icons.help_outline, size: 18, color: Colors.orange),
              label: const Text('Request Early End', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w500, color: Colors.orange)),
            )),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Empty state
// ═══════════════════════════════════════════════════════════════════════════════
class _EmptyCard extends StatelessWidget {
  final String role;
  const _EmptyCard({required this.role});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
    decoration: BoxDecoration(
      color: Colors.white, borderRadius: BorderRadius.circular(22),
      border: Border.all(color: _border),
    ),
    child: Column(children: [
      const Icon(Icons.hourglass_empty_rounded, size: 52, color: Color(0xFFB8B3D8)),
      const SizedBox(height: 14),
      Text(role == 'parent' ? 'No active session' : 'No session yet',
          style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
              fontSize: 16, color: _textDark)),
      const SizedBox(height: 6),
      Text(
        role == 'parent'
            ? 'Tap "Start New Session" to set tasks\nand allowed apps for your child'
            : 'Your parent will start a session\nwhen it\'s time',
        textAlign: TextAlign.center,
        style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Saved (repeatable) session row
// ═══════════════════════════════════════════════════════════════════════════════
class _SavedSessionRow extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool enabled;
  final VoidCallback onRun;
  final VoidCallback onDelete;
  const _SavedSessionRow({
    required this.data, required this.onRun, required this.onDelete, this.enabled = true,
  });

  void _showDetails(BuildContext context) {
    final name = data['name'] as String? ?? 'Session';
    final durationMinutes = data['durationMinutes'] as int? ?? 0;
    final tasks = data['tasks'] as List<dynamic>? ?? [];
    final allowed = data['allowedApps'] as List<dynamic>? ?? [];
    final blocked = data['blockedApps'] as List<dynamic>? ?? [];
    final iosNative = data['iosNativeSelection'] as bool? ?? false;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name, style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$durationMinutes minutes',
                  style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textMid)),
              const SizedBox(height: 16),
              if (tasks.isNotEmpty) ...[
                const Text('Tasks', style: TextStyle(fontFamily: 'PlusJakartaSans',
                    fontWeight: FontWeight.w600, fontSize: 13, color: _textDark)),
                const SizedBox(height: 6),
                ...tasks.map((t) {
                  final m = t as Map<String, dynamic>;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• ${m['text']} (${m['durationMinutes'] ?? 0}m)',
                        style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textDark)),
                  );
                }),
                const SizedBox(height: 14),
              ],
              if (iosNative) ...[
                const Text('App access', style: TextStyle(fontFamily: 'PlusJakartaSans',
                    fontWeight: FontWeight.w600, fontSize: 13, color: _textDark)),
                const SizedBox(height: 6),
                const Text('Apps were selected via the iOS Screen Time picker on the '
                    'child\'s device — Apple doesn\'t expose those app names here.',
                    style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: _textMid)),
              ] else ...[
                if (allowed.isNotEmpty) ...[
                  const Text('Allowed apps', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontWeight: FontWeight.w600, fontSize: 13, color: _green)),
                  const SizedBox(height: 6),
                  Text(allowed.map((a) => (a as Map)['appName'] ?? '').join(', '),
                      style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textDark)),
                  const SizedBox(height: 14),
                ],
                if (blocked.isNotEmpty) ...[
                  const Text('Blocked apps', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontWeight: FontWeight.w600, fontSize: 13, color: Colors.redAccent)),
                  const SizedBox(height: 6),
                  Text(blocked.map((a) => (a as Map)['appName'] ?? '').join(', '),
                      style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 13, color: _textDark)),
                ],
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = data['name'] as String? ?? 'Session';
    final durationMinutes = data['durationMinutes'] as int? ?? 0;
    final taskCount = (data['tasks'] as List<dynamic>? ?? []).length;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showDetails(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Icon(Icons.star_rounded, color: _purple, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontFamily: 'PlusJakartaSans',
                      fontWeight: FontWeight.w600, fontSize: 14, color: _textDark)),
                  Text('$durationMinutes min · ${taskCount == 1 ? '1 task' : '$taskCount tasks'}',
                      style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                ]),
              ),
              IconButton(
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline_rounded, color: _textMid, size: 20),
              ),
              TextButton(
                onPressed: enabled
                    ? onRun
                    : () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('End the current session before starting a saved one'),
                        duration: Duration(seconds: 3),
                        behavior: SnackBarBehavior.floating,
                      )),
                style: TextButton.styleFrom(
                  backgroundColor: enabled ? _purpleLight : const Color(0xFFF0F0F0),
                  foregroundColor: enabled ? _purple : _textMid,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Run', style: TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Past session card (expandable)
// ═══════════════════════════════════════════════════════════════════════════════
class _PastCard extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _PastCard({required this.doc});

  @override
  State<_PastCard> createState() => _PastCardState();
}

class _PastCardState extends State<_PastCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final data     = widget.doc.data();
    final status   = data['status'] as String? ?? 'completed';
    final start    = (data['startTime'] as Timestamp?)?.toDate();
    final end      = (data['endTime']   as Timestamp?)?.toDate();
    final dur      = start != null && end != null ? end.difference(start).inMinutes : 0;
    final label    = dur < 60 ? '${dur}m' : '${dur ~/ 60}h${dur % 60 > 0 ? ' ${dur % 60}m' : ''}';
    final tasks    = data['tasks']       as List<dynamic>? ?? [];
    final allowed  = data['allowedApps'] as List<dynamic>? ?? [];
    final blocked  = data['blockedApps'] as List<dynamic>? ?? [];
    final isOverride = status == 'completed_override';

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: isOverride ? Colors.orange.shade50 : _purpleLight,
                borderRadius: BorderRadius.circular(10)),
              child: Icon(isOverride ? Icons.stop_rounded : Icons.check_rounded,
                  color: isOverride ? Colors.orange : _purple, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                start != null && end != null
                    ? '${TimeOfDay.fromDateTime(start).format(context)} – ${TimeOfDay.fromDateTime(end).format(context)}'
                    : 'Session',
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontWeight: FontWeight.w600,
                    fontSize: 14, color: _textDark)),
              Text('$label${isOverride ? ' · Ended early' : ''}',
                  style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                      color: isOverride ? Colors.orange : _textMid)),
            ])),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: _textMid, size: 20),
          ]),

          if (_expanded) ...[
            const SizedBox(height: 12),
            const Divider(color: _border, height: 1),
            const SizedBox(height: 12),

            if (tasks.isNotEmpty) ...[
              const Text('TASKS', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w600, fontSize: 11, color: _textMid, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              ...tasks.map((t) {
                final m = t as Map<String, dynamic>;
                final done = m['done'] as bool? ?? false;
                return Padding(padding: const EdgeInsets.only(bottom: 5), child: Row(children: [
                  Icon(done ? Icons.check_circle_rounded : Icons.cancel_outlined,
                      size: 14, color: done ? _green : Colors.red.shade300),
                  const SizedBox(width: 7),
                  Expanded(child: Text('${m['text']}', style: TextStyle(fontFamily: 'PlusJakartaSans',
                      fontSize: 12, color: _textDark,
                      decoration: done ? TextDecoration.lineThrough : null))),
                  Text('${m['durationMinutes'] ?? 0}m',
                      style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: _textMid)),
                ]));
              }),
              const SizedBox(height: 10),
            ],

            if (allowed.isNotEmpty || blocked.isNotEmpty) ...[
              const Text('APP ACCESS', style: TextStyle(fontFamily: 'PlusJakartaSans',
                  fontWeight: FontWeight.w600, fontSize: 11, color: _textMid, letterSpacing: 0.8)),
              const SizedBox(height: 8),
              if (allowed.isNotEmpty)
                _AppChips(label: 'Allowed', apps: allowed,
                    fg: _green, bg: const Color(0xFFE8F5E9)),
              if (blocked.isNotEmpty)
                _AppChips(label: 'Blocked', apps: blocked,
                    fg: Colors.red.shade400, bg: const Color(0xFFFFEBEE)),
            ],
          ],
        ]),
      ),
    );
  }
}

class _AppChips extends StatelessWidget {
  final String label;
  final List<dynamic> apps;
  final Color fg, bg;
  const _AppChips({required this.label, required this.apps, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontFamily: 'PlusJakartaSans',
          fontSize: 11, color: fg, fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4,
        children: apps.map((a) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
          child: Text((a as Map)['appName'] as String? ?? '',
              style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 11, color: fg)),
        )).toList()),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Screen Time Limit dialog — with reminder scheduler
// Moved here from the dashboard (which is now a pure progress display) so
// setting the limit and reminders lives alongside the active session and its
// app list.
// ═══════════════════════════════════════════════════════════════════════════════

Future<void> _showScreenTimeLimitDialog(
  BuildContext context,
  String familyId,
  String role,
) async {
  final settingsRef = FirebaseFirestore.instance
      .collection('families').doc(familyId)
      .collection('settings').doc('screenTime');
  final now = DateTime.now();
  final todayKey =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  final settingsDoc = await settingsRef.get();
  final settingsData = settingsDoc.data();
  // screenTimeLimitMinutes is auto-set to the active session's own duration
  // when the session starts (see _writePendingSession/_startSession) — it's
  // read-only here, never edited from this dialog.
  final limitMinutes = settingsData?['screenTimeLimitMinutes'] as int? ?? 0;
  final currentReminders = (settingsData?['reminderMinutes'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList() ??
      <int>[];

  final dayDoc = await FirebaseFirestore.instance
      .collection('families').doc(familyId)
      .collection('dashboard_days').doc(todayKey)
      .get();
  final usedMinutes = dayDoc.data()?['screenTimeUsedMinutes'] as int? ?? 0;

  if (!context.mounted) return;

  showDialog(
    context: context,
    builder: (_) => _ScreenTimeLimitDialog(
      limitMinutes: limitMinutes,
      initialReminders: currentReminders,
      usedMinutes: usedMinutes,
      onSave: (reminders) async {
        await settingsRef.set(
            {'reminderMinutes': reminders}, SetOptions(merge: true));
        await _scheduleScreenTimeReminders(
            familyId, role, todayKey, limitMinutes, usedMinutes, reminders);
      },
    ),
  );
}

Future<void> _scheduleScreenTimeReminders(
  String familyId,
  String role,
  String todayKey,
  int limitMins,
  int usedMinutes,
  List<int> reminders,
) async {
  await NotificationService.cancelAllReminders();
  for (int i = 0; i < reminders.length; i++) {
    final minsLeft = reminders[i];
    final minsUntilFire = limitMins - usedMinutes - minsLeft;
    if (minsUntilFire > 0) {
      await NotificationService.scheduleReminder(
        slotIndex: i,
        title: 'Screen time reminder',
        body: '$minsLeft minutes of screen time left today.',
        delay: Duration(minutes: minsUntilFire),
      );
      try {
        final fireAt = DateTime.now().add(Duration(minutes: minsUntilFire));
        await FirebaseFirestore.instance
            .collection('families').doc(familyId)
            .collection('notifications')
            .add({
          'title': 'Screen time reminder',
          'body': '$minsLeft minutes of screen time left today.',
          'type': 'screen_time_reminder',
          'targetRole': role,
          'dateKey': todayKey,
          'sentAt': Timestamp.fromDate(fireAt),
        });
      } catch (_) {}
    }
  }
}

class _ScreenTimeLimitDialog extends StatefulWidget {
  // Read-only — comes from the active session's own duration, not a
  // separately-configured daily cap. There is no more "daily limit" to edit;
  // each session sets its own time, so only reminders are configurable here.
  final int limitMinutes;
  final List<int> initialReminders;
  final int usedMinutes;
  final void Function(List<int> reminders) onSave;

  const _ScreenTimeLimitDialog({
    required this.limitMinutes,
    required this.initialReminders,
    required this.usedMinutes,
    required this.onSave,
  });

  @override
  State<_ScreenTimeLimitDialog> createState() => _ScreenTimeLimitDialogState();
}

class _ScreenTimeLimitDialogState extends State<_ScreenTimeLimitDialog> {
  late List<int> _reminders;
  double _pendingReminder = 10; // minutes before session end for new reminder

  @override
  void initState() {
    super.initState();
    _reminders = List.of(widget.initialReminders);
  }

  void _addReminder() {
    final v = _pendingReminder.round();
    if (!_reminders.contains(v) && _reminders.length < 5) {
      setState(() => _reminders.add(v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final minsLeft = (widget.limitMinutes - widget.usedMinutes).clamp(0, widget.limitMinutes);

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
              const Text('Add Reminders',
                style: TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: _textDark,
                )),
              const SizedBox(height: 4),
              Text('$minsLeft min left in this session',
                style: const TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                    color: _textMid)),

              const SizedBox(height: 22),
              const Divider(color: _border),
              const SizedBox(height: 14),

              // ── reminders section ─────────────────────────────────────────
              const Text('Remind me when time is running out',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 14,
                    fontWeight: FontWeight.w600, color: _textMid)),
              const SizedBox(height: 6),
              const Text('Add multiple alerts. Each fires X minutes before the session ends.',
                style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12,
                    color: _textMid)),
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
                            activeTrackColor: _purple,
                            inactiveTrackColor: _purpleLight,
                            thumbColor: _purple,
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
                        color: _reminders.length >= 5 ? _border : _purple,
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
                  children: _reminders.sortedAsc().map((r) => Chip(
                    label: Text('$r min',
                      style: const TextStyle(fontFamily: 'PlusJakartaSans',
                          fontSize: 13, fontWeight: FontWeight.w600)),
                    backgroundColor: _purpleLight,
                    side: BorderSide.none,
                    deleteIcon: const Icon(Icons.close, size: 14),
                    deleteIconColor: _textMid,
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
                      style: TextStyle(fontFamily: 'PlusJakartaSans', color: _textMid)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      widget.onSave(_reminders);
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _purple,
                      foregroundColor: Colors.white,
                      elevation: 0,
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

extension _SortedReminderList on List<int> {
  List<int> sortedAsc() => List.of(this)..sort();
}
