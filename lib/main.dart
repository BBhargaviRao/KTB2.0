import 'dart:io';

import 'package:flutter/material.dart';
import 'features/splash/splash_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';

Future<void> _backgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print('BACKGROUND MESSAGE ID: ${message.messageId}');
}

Future<void> _setupNotifications() async {
  final messaging = FirebaseMessaging.instance;

  final settings = await messaging.requestPermission();
  print('NOTIFICATION PERMISSION: ${settings.authorizationStatus}');

  if (settings.authorizationStatus == AuthorizationStatus.denied) {
    print('Notification permission denied.');
    return;
  }

  // iOS: show banners even when app is in foreground
  await messaging.setForegroundNotificationPresentationOptions(
    alert: true, badge: true, sound: true,
  );

  if (Platform.isIOS) {
    String? apnsToken;
    for (int i = 0; i < 10; i++) {
      apnsToken = await messaging.getAPNSToken();
      if (apnsToken != null && apnsToken.isNotEmpty) break;
      await Future.delayed(const Duration(seconds: 1));
    }
    print('APNS TOKEN: $apnsToken');
  }

  final fcmToken = await messaging.getToken();
  print('FCM TOKEN: $fcmToken');

  // When Firebase refreshes the FCM token, update Firestore so Cloud Functions
  // always have a valid token to send to.
  messaging.onTokenRefresh.listen((newToken) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('device_registrations')
          .doc(uid)
          .set({
        'fcmToken': newToken,
        'tokenType': 'fcm',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print('FCM token refreshed and saved: $newToken');
    } catch (e) {
      print('Failed to save refreshed FCM token: $e');
    }
  });

  // Show a local banner when a FCM message arrives while app is in foreground.
  // On iOS the system handles background/terminated delivery automatically.
  // On Android, foreground FCM messages are silent without this.
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final n = message.notification;
    print('FOREGROUND FCM: ${n?.title} / ${n?.body}');
    if (n != null) {
      NotificationService.showNudgeBanner(
        n.title ?? 'KTB',
        n.body ?? '',
      );
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);

    await NotificationService.init();

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
