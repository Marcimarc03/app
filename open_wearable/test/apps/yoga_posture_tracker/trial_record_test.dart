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
        studyConfig: const StudyTrialConfig(
          participantId: 'P07',
          condition: StudyCondition.llmLiveCoaching,
          trialOrder: 2,
        ),
      );
    }

    test('builds a complete record with study metadata', () {
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

      expect(record.participantId, 'P07');
      expect(record.trialId, 'P07-T2');
      expect(record.trialOrder, 2);
      expect(record.condition, 'llmLiveCoaching');
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

    test('a free-mode record carries no participant information', () {
      final record = TrialRecordBuilder(
        sessionId: 'session-2',
        appVersion: 'unknown',
        poseId: 'cobra',
        studyConfig: null,
      ).build();

      expect(record.participantId, isNull);
      expect(record.trialId, isNull);
      expect(record.condition, 'free');
    });
  });

  group('TrialRecord export', () {
    TrialRecord buildRecord() {
      return (TrialRecordBuilder(
        sessionId: 's',
        appVersion: 'v',
        poseId: 'warrior_ii',
        studyConfig: const StudyTrialConfig(
          participantId: 'P, "1"',
          condition: StudyCondition.noLiveCoaching,
          trialOrder: 1,
        ),
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
        // The escaped participant ID contains commas only inside quotes.
        lines.last.split(RegExp(r',(?=(?:[^"]*"[^"]*")*[^"]*$)')).length,
      );
      expect(lines.last, contains('"P, ""1"""'));
    });
  });
}
