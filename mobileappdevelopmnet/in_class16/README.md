CSC 4360 / ICA 16 — Class A General Knowledge Cloud Quiz
Repository: https://github.com/nwg02/inClass16
Features
- Firebase Authentication with Email/Password and separate user accounts.
- Open Trivia Database GET request for exactly 10 easy General Knowledge multiple-choice questions.
- HTTP 200, API response code 0, question-count/format/choice validation, HTML decoding, once-per-question shuffling.
- One answer per question, score and review, fresh round ID for Replay.
- Create-once Firestore transaction at users/{uid}/attempts/{roundId}; exact six fields.
- Source.server verification and persisted-attempt retrieval after restart.
- Recovery from lost acknowledgement and offline/unavailable states without intentionally creating duplicate records.
- Debug-only T10/T11 screen for deployed security-rules tests.
Install these source files
Extract the ZIP into your EXISTING Flutter project, preserving the project's lib/firebase_options.dart,
pubspec.yaml, Android configuration and local Firebase setup. ZIP deliberately contains no Firebase credentials.
The complete replacement source files are lib/main.dart and lib/quiz_screen.dart.
firestore.rules is a copy of the rules that must be published to the Firebase project.
Do not copy this rules file into lib/.
Dependencies
Run in Flutter project root:
flutter pub add http html_unescape firebase_core firebase_auth cloud_firestore
flutter pub get
Ensure your android/app/src/main/AndroidManifest.xml includes the Internet permission immediately within the root <manifest> element:
<uses-permission android:name="android.permission.INTERNET" />
The project must have a generated lib/firebase_options.dart from flutterfire configure.
Use Firebase Authentication with Email/Password enabled and Cloud Firestore in production mode.
Deploy the restrictive Firestore rules from firestore.rules using the Firebase console.
Build the release APK on your Mac
cd /Users/nick/Desktop/mobileappdevelopmnet/in_class16
flutter analyze
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ICA16_A_NickGilreath.apk
You can alternatively use bash scripts/build_release.sh after extracting these files into your project.
If flutter analyze finds issues, resolve them before packaging. The release APK is not built or tested in the assistant environment; only your Mac has the configured Flutter/Android toolchains.
Install-test the resulting release APK on your emulator/device.
Evidence and development testing
- T01/T02/T04/T05/T06/T07/T08/T09 were reported working during the user walkthrough; preserve screenshots/logs.
- T03 (bad JSON, nonzero response code, nine results) and T12 (injected unavailable/resource-exhausted) require explicit injected tests; do not mark PASS without running them.
- For T10 and T11, run flutter run (debug) and open Security Tests T10 / T11 (DEV ONLY) from the dashboard. Those actions perform REAL Firestore requests and should be demonstrated online.
- T09 test flag in lib/quiz_screen.dart: _injectLostAcknowledgement; default must remain false for release.
- Do not commit passwords, access tokens, service-account JSON, emulator-only credentials, or unredacted personal data.
- Capture the Git commit hash with git rev-parse --short HEAD and fill it into the evidence document.
Submission
1. ICA16_A_NickGilreath.apk (release APK, after install test)
2. Public GitHub repository URL with source/rules/README/final commit
3. ICA16_A_NickGilreath.docx with screenshots, real test log and six grounded responses
Deadline: November 16, 2026 at 11:59 PM