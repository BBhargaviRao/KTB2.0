import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ktb_nudges/features/parent_login/parent_login_screen.dart';
import 'package:ktb_nudges/features/child_login/child_login_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Lock text scaling so it stays identical to Figma
    final mq = MediaQuery.of(context);

    return MediaQuery(
      data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,

          // EXACT SAME AS SPLASH SCREEN
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    SizedBox(height: 40),
                    Text(
                      'NudgeLab',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'InstrumentSerif',
                        fontSize: 72,
                        fontWeight: FontWeight.w400,
                        color: Colors.black,
                        height: 0.95,
                        letterSpacing: -0.4,
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
  static const double _designH = 430; // increased to fit the Continue button

  final _familyCodeCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  // pin should be visible by default.
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

    // Find the family doc with this familyCode
    final famSnap = await db
        .collection('families')
        .where('familyCode', isEqualTo: familyCode)
        .limit(1)
        .get();

    if (famSnap.docs.isEmpty) return null;

    final familyDoc = famSnap.docs.first;

    // Find an account with this pin inside that family
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

    if (role == 'parent') {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ParentLoginScreen(
            parentName: name.isEmpty ? 'Parent' : name,
            familyId: familyId,
            parentAccountId: accountId,
          ),
        ),
      );
      return;
    }

    if (role == 'child') {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChildLoginScreen(
            childName: name.isEmpty ? 'Child' : name,
            familyId: familyId,
            childAccountId: accountId,
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account role is invalid')),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account role is invalid')),
    );
  } on FirebaseException catch (e) {
    // This will catch permission-denied / missing-index / etc.
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
        // Scale down if needed, never scale up.
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
                      // background: linear-gradient(149deg, ...)
                      begin: Alignment(0.85, -1.0),
                      end: Alignment(-0.85, 1.0),
                      colors: [
                        Color(0x4D6200FF), // rgba(98, 0, 255, 0.30)
                        Color(0x4DFF8C00), // rgba(255, 140, 0, 0.30)
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
                                  color: Colors.white.withOpacity(0.6), // hsba(0, 0%, 100%, 0.6)
                                  borderRadius: BorderRadius.circular(30),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.25), // hsba(0,0%,0%,0.25)
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
                                    fontSize: 28, // tweak if your Figma text size differs
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