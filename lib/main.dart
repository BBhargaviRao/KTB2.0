import 'dart:io';

import 'package:flutter/material.dart';
import 'features/splash/splash_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

Future<void> _backgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  print('BACKGROUND MESSAGE ID: ${message.messageId}');
}

Future<void> _setupNotifications() async {
  final messaging = FirebaseMessaging.instance;

  final settings = await messaging.requestPermission();
  print('NOTIFICATION PERMISSION STATUS: ${settings.authorizationStatus}');

  if (settings.authorizationStatus == AuthorizationStatus.denied) {
    print('Notification permission denied.');
    return;
  }

  if (Platform.isIOS) {
    String? apnsToken;

    for (int i = 0; i < 10; i++) {
      apnsToken = await messaging.getAPNSToken();
      print('APNS TOKEN ATTEMPT ${i + 1}: $apnsToken');

      if (apnsToken != null && apnsToken.isNotEmpty) {
        break;
      }

      await Future.delayed(const Duration(seconds: 1));
    }

    if (apnsToken == null || apnsToken.isEmpty) {
      print('APNS token still not available yet. Skipping FCM token fetch for now.');
      return;
    }

    print('APNS TOKEN: $apnsToken');
  }

  final fcmToken = await messaging.getToken();
  print('FCM TOKEN: $fcmToken');

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('FOREGROUND MESSAGE TITLE: ${message.notification?.title}');
    print('FOREGROUND MESSAGE BODY: ${message.notification?.body}');
    print('FOREGROUND MESSAGE DATA: ${message.data}');
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);

    await FirebaseAuth.instance.signInAnonymously();
    print('AUTH UID: ${FirebaseAuth.instance.currentUser?.uid}');

    await _setupNotifications();
  } catch (e, st) {
    print('Startup error: $e');
    print(st);
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}