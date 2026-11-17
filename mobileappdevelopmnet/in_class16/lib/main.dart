import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, mapEquals;

import 'firebase_options.dart';
import 'quiz_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const QuizApp());
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'General Knowledge Quiz',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: Text('Authentication error: ${snapshot.error}')),
          );
        }
        if (snapshot.hasData) {
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          'invalid-credential' => 'Incorrect email or password.',
          'user-disabled' => 'This account is disabled.',
          'too-many-requests' => 'Too many attempts. Try later.',
          'network-request-failed' => 'Check your internet connection.',
          _ => 'Sign-in error: ${error.code}',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Unable to sign in. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quiz Login')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.quiz, size: 72, color: Colors.blue),
              const SizedBox(height: 12),
              const Text(
                'General Knowledge Quiz',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _busy ? null : _signIn,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign In'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _roundIdController = TextEditingController();
  bool _reading = false;
  String? _readError;
  Map<String, dynamic>? _verifiedData;
  String? _verifiedId;

  @override
  void dispose() {
    _roundIdController.dispose();
    super.dispose();
  }

  Future<void> _readSavedAttempt() async {
    if (_reading) return;
    final user = FirebaseAuth.instance.currentUser;
    final id = _roundIdController.text.trim();

    if (user == null || id.isEmpty || id.contains('/') || id == '.' || id == '..') {
      setState(() {
        _readError = 'Enter a valid round document ID while signed in.';
        _verifiedData = null;
        _verifiedId = null;
      });
      return;
    }

    final startingUid = user.uid;
    setState(() {
      _reading = true;
      _readError = null;
      _verifiedData = null;
      _verifiedId = null;
    });

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(startingUid)
          .collection('attempts')
          .doc(id)
          .get(const GetOptions(source: Source.server));

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != startingUid) {
        return;
      }

      if (doc.metadata.isFromCache || doc.metadata.hasPendingWrites) {
        throw const FormatException('This is not a confirmed server result.');
      }
      if (!doc.exists) {
        throw const FormatException('No attempt exists with that ID for this user.');
      }

      final data = doc.data()!;
      const fields = {
        'schemaVersion', 'variant', 'categoryId',
        'questionCount', 'correctCount', 'submittedAt',
      };
      final score = data['correctCount'];
      if (data.keys.toSet().length != fields.length ||
          !data.keys.toSet().containsAll(fields) ||
          data['schemaVersion'] != 1 ||
          data['variant'] != 'A' ||
          data['categoryId'] != 9 ||
          data['questionCount'] != 10 ||
          score is! int ||
          score < 0 || score > 10 ||
          data['submittedAt'] is! Timestamp) {
        throw const FormatException('Server record failed schema verification.');
      }

      setState(() {
        _verifiedData = data;
        _verifiedId = id;
      });
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() => _readError = 'Server read error: ${error.code}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _readError = 'Unable to verify: $error');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Quiz Dashboard')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 62),
              const SizedBox(height: 12),
              const Text(
                'Successfully Signed In!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Email: ${user?.email ?? "Unknown"}', textAlign: TextAlign.center),
              const SizedBox(height: 6),
              SelectableText('UID: ${user?.uid ?? "Unknown"}', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QuizScreen()),
                  );
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Quiz'),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SecurityTestScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.security),
                  label: const Text('Security Tests T10 / T11 (DEV ONLY)'),
                ),
              ],
              const Divider(height: 40),
              const Text(
                'Retrieve a Saved Attempt (T07)',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'After a successful cloud submission, copy the round ID. '
                'Restart the app, sign in as the same user, and enter that exact ID below.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _roundIdController,
                decoration: const InputDecoration(
                  labelText: 'Round ID',
                  hintText: 'Paste the Firestore document ID',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _reading ? null : _readSavedAttempt,
                icon: _reading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_outlined),
                label: const Text('Retrieve From Server'),
              ),
              if (_readError != null) ...[
                const SizedBox(height: 12),
                Text(_readError!, style: const TextStyle(color: Colors.red)),
              ],
              if (_verifiedData != null) ...[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.verified, color: Colors.green),
                            SizedBox(width: 8),
                            Text(
                              'Cloud verified (server-only read)',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text('Score: ${_verifiedData!['correctCount']} / 10'),
                        Text('Variant: ${_verifiedData!['variant']}'),
                        Text('Schema version: ${_verifiedData!['schemaVersion']}'),
                        Text('Category ID: ${_verifiedData!['categoryId']}'),
                        Text('Question count: ${_verifiedData!['questionCount']}'),
                        Text('Submitted at: ${(_verifiedData!['submittedAt'] as Timestamp).toDate().toLocal()}'),
                        const SizedBox(height: 8),
                        SelectableText(
                          'users/${user!.uid}/attempts/$_verifiedId',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              OutlinedButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('Sign Out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


// Debug-only screen. These are REAL calls to the deployed Firestore backend,
// not simulated rules tests. Do not include this screen in release builds.
class SecurityTestScreen extends StatefulWidget {
  const SecurityTestScreen({super.key});

  @override
  State<SecurityTestScreen> createState() => _SecurityTestScreenState();
}

class _SecurityTestScreenState extends State<SecurityTestScreen> {
  final _ownerUidInput = TextEditingController();
  final _roundIdInput = TextEditingController();
  final List<String> _results = [];
  bool _running = false;

  @override
  void dispose() {
    _ownerUidInput.dispose();
    _roundIdInput.dispose();
    super.dispose();
  }

  bool _validDocumentId(String value) =>
      value.isNotEmpty && value != '.' && value != '..' && !value.contains('/');

  Map<String, dynamic> _validAttempt({int correctCount = 5}) => {
        'schemaVersion': 1,
        'variant': 'A',
        'categoryId': 9,
        'questionCount': 10,
        'correctCount': correctCount,
        'submittedAt': FieldValue.serverTimestamp(),
      };

  Future<String> _expectDenied(
    String title,
    Future<void> Function() request,
  ) async {
    try {
      await request();
      return '$title: FAIL — unexpectedly allowed';
    } on FirebaseException catch (error) {
      return error.code == 'permission-denied'
          ? '$title: PASS — permission-denied'
          : '$title: FAIL — ${error.code}';
    } catch (error) {
      return '$title: FAIL — $error';
    }
  }

  // T10: Sign in as B, read A's existing document, and try creating
  // a new valid document under A's UID (ownership denial, not update denial).
  Future<void> _testT10() async {
    if (_running) return;
    final current = FirebaseAuth.instance.currentUser;
    final ownerUid = _ownerUidInput.text.trim();
    final savedRound = _roundIdInput.text.trim();
    if (current == null || !_validDocumentId(ownerUid) ||
        !_validDocumentId(savedRound) || current.uid == ownerUid) {
      setState(() {
        _results
          ..clear()
          ..add('T10: Sign in as user B, then enter DIFFERENT user A UID and A saved round ID.');
      });
      return;
    }

    final actingUid = current.uid;
    setState(() {
      _running = true;
      _results.clear();
      _results.add('T10: Real deployed-backend requests as user B');
    });

    try {
      final attempts = FirebaseFirestore.instance
          .collection('users').doc(ownerUid).collection('attempts');
      final original = attempts.doc(savedRound);
      final readResult = await _expectDenied('B reads A record', () async {
        await original.get(const GetOptions(source: Source.server));
      });

      // A generated ID avoids triggering update-denial rather than ownership.
      final illegalNewRecord = attempts.doc();
      final writeResult = await _expectDenied('B creates in A path', () async {
        await illegalNewRecord.set(_validAttempt());
      });

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != actingUid) return;
      setState(() {
        _results.add(readResult);
        _results.add(writeResult);
        _results.add('T10 result: ${readResult.contains('PASS') && writeResult.contains('PASS') ? 'PASS' : 'FAIL'}');
        if (writeResult.contains('FAIL — unexpectedly allowed')) {
          _results.add('WARNING: A foreign-path write succeeded. Fix rules and remove the test document from the console.');
          _results.add('Unexpected document ID: ${illegalNewRecord.id}');
        }
      });
    } catch (error) {
      if (mounted) setState(() => _results.add('T10 error: $error'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  // T11: Sign in as A. Reject two invalid creates and an update
  // of A's already-completed, immutable attempt. Check original unchanged.
  Future<void> _testT11() async {
    if (_running) return;
    final current = FirebaseAuth.instance.currentUser;
    final ownerUid = _ownerUidInput.text.trim();
    final savedRound = _roundIdInput.text.trim();
    if (current == null || ownerUid != current.uid ||
        !_validDocumentId(savedRound)) {
      setState(() {
        _results
          ..clear()
          ..add('T11: Sign in as user A and enter A UID and an EXISTING saved round ID.');
      });
      return;
    }

    final actingUid = current.uid;
    setState(() {
      _running = true;
      _results.clear();
      _results.add('T11: Real deployed-backend rule checks as user A');
    });

    try {
      final attempts = FirebaseFirestore.instance
          .collection('users').doc(ownerUid).collection('attempts');
      final original = attempts.doc(savedRound);
      final before = await original.get(const GetOptions(source: Source.server));
      if (!before.exists || before.metadata.isFromCache ||
          before.metadata.hasPendingWrites) {
        throw StateError('Cannot verify original attempt from server.');
      }
      final oldData = before.data()!;
      final oldScore = oldData['correctCount'];
      if (oldScore is! int) throw StateError('Original correctCount missing.');

      final invalidScoreDoc = attempts.doc();
      final badScore = await _expectDenied('Score 11 rejected', () async {
        await invalidScoreDoc.set(_validAttempt(correctCount: 11));
      });

      final extraFieldDoc = attempts.doc();
      final extra = await _expectDenied('Extra field rejected', () async {
        final payload = _validAttempt()..['unexpectedField'] = true;
        await extraFieldDoc.set(payload);
      });

      final update = await _expectDenied('Completed record update rejected', () async {
        await original.update({'correctCount': (oldScore + 1) % 11});
      });

      final after = await original.get(const GetOptions(source: Source.server));
      final unchanged = after.exists &&
          !after.metadata.isFromCache &&
          !after.metadata.hasPendingWrites &&
          mapEquals(oldData, after.data());

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != actingUid) return;
      setState(() {
        _results.addAll([badScore, extra, update]);
        _results.add('Original record unchanged: ${unchanged ? 'PASS' : 'FAIL'}');
        final passed = [badScore, extra, update].every((x) => x.contains('PASS')) && unchanged;
        _results.add('T11 result: ${passed ? 'PASS' : 'FAIL'}');
        if (!passed) {
          _results.add('Review the deployed rules. If an invalid create succeeded, remove that invalid document in the Firebase Console.');
          _results.add('Probe IDs: ${invalidScoreDoc.id}, ${extraFieldDoc.id}');
        }
      });
    } catch (error) {
      if (mounted) setState(() => _results.add('T11 error: $error'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '(signed out)';
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(title: const Text('Security Tests (DEV ONLY)')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text('T10: sign in as B to test denied cross-user read/create. '
                    'T11: sign in as A to test invalid creates and an immutable update. '
                    'These operations contact your deployed Firestore project.'),
                const SizedBox(height: 12),
                SelectableText('Currently signed-in UID: $uid'),
                const SizedBox(height: 14),
                TextField(
                  controller: _ownerUidInput,
                  decoration: const InputDecoration(
                    labelText: 'User A UID',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _roundIdInput,
                  decoration: const InputDecoration(
                    labelText: 'Existing User A round ID',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _running ? null : _testT10,
                  child: const Text('Run T10 (must be signed in as B)'),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _running ? null : _testT11,
                  child: const Text('Run T11 (must be signed in as A)'),
                ),
                if (_running) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
                if (_results.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(_results.join('\n')),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                const Text('Screenshot the results. Both tests require PASS for every check. '
                    'Use your normal app for submissions; this screen only performs security tests.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
