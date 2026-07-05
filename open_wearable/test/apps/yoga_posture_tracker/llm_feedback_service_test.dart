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

    test('uses the selected pose in the system instruction', () async {
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final systemInstruction =
              body['systemInstruction'] as Map<String, dynamic>;
          final systemParts = systemInstruction['parts'] as List<dynamic>;
          final systemText =
              (systemParts.single as Map<String, dynamic>)['text'] as String;
          expect(systemText, contains('during Chair'));
          expect(systemText, isNot(contains('Warrior II')));
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Reach both arms upward and sit deeper.'},
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
        poseName: 'Chair',
        score: 70,
      );

      expect(feedback.generatedByLlm, isTrue);
    });

    test('falls back when the request exceeds the timeout', () async {
      final fallback = _RecordingLlmFeedbackService(
        const YogaFeedback(recommendation: 'Keep both arms steady and long.'),
      );
      final service = GeminiLlmFeedbackService(
        apiKey: 'test-key',
        fallback: fallback,
        requestTimeout: const Duration(milliseconds: 50),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{}', 200);
        }),
      );

      final feedback = await service.generateYogaFeedback(
        postureErrors: const [],
        poseName: 'Triangle',
        score: 55,
      );

      expect(fallback.callCount, 1);
      expect(feedback.generatedByLlm, isFalse);
      expect(feedback.recommendation, 'Keep both arms steady and long.');
    });
  });

  group('TemplateLlmFeedbackService', () {
    const template = TemplateLlmFeedbackService();

    test('never mentions the score, with and without errors', () async {
      final withError = await template.generateYogaFeedback(
        postureErrors: const [
          PostureError(
            code: 'left_arm_too_low',
            message: 'Raise your left arm toward shoulder height.',
            severity: PostureErrorSeverity.medium,
            measuredValue: 50,
            threshold: 75,
          ),
        ],
        poseName: 'Warrior II',
        score: 42,
      );
      final withoutError = await template.generateYogaFeedback(
        postureErrors: const [],
        poseName: 'Cobra',
        score: 97,
      );

      for (final feedback in [withError, withoutError]) {
        expect(feedback.recommendation.toLowerCase(), isNot(contains('score')));
        expect(feedback.recommendation, isNot(contains('42')));
        expect(feedback.recommendation, isNot(contains('97')));
      }
      expect(
        withError.recommendation,
        'Raise your left arm toward shoulder height and broaden across the chest.',
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
}
