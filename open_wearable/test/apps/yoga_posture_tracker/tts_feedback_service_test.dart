import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/tts_feedback_service.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:logger/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_tts');
  late List<MethodCall> calls;

  setUpAll(() {
    initLogger(Logger(output: MemoryOutput(), printer: SimplePrinter()));
  });

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'speak') {
        unawaited(_emitTtsEvent('speak.onComplete'));
        return 1;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('FlutterTtsFeedbackService', () {
    test('configures platform TTS and speaks trimmed feedback', () async {
      final service = FlutterTtsFeedbackService();

      await service.speak('  Raise your arms.  ');

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(<String>[
          'awaitSpeakCompletion',
          'setLanguage',
          'setSpeechRate',
          'setPitch',
          'setVolume',
          'speak',
        ]),
      );
      expect(calls.map((call) => call.method), isNot(contains('stop')));
      expect(
        calls
            .singleWhere((call) => call.method == 'awaitSpeakCompletion')
            .arguments,
        isTrue,
      );
      expect(
        calls.singleWhere((call) => call.method == 'setLanguage').arguments,
        'en-US',
      );
      expect(
        calls.singleWhere((call) => call.method == 'setSpeechRate').arguments,
        0.45,
      );
      expect(
        calls.singleWhere((call) => call.method == 'setPitch').arguments,
        1,
      );
      expect(
        calls.singleWhere((call) => call.method == 'setVolume').arguments,
        1,
      );
      expect(
        calls.singleWhere((call) => call.method == 'speak').arguments,
        'Raise your arms.',
      );
    });

    test('does not interrupt an active utterance with a newer cue', () async {
      final service = FlutterTtsFeedbackService();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'speak' ? 1 : null;
      });

      final firstCue = service.speak('Lift your left arm.');
      await _waitUntil(() => calls.any((call) => call.method == 'speak'));

      final secondSpoken = await service.speak('Lower your right arm.');

      expect(secondSpoken, isFalse, reason: 'skipped cues report false');
      expect(
        calls.where((call) => call.method == 'speak'),
        hasLength(1),
      );
      expect(calls.map((call) => call.method), isNot(contains('stop')));

      await _emitTtsEvent('speak.onComplete');
      expect(await firstCue, isTrue, reason: 'completed cues report true');
    });

    test('ignores empty feedback without calling the platform channel',
        () async {
      final service = FlutterTtsFeedbackService();

      await service.speak('   ');

      expect(calls, isEmpty);
    });

    test('stops current platform speech when requested', () async {
      final fallback = _RecordingTtsFeedbackService();
      final service = FlutterTtsFeedbackService(fallback: fallback);

      await service.stop();

      expect(calls.map((call) => call.method), <String>['stop']);
      expect(fallback.stopCount, 1);
    });

    test('falls back when platform TTS does not start playback', () async {
      final fallback = _RecordingTtsFeedbackService();
      final service = FlutterTtsFeedbackService(fallback: fallback);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'speak' ? 0 : null;
      });

      await service.speak('Balance your hands.');

      expect(fallback.spokenTexts, <String>['Balance your hands.']);
    });
  });
}

Future<void> _emitTtsEvent(String method) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'flutter_tts',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not met before timeout.');
}

class _RecordingTtsFeedbackService implements TtsFeedbackService {
  final List<String> spokenTexts = <String>[];
  var stopCount = 0;

  @override
  Future<bool> speak(String text) async {
    spokenTexts.add(text);
    return true;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> dispose() async {}
}
