import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

class AudioUploadService {
  // families/{familyId}/nudgeAnswers/{nudgeId}/... mirrors the Firestore
  // path structure so a nudge's audio is easy to locate/clean up alongside
  // its Firestore doc.
  static Future<String> uploadNudgeAnswer({
    required String familyId,
    required String nudgeId,
    required String localFilePath,
  }) async {
    final ref = FirebaseStorage.instance.ref(
      'families/$familyId/nudgeAnswers/$nudgeId/answer_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await ref.putFile(File(localFilePath), SettableMetadata(contentType: 'audio/m4a'));
    return ref.getDownloadURL();
  }
}
