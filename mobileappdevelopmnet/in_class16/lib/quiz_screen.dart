import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;

class QuizQuestion {
  final String question;
  final String correctAnswer;
  final List<String> choices;

  const QuizQuestion({
    required this.question,
    required this.correctAnswer,
    required this.choices,
  });

  factory QuizQuestion.fromJson(
    Map<String, dynamic> json,
    HtmlUnescape decoder,
  ) {
    if (json['category'] != 'General Knowledge' ||
        json['difficulty'] != 'easy' ||
        json['type'] != 'multiple') {
      throw const FormatException('Wrong question category, difficulty, or type.');
    }

    String decoded(dynamic value) {
      if (value is! String) {
        throw const FormatException('Expected question or answer text.');
      }
      final text = decoder.convert(value).trim();
      if (text.isEmpty) {
        throw const FormatException('Question or answer is empty.');
      }
      return text;
    }

    final question = decoded(json['question']);
    final correctAnswer = decoded(json['correct_answer']);
    final incorrect = json['incorrect_answers'];

    if (incorrect is! List || incorrect.length != 3) {
      throw const FormatException('Expected exactly three incorrect answers.');
    }

    final choices = <String>[
      correctAnswer,
      ...incorrect.map(decoded),
    ];

    if (choices.map((value) => value.toLowerCase()).toSet().length != 4) {
      throw const FormatException('Answer choices must be unique.');
    }

    choices.shuffle(); // Only shuffle once, not every time build() runs.
    return QuizQuestion(
      question: question,
      correctAnswer: correctAnswer,
      choices: choices,
    );
  }
}

// The only permitted fields in a completed Class A attempt.
class _CloudAttempt {
  final String uid;
  final String roundId;
  final int correctCount;
  late final Map<String, dynamic> payload =
      Map<String, dynamic>.unmodifiable({
    'schemaVersion': 1,
    'variant': 'A',
    'categoryId': 9,
    'questionCount': 10,
    'correctCount': correctCount,
    'submittedAt': FieldValue.serverTimestamp(),
  });

  _CloudAttempt({
    required this.uid,
    required this.roundId,
    required this.correctCount,
  });

  DocumentReference<Map<String, dynamic>> get document =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('attempts')
          .doc(roundId);

  bool matchesFixedFields(Map<String, dynamic>? data) {
    return data != null &&
        data['schemaVersion'] == 1 &&
        data['variant'] == 'A' &&
        data['categoryId'] == 9 &&
        data['questionCount'] == 10 &&
        data['correctCount'] == correctCount;
  }

  Future<void> commitOnce() async {
    final ref = document;

    await FirebaseFirestore.instance.runTransaction<void>((transaction) async {
      final existing = await transaction.get(ref);

      if (existing.exists) {
        if (!matchesFixedFields(existing.data())) {
          throw const _AttemptCollision();
        }
        // Same attempt already exists. Do not overwrite it.
        return;
      }

      transaction.set(ref, payload);
    });
  }

  Future<bool> verifyOnServer() async {
    final snapshot = await document.get(
      const GetOptions(source: Source.server),
    );

    if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
      throw const _InvalidCloudRecord();
    }
    if (!snapshot.exists) return false;

    final data = snapshot.data();
    const expectedFields = <String>{
      'schemaVersion',
      'variant',
      'categoryId',
      'questionCount',
      'correctCount',
      'submittedAt',
    };

    if (data == null ||
        data.keys.toSet().length != expectedFields.length ||
        !data.keys.toSet().containsAll(expectedFields) ||
        !matchesFixedFields(data) ||
        data['submittedAt'] is! Timestamp) {
      throw const _InvalidCloudRecord();
    }

    return true;
  }
}

class _AttemptCollision implements Exception {
  const _AttemptCollision();
}

class _InvalidCloudRecord implements Exception {
  const _InvalidCloudRecord();
}

enum _CloudState {
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  verificationUnavailable,
  permissionDenied,
  authError,
  collision,
}

