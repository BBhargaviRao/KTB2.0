import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ktb2/features/dashboard/dashboard_screen.dart';

const String kSavedFamilyCodeKey = 'ktb_saved_family_code';
const String kSavedPinKey        = 'ktb_saved_pin';

// Called from DashboardScreen (already reached, not the login screen) so a
// hang or slow resolution in SharedPreferences can never strand the user
// before SessionTab mounts — that previously silently blocked the Android
// blocking service from starting for an already-active session. This is a
// convenience feature only, so the whole body is defensive.
Future<void> maybePromptToSaveLogin(
  BuildContext context, {
  required String familyCode,
  required String pin,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final alreadySaved = prefs.getString(kSavedFamilyCodeKey) == familyCode &&
        prefs.getString(kSavedPinKey) == pin;
    if (alreadySaved || !context.mounted) return;

    // Auto-dismiss after a few seconds so an unanswered dialog can't block.
    Timer? autoClose;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        autoClose = Timer(const Duration(seconds: 6), () {
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop(false);
        });
        return AlertDialog(
          title: const Text('Save login?'),
          content: const Text(
            'Save your Family Code and PIN on this device so you can skip '
            'typing them next time — just tap Continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    autoClose?.cancel();

    if (shouldSave == true) {
      await prefs.setString(kSavedFamilyCodeKey, familyCode);
      await prefs.setString(kSavedPinKey, pin);
    }
  } catch (e) {
    print('KTB: maybePromptToSaveLogin failed (non-fatal): $e');
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return MediaQuery(
      data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFEFE9FF),
                Color(0xFFF4D7C8),
                Color(0xFFBFA9FF),
                Color(0xFFF0D4C7),
              ],
              stops: [0.0, 0.38, 0.75, 1.0],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    SizedBox(height: 40),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'KidTechBalance',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'InstrumentSerif',
                          fontSize: 62,
                          fontWeight: FontWeight.w400,
                          color: Colors.black,
                          height: 0.95,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    SizedBox(height: 48),
                    _FamilyCodeCard(),
                    SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FamilyCodeCard extends StatefulWidget {
  const _FamilyCodeCard();

  @override
  State<_FamilyCodeCard> createState() => _FamilyCodeCardState();
}

class _FamilyCodeCardState extends State<_FamilyCodeCard> {
  static const double _designW = 296;
  static const double _designH = 430;

  final _familyCodeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  bool _pinHidden = true;

  @override
  void initState() {
    super.initState();
    _loadSavedLogin();
  }

  Future<void> _loadSavedLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString(kSavedFamilyCodeKey);
      final savedPin  = prefs.getString(kSavedPinKey);
      if (savedCode == null || savedPin == null || !mounted) return;
      setState(() {
        _familyCodeCtrl.text = savedCode;
        _pinCtrl.text = savedPin;
      });
    } catch (e) {
      print('KTB: _loadSavedLogin failed (non-fatal): $e');
    }
  }

  @override
  void dispose() {
    _familyCodeCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _lookupAccount({
    required String familyCode,
    required String pin,
  }) async {
    final db = FirebaseFirestore.instance;

    final famSnap = await db
        .collection('families')
        .where('familyCode', isEqualTo: familyCode)
        .limit(1)
        .get();

    if (famSnap.docs.isEmpty) return null;

    final familyDoc = famSnap.docs.first;

    final acctSnap = await familyDoc.reference
        .collection('accounts')
        .where('pin', isEqualTo: pin)
        .limit(1)
        .get();

    if (acctSnap.docs.isEmpty) return null;

    final accountDoc = acctSnap.docs.first;
    final data = accountDoc.data();

    return {
      'familyId': familyDoc.id,
      'accountId': accountDoc.id,
      'role': data['role'],
      'displayName': data['displayName'],
    };
  }

  Future<void> _linkDeviceToLoggedInAccount({
    required String familyId,
    required String accountId,
    required String role,
    required String displayName,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      print('No Firebase auth UID found. Device linking skipped.');
      return;
    }

    String? fcmToken;
    String? admToken;
    String? tokenType;
    String platformName = 'unknown';

    if (Platform.isAndroid) {
      platformName = 'android';

      try {
        const admChannel = MethodChannel('ktb2/adm');
        final possibleAdmToken =
            await admChannel.invokeMethod<String>('getAdmRegistrationId');

        if (possibleAdmToken != null && possibleAdmToken.isNotEmpty) {
          admToken = possibleAdmToken;
          tokenType = 'adm';
          print('ADM TOKEN FROM FLUTTER: $admToken');
        } else {
          fcmToken = await FirebaseMessaging.instance.getToken();
          tokenType = 'fcm';
          print('FCM TOKEN FROM HOME SCREEN: $fcmToken');
        }
      } catch (e) {
        print('ADM fetch failed, falling back to FCM: $e');
        try {
          fcmToken = await FirebaseMessaging.instance.getToken();
          tokenType = 'fcm';
          print('FCM TOKEN FROM HOME SCREEN: $fcmToken');
        } catch (e2) {
          print('FCM token fetch also failed: $e2');
        }
      }
    } else if (Platform.isIOS) {
      platformName = 'ios';

      try {
        const admChannel = MethodChannel('ktb2/adm');
        final possibleAdmToken =
            await admChannel.invokeMethod<String>('getAdmRegistrationId');

        if (possibleAdmToken != null && possibleAdmToken.isNotEmpty) {
          admToken = possibleAdmToken;
          tokenType = 'adm';
          print('ADM TOKEN FROM FLUTTER: $admToken');
        } else {
          fcmToken = await FirebaseMessaging.instance.getToken();
          tokenType = 'fcm';
          print('FCM TOKEN FROM HOME SCREEN: $fcmToken');
        }
      } catch (e) {
        // ADM channel not available on iOS — fall back to FCM
        try {
          fcmToken = await FirebaseMessaging.instance.getToken();
          tokenType = 'fcm';
          print('FCM TOKEN FROM HOME SCREEN (iOS fallback): $fcmToken');
        } catch (e2) {
          print('FCM token fetch also failed on iOS: $e2');
        }
      }
    }

    final data = <String, dynamic>{
      'uid': uid,
      'familyId': familyId,
      'accountId': accountId,
      'role': role,
      'displayName': displayName,
      'linkedAt': FieldValue.serverTimestamp(),
      'platform': platformName,
      'tokenType': tokenType,
    };

    if (fcmToken != null && fcmToken.isNotEmpty) {
      data['fcmToken'] = fcmToken;
    }

    if (admToken != null && admToken.isNotEmpty) {
      data['admRegistrationId'] = admToken;
    }

    await FirebaseFirestore.instance
        .collection('device_registrations')
        .doc(uid)
        .set(data, SetOptions(merge: true));

    // Remove any stale registrations for this account from previous installs
    // so the Cloud Function always finds the current valid token.
    try {
      final staleSnap = await FirebaseFirestore.instance
          .collection('device_registrations')
          .where('familyId', isEqualTo: familyId)
          .where('accountId', isEqualTo: accountId)
          .get();
      for (final doc in staleSnap.docs) {
        if (doc.id != uid) {
          await doc.reference.delete();
        }
      }
    } catch (e) {
      print('Stale registration cleanup failed (non-fatal): $e');
    }

    print('Device registration linked to family/account successfully.');
  }

  Future<void> _handleContinue() async {
    final familyCode = _familyCodeCtrl.text.trim();
    final pin = _pinCtrl.text.trim();

    if (familyCode.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter Family Code and PIN')),
      );
      return;
    }

    if (familyCode.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Family Code must be 6 characters')),
      );
      return;
    }

    if (pin.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be 4 digits')),
      );
      return;
    }

    try {
      final result = await _lookupAccount(
        familyCode: familyCode,
        pin: pin,
      );

      if (!mounted) return;

      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid Family Code or PIN')),
        );
        return;
      }

      final familyId = result['familyId'] as String;
      final accountId = result['accountId'] as String;
      final role = (result['role'] ?? '') as String;
      final name = (result['displayName'] ?? '') as String;

      await _linkDeviceToLoggedInAccount(
        familyId: familyId,
        accountId: accountId,
        role: role,
        displayName: name,
      );

      if (!mounted) return;

      if (!mounted) return;

      if (role == 'parent' || role == 'child') {
        // The save-login prompt must never gate reaching the Dashboard — a
        // hang or slow resolution in SharedPreferences on one device left
        // the user stuck on this screen indefinitely when it was awaited
        // here, with SessionTab never mounting and the Android blocking
        // service never starting for an already-active session. Pass the
        // credentials through and let DashboardScreen show the prompt on
        // its own, already-reached screen instead.
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(
              displayName: name.isEmpty ? (role == 'parent' ? 'Parent' : 'Child') : name,
              role: role,
              familyId: familyId,
              accountId: accountId,
              pendingSaveLoginFamilyCode: familyCode,
              pendingSaveLoginPin: pin,
            ),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account role is invalid')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Firebase error: ${e.code}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / _designW).clamp(0.0, 1.0);

        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: _designW,
            height: _designH,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    gradient: const LinearGradient(
                      begin: Alignment(0.85, -1.0),
                      end: Alignment(-0.85, 1.0),
                      colors: [
                        Color(0x4D6200FF),
                        Color(0x4DFF8C00),
                      ],
                      stops: [0.0295, 0.9743],
                    ),
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    child: Column(
                      children: [
                        const SizedBox(height: 50),
                        const Text(
                          'Family Code',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'InstrumentSerif',
                            fontSize: 32,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                            height: 22 / 32,
                            letterSpacing: -0.408,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _PillTextField(
                          controller: _familyCodeCtrl,
                          height: 64,
                          obscureText: false,
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(6),
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9]'),
                            ),
                            _UpperCaseTextFormatter(),
                          ],
                          showEye: false,
                        ),
                        const SizedBox(height: 36),
                        const Text(
                          'Pin',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'InstrumentSerif',
                            fontSize: 32,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                            height: 22 / 32,
                            letterSpacing: -0.408,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _PillTextField(
                          controller: _pinCtrl,
                          height: 64,
                          obscureText: _pinHidden,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(4),
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          showEye: true,
                          onToggleVisibility: () =>
                              setState(() => _pinHidden = !_pinHidden),
                          onSubmitted: (_) => _handleContinue(),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: 325,
                          height: 77,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(30),
                              onTap: _handleContinue,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(30),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.25),
                                      offset: const Offset(0, 5),
                                      blurRadius: 4,
                                      spreadRadius: 0,
                                    ),
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: const Text(
                                  'Continue',
                                  style: TextStyle(
                                    fontFamily: 'InstrumentSerif',
                                    fontSize: 28,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PillTextField extends StatelessWidget {
  final TextEditingController controller;
  final bool obscureText;
  final double height;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final List<TextInputFormatter> inputFormatters;
  final VoidCallback? onToggleVisibility;
  final bool showEye;
  final ValueChanged<String>? onSubmitted;

  const _PillTextField({
    required this.controller,
    required this.obscureText,
    required this.height,
    required this.keyboardType,
    required this.textInputAction,
    required this.inputFormatters,
    this.onToggleVisibility,
    this.showEye = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TextField(
            controller: controller,
            obscureText: obscureText,
            textAlign: TextAlign.center,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            inputFormatters: inputFormatters,
            onSubmitted: onSubmitted,
            style: const TextStyle(
              fontFamily: 'InstrumentSerif',
              fontSize: 22,
              color: Colors.black,
            ),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              filled: true,
              fillColor: const Color(0x73FFFFFF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (showEye && onToggleVisibility != null)
            Positioned(
              right: 16,
              child: IconButton(
                splashRadius: 18,
                onPressed: onToggleVisibility,
                icon: Icon(
                  obscureText ? Icons.visibility_off : Icons.visibility,
                  color: Colors.black.withOpacity(0.65),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    return newValue.copyWith(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}
