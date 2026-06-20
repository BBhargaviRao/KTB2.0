import 'package:flutter/services.dart';

class AdmService {
  static const MethodChannel _channel = MethodChannel('ktb2/adm');

  static Future<String?> getRegistrationId() async {
    try {
      final token =
          await _channel.invokeMethod<String>('getAdmRegistrationId');
      return token;
    } catch (e) {
      print('ADM token read error: $e');
      return null;
    }
  }
}