class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  static const String _apiUrl =
      'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple';

  // Development-only test for T09. Turn on, complete a real cloud commit,
  // then press Check Server to recover the acknowledgement.
  static const bool _injectLostAcknowledgement = false;

  List<QuizQuestion> _questions = [];
  List<String?> _answers = [];
  int _currentIndex = 0;
  int _score = 0;
  bool _loading = false;
  bool _finished = false;
  String? _requestError;
  DateTime? _lastRequest;

  late final String _ownerUid;
  late String _roundId;
  _CloudAttempt? _attempt;
  _CloudState _cloudState = _CloudState.readyToSubmit;
  String _cloudMessage = '';
  bool _commitReturned = false;

  bool get _cloudUnresolved =>
      _cloudState == _CloudState.submitting ||
      _cloudState == _CloudState.verifying ||
      _cloudState == _CloudState.saveUnknown ||
      _cloudState == _CloudState.verificationUnavailable;

  String _newRoundId() => FirebaseFirestore.instance
      .collection('users')
      .doc(_ownerUid)
      .collection('attempts')
      .doc()
      .id;

  bool _sameContext(String uid, String roundId) =>
      mounted &&
      FirebaseAuth.instance.currentUser?.uid == uid &&
      _ownerUid == uid &&
      _roundId == roundId;

  @override
  void initState() {
    super.initState();
    _ownerUid = FirebaseAuth.instance.currentUser!.uid;
    _roundId = _newRoundId();
    _fetchQuestions();
  }

  Future<void> _fetchQuestions() async {
    if (_loading || _cloudUnresolved) return;

    final now = DateTime.now();
    if (_lastRequest != null &&
        now.difference(_lastRequest!).inMilliseconds < 5000) {
      setState(() {
        _requestError = 'Please wait at least 5 seconds before retrying.';
      });
      return;
    }

    _lastRequest = now;
    setState(() {
      _loading = true;
      _requestError = null;
      _questions = [];
    });

    try {
      final response = await http
          .get(Uri.parse(_apiUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP status ${response.statusCode}');
      }

      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Invalid API JSON object.');
      }
      if (json['response_code'] != 0) {
        throw Exception('OpenTDB response code ${json['response_code']}');
      }

      final results = json['results'];
      if (results is! List || results.length != 10) {
        throw const FormatException('Expected exactly 10 questions.');
      }

      final decoder = HtmlUnescape();
      final loaded = results.map((item) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Malformed question object.');
        }
        return QuizQuestion.fromJson(item, decoder);
      }).toList();

      if (!mounted) return;
      setState(() {
        _questions = loaded;
        _answers = List<String?>.filled(loaded.length, null);
        _currentIndex = 0;
        _score = 0;
        _finished = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _requestError = 'Could not load questions: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectAnswer(String answer) {
    if (_loading ||
        _finished ||
        _questions.isEmpty ||
        _answers[_currentIndex] != null) {
      return;
    }

    setState(() {
      _answers[_currentIndex] = answer;
      if (answer == _questions[_currentIndex].correctAnswer) _score++;
    });
  }

  void _nextQuestion() {
    if (_questions.isEmpty || _answers[_currentIndex] == null) return;
    setState(() {
      if (_currentIndex < _questions.length - 1) {
        _currentIndex++;
      } else {
        _finished = true;
      }
    });
  }

  void _replayQuiz() {
    if (_loading || _cloudUnresolved) return;
    setState(() {
      _roundId = _newRoundId();
      _attempt = null;
      _commitReturned = false;
      _cloudState = _CloudState.readyToSubmit;
      _cloudMessage = '';
      _questions = [];
      _answers = [];
      _currentIndex = 0;
      _score = 0;
      _finished = false;
      _requestError = null;
    });
    _fetchQuestions();
  }

  Future<void> _submitToCloud() async {
    if (!_finished || _cloudState != _CloudState.readyToSubmit) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != _ownerUid) {
      setState(() {
        _cloudState = _CloudState.authError;
        _cloudMessage = 'You must be signed in as the original user.';
      });
      return;
    }

    _attempt ??= _CloudAttempt(
      uid: _ownerUid,
      roundId: _roundId,
      correctCount: _score,
    );

    final attempt = _attempt!;
    final uid = attempt.uid;
    final id = attempt.roundId;

    setState(() {
      _cloudState = _CloudState.submitting;
      _cloudMessage = 'Submitting the round to Cloud Firestore...';
    });

    try {
      await attempt.commitOnce();
      _commitReturned = true;
      if (!_sameContext(uid, id)) return;

      if (_injectLostAcknowledgement) {
        setState(() {
          _cloudState = _CloudState.saveUnknown;
          _cloudMessage =
              'TEST INJECTION: Cloud commit completed, acknowledgement hidden. '
              'Press Check Server.';
        });
        return;
      }

      setState(() {
        _cloudState = _CloudState.verifying;
        _cloudMessage = 'Checking the exact document on the server...';
      });

      final found = await attempt.verifyOnServer();
      if (!_sameContext(uid, id)) return;

      setState(() {
        if (found) {
          _cloudState = _CloudState.cloudVerified;
          _cloudMessage = 'Cloud verified! Score $_score/10 saved.';
        } else {
          _cloudState = _CloudState.verificationUnavailable;
          _cloudMessage =
              'The transaction completed, but the server did not return '
              'the record. Check Server again.';
        }
      });
    } on _AttemptCollision {
      if (!_sameContext(uid, id)) return;
      setState(() {
        _cloudState = _CloudState.collision;
        _cloudMessage = 'Round ID collision: existing score is different.';
      });
    } on _InvalidCloudRecord {
      if (!_sameContext(uid, id)) return;
      setState(() {
        _cloudState = _CloudState.collision;
        _cloudMessage = 'Server record has incorrect fields or timestamp.';
      });
    } on FirebaseException catch (e) {
      if (!_sameContext(uid, id)) return;
      setState(() {
        if (_commitReturned) {
          _cloudState = _CloudState.verificationUnavailable;
          _cloudMessage =
              'Commit completed; server verification unavailable (${e.code}).';
        } else if (e.code == 'permission-denied') {
          _cloudState = _CloudState.permissionDenied;
          _cloudMessage = 'Permission denied. Check deployed Firestore rules.';
        } else if (e.code == 'unauthenticated') {
          _cloudState = _CloudState.authError;
          _cloudMessage = 'Firebase authentication was lost.';
        } else {
          _cloudState = _CloudState.saveUnknown;
          _cloudMessage =
              'Save outcome unknown (${e.code}). Check the server before retrying.';
        }
      });
    } catch (e) {
      if (!_sameContext(uid, id)) return;
      setState(() {
        _cloudState = _commitReturned
            ? _CloudState.verificationUnavailable
            : _CloudState.saveUnknown;
        _cloudMessage = 'Cloud outcome needs verification: $e';
      });
    }
  }

  Future<void> _checkServer() async {
    if (_cloudState != _CloudState.saveUnknown &&
        _cloudState != _CloudState.verificationUnavailable) {
      return;
    }

    final attempt = _attempt;
    if (attempt == null ||
        !_sameContext(attempt.uid, attempt.roundId)) {
      return;
    }

    setState(() {
      _cloudState = _CloudState.verifying;
      _cloudMessage = 'Checking the original round ID on the server...';
    });

    try {
      final found = await attempt.verifyOnServer();
      if (!_sameContext(attempt.uid, attempt.roundId)) return;

      setState(() {
        if (found) {
          _cloudState = _CloudState.cloudVerified;
          _cloudMessage = 'Cloud verified! Original attempt recovered.';
        } else if (_commitReturned) {
          _cloudState = _CloudState.verificationUnavailable;
          _cloudMessage =
              'The completed transaction has no matching server record. '
              'Do not start a new round yet.';
        } else {
          // The previous transaction has already returned an error.
          _cloudState = _CloudState.readyToSubmit;
          _cloudMessage =
              'No server record found. You can retry with the SAME round ID.';
        }
      });
    } on _InvalidCloudRecord {
      if (!_sameContext(attempt.uid, attempt.roundId)) return;
      setState(() {
        _cloudState = _CloudState.collision;
        _cloudMessage = 'Existing server record does not match this round.';
      });
    } on FirebaseException catch (e) {
      if (!_sameContext(attempt.uid, attempt.roundId)) return;
      setState(() {
        _cloudState = _CloudState.verificationUnavailable;
        _cloudMessage = 'Server read unavailable (${e.code}). Try again online.';
      });
    } catch (e) {
      if (!_sameContext(attempt.uid, attempt.roundId)) return;
      setState(() {
        _cloudState = _CloudState.verificationUnavailable;
        _cloudMessage = 'Server verification unavailable: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_cloudUnresolved,
      child: Scaffold(
        appBar: AppBar(title: const Text('General Knowledge Quiz')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _requestError != null
                ? _buildError()
                : _questions.isEmpty
                    ? const Center(child: Text('No questions loaded.'))
                    : _finished
                        ? _buildResults()
                        : _buildQuestion(),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 58, color: Colors.red),
            const SizedBox(height: 16),
            Text(_requestError!, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _fetchQuestions,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion() {
    final question = _questions[_currentIndex];
    final selected = _answers[_currentIndex];
    final answered = selected != null;
    final correct = selected == question.correctAnswer;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Question ${_currentIndex + 1} of ${_questions.length}',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: (_currentIndex + 1) / _questions.length,
              minHeight: 8,
            ),
            const SizedBox(height: 12),
            Text(
              'Current Score: $_score / 10',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 28),
            Text(
              question.question,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            ...question.choices.map((choice) {
              final isCorrectChoice = choice == question.correctAnswer;
              final isSelected = choice == selected;
              Color? background;
              IconData icon = Icons.circle_outlined;
              Color iconColor = Colors.grey;

              if (answered && isCorrectChoice) {
                background = Colors.green.shade100;
                icon = Icons.check_circle;
                iconColor = Colors.green;
              } else if (answered && isSelected) {
                background = Colors.red.shade100;
                icon = Icons.cancel;
                iconColor = Colors.red;
              }

              return Card(
                color: background,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(icon, color: iconColor),
                  title: Text(choice),
                  onTap: answered ? null : () => _selectAnswer(choice),
                ),
              );
            }),
            if (answered) ...[
              const SizedBox(height: 12),
              Text(
                correct
                    ? 'Correct answer!'
                    : 'Incorrect. Correct answer: ${question.correctAnswer}',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: correct ? Colors.green : Colors.red,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _nextQuestion,
                child: Text(
                  _currentIndex == _questions.length - 1
                      ? 'Finish Quiz'
                      : 'Next Question',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final canCheckServer =
        _cloudState == _CloudState.saveUnknown ||
        _cloudState == _CloudState.verificationUnavailable;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Icon(Icons.emoji_events, size: 65, color: Colors.amber),
            const SizedBox(height: 10),
            const Text(
              'Quiz Complete!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'Final Score: $_score / 10',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              'Percentage: ${(_score * 10)}%',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Round ID: ...${_roundId.substring(_roundId.length - 6)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 18),
            const Text(
              'Answer Review',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            ...List.generate(_questions.length, (index) {
              final q = _questions[index];
              final selected = _answers[index];
              final correct = selected == q.correctAnswer;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index + 1}. ${q.question}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your answer: $selected',
                        style: TextStyle(
                          color: correct ? Colors.green : Colors.red,
                        ),
                      ),
                      Text('Correct answer: ${q.correctAnswer}'),
                      Text(
                        correct ? 'Correct' : 'Incorrect',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: correct ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 16),
            if (_cloudMessage.isNotEmpty) ...[
              Text(
                _cloudMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _cloudState == _CloudState.cloudVerified
                      ? Colors.green
                      : Colors.deepOrange,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_cloudState == _CloudState.submitting ||
                _cloudState == _CloudState.verifying) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: _cloudState == _CloudState.readyToSubmit
                  ? _submitToCloud
                  : null,
              child: Text(
                switch (_cloudState) {
                  _CloudState.cloudVerified => 'Cloud Verified',
                  _CloudState.submitting => 'Submitting...',
                  _CloudState.verifying => 'Verifying...',
                  _ => 'Submit to Cloud',
                },
              ),
            ),
            if (canCheckServer) ...[
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _checkServer,
                child: const Text('Check Server'),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _cloudUnresolved ? null : _replayQuiz,
              child: const Text('Replay Quiz'),
            ),
            if (_cloudState == _CloudState.cloudVerified) ...[
              const SizedBox(height: 12),
              SelectableText(
                'Verified path:\nusers/$_ownerUid/attempts/$_roundId',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
