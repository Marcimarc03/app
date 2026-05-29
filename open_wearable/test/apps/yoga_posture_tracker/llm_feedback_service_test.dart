import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logger/logger.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/llm_feedback_service.dart';
import 'package:open_wearable/models/logger.dart';

void main() {
  setUpAll(() {
    initLogger(Logger(output: MemoryOutput(), printer: SimplePrinter()));
  });

  group('GeminiLlmFeedbackService', () {
    test('normalizes a complete Gemini cue for spoken feedback', () async {
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        client: MockClient((request) async {
          expect(request.headers['x-goog-api-key'], 'test-key');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['systemInstruction'], isA<Map<String, dynamic>>());
          expect(body['contents'], isA<List<dynamic>>());
          expect(
            body['generationConfig'],
            containsPair('maxOutputTokens', 96),
          );
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            'Gently raise your left arm toward shoulder height',
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final feedback = await service.generateYogaFeedback(
        postureErrors: const [],
        poseName: 'Warrior II',
        score: 82,
      );

      expect(feedback.generatedByLlm, isTrue);
      expect(
        feedback.recommendation,
        'Gently raise your left arm toward shoulder height.',
      );
    });

    test('joins line-broken Gemini cue before validating completeness',
        () async {
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Lift both\narms toward shoulder height'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final feedback = await service.generateYogaFeedback(
        postureErrors: const [],
        poseName: 'Warrior II',
        score: 82,
      );

      expect(feedback.generatedByLlm, isTrue);
      expect(
        feedback.recommendation,
        'Lift both arms toward shoulder height.',
      );
    });

    test('uses fallback when Gemini returns a sentence fragment', () async {
      final fallback = _RecordingLlmFeedbackService(
        const YogaFeedback(
          recommendation: 'Raise your left arm toward shoulder height.',
        ),
      );
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        fallback: fallback,
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Gently'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final feedback = await service.generateYogaFeedback(
        postureErrors: const [],
        poseName: 'Warrior II',
        score: 82,
      );

      expect(fallback.callCount, 1);
      expect(feedback.generatedByLlm, isFalse);
      expect(
        feedback.recommendation,
        'Raise your left arm toward shoulder height.',
      );
    });

    test('generates pose setup instructions with a dedicated prompt', () async {
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final systemInstruction =
              body['systemInstruction'] as Map<String, dynamic>;
          final systemParts = systemInstruction['parts'] as List<dynamic>;
          final userContents = body['contents'] as List<dynamic>;
          final userParts = (userContents.single
              as Map<String, dynamic>)['parts'] as List<dynamic>;
          expect(
            (systemParts.single as Map<String, dynamic>)['text'],
            contains('setup cue'),
          );
          expect(
            (userParts.single as Map<String, dynamic>)['text'],
            contains('wide stance'),
          );
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            'Step into a wide stance, raise both arms, bend your front knee, and gaze over your front hand.',
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final feedback = await service.generatePoseSetupInstruction(
        poseName: 'Warrior II',
      );

      expect(feedback.generatedByLlm, isTrue);
      expect(
        feedback.recommendation,
        'Step into a wide stance, raise both arms, bend your front knee, and gaze over your front hand.',
      );
    });
  });
}

class _RecordingLlmFeedbackService implements LlmFeedbackService {
  final YogaFeedback feedback;
  var callCount = 0;

  _RecordingLlmFeedbackService(this.feedback);

  @override
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  }) async {
    callCount += 1;
    return feedback;
  }

  @override
  Future<YogaFeedback> generatePoseSetupInstruction({
    required String poseName,
  }) async {
    callCount += 1;
    return feedback;
  }
}
