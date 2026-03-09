import 'package:flutter/material.dart';
import '../home/home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;

      Navigator.of(context).pushReplacement(_smartAnimateTo(const HomeScreen()));
    });
  }

  PageRouteBuilder _smartAnimateTo(Widget page) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 3000),
      reverseTransitionDuration: const Duration(milliseconds: 3000),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        );

        // Crossfade
        final opacity = Tween<double>(begin: 0.0, end: 1.0).animate(curve);

        // Very subtle scale to mimic "smart animate" smoothness
        final scale = Tween<double>(begin: 0.985, end: 1.0).animate(curve);

        return FadeTransition(
          opacity: opacity,
          child: ScaleTransition(
            scale: scale,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Your existing splash UI (keep as-is)
    return Scaffold(
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'Welcome to',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      color: Colors.black,
                      fontSize: 22,
                      fontWeight: FontWeight.w400,
                      height: 1.1,
                    ),
                  ),
                  SizedBox(height: 12),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'NudgeLab',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'InstrumentSerif',
                        color: Colors.black,
                        fontSize: 96,
                        fontWeight: FontWeight.w400,
                        height: 0.95,
                        letterSpacing: -0.408,
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'A gentle check-in app for families',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      color: Colors.black,
                      fontSize: 20,
                      fontWeight: FontWeight.w400,
                      height: 1.1,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}