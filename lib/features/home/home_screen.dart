import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io' show Platform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:ktb2/features/dashboard/dashboard_screen.dart';

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

  bool _pinHidden = false;

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
        print('FCM token fetch failed on iOS: $e');
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

      if (role == 'parent' || role == 'child') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(
              displayName: name.isEmpty ? (role == 'parent' ? 'Parent' : 'Child') : name,
              role: role,
              familyId: familyId,
              accountId: accountId,
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
