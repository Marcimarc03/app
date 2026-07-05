import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/trial_record.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

void main() {
  group('TrialRecordBuilder', () {
    TrialRecordBuilder newBuilder() {
      return TrialRecordBuilder(
        sessionId: 'session-1',
        appVersion: '1.2.0+1',
        poseId: 'chair',
        trialOrder: 2,
      );
    }

    test('builds a complete record with session metadata', () {
      final builder = newBuilder()
        ..markPhase(YogaSessionPhase.holdingPose)
        ..recordCalibrationAttempt(
          accepted: true,
          quality: const SensorWindowQuality(
            streams: [
              SensorSampleQuality(
                label: 'Earable accelerometer',
                sampleCount: 42,
                minimumSampleCount: 15,
              ),
            ],
          ),
        )
        ..recordWindow(
          index: 0,
          isValid: true,
          sampleCount: 120,
          result: const PoseEvaluationResult(score: 90, errors: []),
        )
        ..recordWindow(index: 1, isValid: false, sampleCount: 3)
        ..recordFeedback(text: 'Sit deeper.', source: 'llm', spoken: true)
        ..finalScore = 90
        ..completionStatus = 'completed';

      final record = builder.build();

      expect(record.trialOrder, 2);
      expect(record.poseId, 'chair');
      expect(record.calibrationAttempts, 1);
      expect(record.calibrationValid, isTrue);
      expect(record.calibrationSampleCounts['Earable accelerometer'], 42);
      expect(record.validWindowCount, 1);
      expect(record.windows, hasLength(2));
      expect(record.feedbackEvents.single.source, 'llm');
      expect(record.feedbackEvents.single.spoken, isTrue);
      expect(
        record.phaseTimestamps,
        contains(YogaSessionPhase.holdingPose.name),
      );
    });
  });

  group('TrialRecord export', () {
    TrialRecord buildRecord() {
      return (TrialRecordBuilder(
        sessionId: 's, "1"',
        appVersion: 'v',
        poseId: 'warrior_ii',
        trialOrder: 1,
      )
            ..recordWindow(
              index: 0,
              isValid: true,
              sampleCount: 100,
              result: const PoseEvaluationResult(score: 80, errors: []),
            )
            ..finalScore = 80
            ..completionStatus = 'completed')
          .build();
    }

    test('JSON round-trips and contains no API-key-like fields', () {
      final json =
          jsonDecode(buildRecord().toJsonString()) as Map<String, dynamic>;

      expect(json['finalScore'], 80);
      expect(json['completionStatus'], 'completed');
      expect((json['windows'] as List).single['score'], 80);
      expect(json.keys.join(','), isNot(contains('key')));
    });

    test('CSV has a matching header and escapes special characters', () {
      final csv = TrialRecord.toCsv([buildRecord()]);
      final lines = csv.split('\n');

      expect(lines, hasLength(2));
      expect(
        lines.first.split(',').length,
        // The escaped session ID contains commas only inside quotes.
        lines.last.split(RegExp(r',(?=(?:[^"]*"[^"]*")*[^"]*$)')).length,
      );
      expect(lines.last, contains('"s, ""1"""'));
    });
  });
}
