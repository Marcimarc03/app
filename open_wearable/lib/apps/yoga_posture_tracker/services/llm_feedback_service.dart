import 'dart:convert';

import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:http/http.dart' as http;

abstract class LlmFeedbackService {
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  });
}

class GeminiLlmFeedbackService implements LlmFeedbackService {
  static const String _apiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  static const String _model = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );

  final LlmFeedbackService fallback;
  final http.Client _client;

  GeminiLlmFeedbackService({
    this.fallback = const TemplateLlmFeedbackService(),
    http.Client? client,
  }) : _client = client ?? http.Client();

  bool get isConfigured => _apiKey.trim().isNotEmpty;

  @override
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  }) async {
    if (!isConfigured) {
      return fallback.generateYogaFeedback(
        postureErrors: postureErrors,
        poseName: poseName,
        score: score,
      );
    }

    try {
      final uri = Uri.https(
        'generativelanguage.googleapis.com',
        '/v1beta/models/$_model:generateContent',
      );
      final response = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': _apiKey,
        },
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {
                'text':
                    'You are a calm, precise yoga instructor. Give one short spoken coaching cue for the current Warrior II posture. Mention only actionable corrections, stay friendly, and do not mention sensors or scores unless asked.',
              },
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'text': _buildPrompt(
                    postureErrors: postureErrors,
                    poseName: poseName,
                    score: score,
                  ),
                },
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.4,
            'maxOutputTokens': 80,
          },
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        logger.w(
          'Gemini yoga feedback failed with HTTP ${response.statusCode}: '
          '${response.body}',
        );
        return fallback.generateYogaFeedback(
          postureErrors: postureErrors,
          poseName: poseName,
          score: score,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final text = _extractText(decoded);
      if (text == null || text.trim().isEmpty) {
        logger.w('Gemini yoga feedback response did not contain text.');
        return fallback.generateYogaFeedback(
          postureErrors: postureErrors,
          poseName: poseName,
          score: score,
        );
      }

      return YogaFeedback(
        recommendation: text.trim(),
        generatedByLlm: true,
      );
    } catch (error, stackTrace) {
      logger.w(
        'Gemini yoga feedback failed, using template fallback.',
        error: error,
        stackTrace: stackTrace,
      );
      return fallback.generateYogaFeedback(
        postureErrors: postureErrors,
        poseName: poseName,
        score: score,
      );
    }
  }

  String _buildPrompt({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  }) {
    final issues = postureErrors.isEmpty
        ? 'No posture issues were detected.'
        : postureErrors
            .map(
              (error) => '- ${error.code}: ${error.message} '
                  '(severity: ${error.severity.name})',
            )
            .join('\n');
    return '''
Pose: $poseName
Current score: $score out of 100
Detected issues:
$issues

Write exactly one natural coaching cue that can be spoken while the student is still holding the pose.
''';
  }

  String? _extractText(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return null;
    }
    final first = candidates.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final content = first['content'];
    if (content is! Map<String, dynamic>) {
      return null;
    }
    final parts = content['parts'];
    if (parts is! List) {
      return null;
    }
    final texts = parts
        .whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .toList();
    if (texts.isEmpty) {
      return null;
    }
    return texts.join(' ');
  }
}

class TemplateLlmFeedbackService implements LlmFeedbackService {
  const TemplateLlmFeedbackService();

  @override
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  }) async {
    if (postureErrors.isEmpty) {
      return YogaFeedback(
        recommendation:
            'Excellent work in $poseName. Keep your breath steady and hold the same calm alignment.',
      );
    }

    final primary = postureErrors.first;
    final cue = switch (primary.code) {
      'left_arm_too_low' =>
        'Raise your left arm toward shoulder height and broaden across the chest.',
      'right_arm_too_low' =>
        'Raise your right arm toward shoulder height and keep both arms active.',
      'left_arm_unstable' =>
        'Soften your left shoulder, reach through the fingertips, and reduce small movements.',
      'right_arm_unstable' =>
        'Soften your right shoulder, reach through the fingertips, and reduce small movements.',
      'head_tilted' =>
        'Bring your head back to neutral and let your gaze follow the front hand.',
      'head_unstable' =>
        'Keep your neck long and make the head position quiet and steady.',
      'left_ring_data_missing' =>
        'Check the left ring connection, then repeat the hold so your left arm can be assessed.',
      'right_ring_data_missing' =>
        'Check the right ring connection, then repeat the hold so your right arm can be assessed.',
      'no_sensor_data' =>
        'Check sensor streaming, then repeat the pose with the devices connected.',
      _ => 'Adjust the highlighted alignment point and repeat the hold calmly.',
    };

    return YogaFeedback(
      recommendation: '$cue Your current $poseName score is $score.',
    );
  }
}
