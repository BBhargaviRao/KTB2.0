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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);

    await FirebaseAuth.instance.signInAnonymously();
    print('AUTH UID: ${FirebaseAuth.instance.currentUser?.uid}');

    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission();
    print('NOTIFICATION PERMISSION STATUS: ${settings.authorizationStatus}');

    final token = await messaging.getToken();
    print('FCM TOKEN: $token');

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FOREGROUND MESSAGE TITLE: ${message.notification?.title}');
      print('FOREGROUND MESSAGE BODY: ${message.notification?.body}');
      print('FOREGROUND MESSAGE DATA: ${message.data}');
    });
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