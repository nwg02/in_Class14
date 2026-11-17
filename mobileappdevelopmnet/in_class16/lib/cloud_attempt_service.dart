
import 'package:cloud_firestore/cloud_firestore.dart';

class AttemptCollision implements Exception {}

class InvalidAttemptDocument implements Exception {}

class CloudAttemptService {
  final String uid;
  final String roundId;
  final int correctCount;
  final Map<String, dynamic> payload;

  CloudAttemptService({
    required this.uid,
    required this.roundId,
    required this.correctCount,
  }) : payload = Map<String, dynamic>.unmodifiable({
          'schemaVersion': 1,
          'variant': 'A',
          'categoryId': 9,
          'questionCount': 10,
          'correctCount': correctCount,
          'submittedAt': FieldValue.serverTimestamp(),
        });

  DocumentReference<Map<String, dynamic>> get reference {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('attempts')
        .doc(roundId);
  }

  bool matchesFixedFields(Map<String, dynamic>? data) {
    if (data == null) return false;

    return data['schemaVersion'] == 1 &&
        data['variant'] == 'A' &&
        data['categoryId'] == 9 &&
        data['questionCount'] == 10 &&
        data['correctCount'] == correctCount;
  }

  // Creates one record, or reuses an identical existing record.
  Future<void> commitOnce() async {
    final ref = reference;

    await FirebaseFirestore.instance.runTransaction<void>(
      (transaction) async {
        final existing = await transaction.get(ref);

        if (existing.exists) {
          if (!matchesFixedFields(existing.data())) {
            throw AttemptCollision();
          }
        } else {
          transaction.set(ref, payload);
        }
      },
    );
  }

  // Reads the deployed server, never the local cache.
  Future<bool> verifyServer() async {
    final snapshot = await reference.get(
      const GetOptions(source: Source.server),
    );

    if (snapshot.metadata.isFromCache ||
        snapshot.metadata.hasPendingWrites) {
      throw InvalidAttemptDocument();
    }

    if (!snapshot.exists) {
      return false;
    }

    final data = snapshot.data();

    if (data == null ||
        data.length != 6 ||
        !matchesFixedFields(data) ||
        data['submittedAt'] is! Timestamp) {
      throw InvalidAttemptDocument();
    }

    return true;
  }
}
