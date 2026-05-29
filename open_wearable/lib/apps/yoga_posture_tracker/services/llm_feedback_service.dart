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

  Future<YogaFeedback> generatePoseSetupInstruction({
    required String poseName,
  });
}

class GeminiLlmFeedbackService implements LlmFeedbackService {
  static const String _environmentApiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  static const String _environmentModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );
  static const int _maxOutputTokens = 96;

  final LlmFeedbackService fallback;
  final http.Client _client;
  final String _apiKey;
  final String _model;

  GeminiLlmFeedbackService({
    this.fallback = const TemplateLlmFeedbackService(),
    http.Client? client,
    String? apiKey,
    String? model,
  })  : _client = client ?? http.Client(),
        _apiKey = apiKey ?? _environmentApiKey,
        _model = model ?? _environmentModel;

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
      final text = await _generateContent(
        systemInstruction:
            'You are a calm, precise yoga instructor giving real-time spoken corrections during Warrior II. Return one complete TTS-ready sentence only.',
        prompt: _buildLiveFeedbackPrompt(
          postureErrors: postureErrors,
          poseName: poseName,
          score: score,
        ),
        temperature: 0.35,
        maxOutputTokens: _maxOutputTokens,
      );
      final cue = text == null ? null : _completeSpokenCue(text);
      if (cue == null) {
        logger.w(
          'Gemini yoga feedback response was empty or incomplete: '
          '${text ?? '<no text>'}',
        );
        return fallback.generateYogaFeedback(
          postureErrors: postureErrors,
          poseName: poseName,
          score: score,
        );
      }

      return YogaFeedback(
        recommendation: cue,
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

  @override
  Future<YogaFeedback> generatePoseSetupInstruction({
    required String poseName,
  }) async {
    if (!isConfigured) {
      return fallback.generatePoseSetupInstruction(poseName: poseName);
    }

    try {
      final text = await _generateContent(
        systemInstruction:
            'You are a calm yoga instructor giving a short spoken setup cue before a student enters a pose. Stay concrete, gentle, and concise.',
        prompt: _buildPoseSetupPrompt(poseName),
        temperature: 0.3,
        maxOutputTokens: _maxOutputTokens,
      );
      final cue = text == null
          ? null
          : _completeSpokenCue(
              text,
              minimumWordCount: 8,
            );
      if (cue == null) {
        logger.w(
          'Gemini pose setup response was empty or incomplete: '
          '${text ?? '<no text>'}',
        );
        return fallback.generatePoseSetupInstruction(poseName: poseName);
      }

      return YogaFeedback(
        recommendation: cue,
        generatedByLlm: true,
      );
    } catch (error, stackTrace) {
      logger.w(
        'Gemini pose setup failed, using template fallback.',
        error: error,
        stackTrace: stackTrace,
      );
      return fallback.generatePoseSetupInstruction(poseName: poseName);
    }
  }

  Future<String?> _generateContent({
    required String systemInstruction,
    required String prompt,
    required double temperature,
    required int maxOutputTokens,
  }) async {
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
            {'text': systemInstruction},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': temperature,
          'maxOutputTokens': maxOutputTokens,
        },
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      logger.w(
        'Gemini yoga feedback failed with HTTP ${response.statusCode}: '
        '${response.body}',
      );
      return null;
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return _extractText(decoded);
  }

  String _buildLiveFeedbackPrompt({
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

Write one natural coaching cue that can be spoken while the student is still holding the pose.
Use the detected issues to choose the most important correction.

Good examples:
- "Lift both arms to shoulder height and rotate your palms toward the floor."
- "Lower your left hand slightly so both arms form one steady line."

Bad examples:
- "Lift both"
- "Gently"

Constraints:
- one complete sentence only
- 8 to 20 words
- end with a period
- no markdown
- no emojis
- do not mention sensors, IMU, API, score, or device data
''';
  }

  String _buildPoseSetupPrompt(String poseName) {
    final poseSetupDetails = switch (poseName) {
      'Warrior II' =>
        'For Warrior II, cue a wide stance, arms at shoulder height, a softly bent front knee, long back leg, and gaze over the front hand.',
      'Triangle' =>
        'For Triangle, cue a wide stance, one hand reaching toward the front leg, the other arm upward, and a long controlled neck.',
      'Chair' =>
        'For Chair, cue bent knees, hips sitting back, lifted chest, and both arms reaching upward.',
      'Cobra' =>
        'For Cobra, cue hands beside the ribs, a gentle head and chest lift, relaxed shoulders, and steady hands.',
      _ =>
        'Cue the main setup points for the selected yoga pose using only observable, practical alignment language.',
    };
    return '''
Pose: $poseName

Give one short spoken instruction for entering and setting up this yoga pose before the timed hold starts.
$poseSetupDetails

Good example:
"Step into a wide stance, raise your arms to shoulder height, bend your front knee softly, and gaze over your front hand."

Bad examples:
- "Warrior II setup"
- "Take the pose"

Constraints:
- one complete sentence only
- 16 to 32 words
- end with a period
- no markdown
- no emojis
- do not mention sensors, IMU, API, score, or device data
- do not give medical advice
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

  String? _completeSpokenCue(
    String text, {
    int minimumWordCount = 4,
  }) {
    var cue = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cue.isEmpty) {
      return null;
    }

    cue = cue
        .replaceFirst(RegExp('^\\s*(?:[-*]|\\u2022|\\d+[.)])\\s*'), '')
        .trim();
    cue = cue.replaceAll(RegExp(r'^"+|"+$'), '').trim();
    if (cue.isEmpty) {
      return null;
    }

    final firstSentence = RegExp(r'^[^.!?]+[.!?]').firstMatch(cue);
    if (firstSentence != null) {
      cue = firstSentence.group(0)!.trim();
    }

    final wordCount = RegExp(r"[A-Za-z0-9']+").allMatches(cue).length;
    if (wordCount < minimumWordCount) {
      return null;
    }

    if (!RegExp(r'[.!?]$').hasMatch(cue)) {
      cue = '$cue.';
    }
    return cue;
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
            'Based on your head and hand positions, $poseName looks stable. Keep your breath steady.',
      );
    }

    final primary = postureErrors.first;
    final cue = switch (primary.code) {
      'left_arm_too_low' =>
        'Raise your left arm toward shoulder height and broaden across the chest.',
      'right_arm_too_low' =>
        'Raise your right arm toward shoulder height and keep both arms active.',
      'left_arm_too_high' =>
        'Lower your left arm slightly until both hands are near shoulder height.',
      'right_arm_too_high' =>
        'Lower your right arm slightly until both hands are near shoulder height.',
      'left_arm_higher' =>
        'Lower your left hand slightly so both arms form one steady line.',
      'right_arm_higher' =>
        'Lower your right hand slightly so both arms form one steady line.',
      'left_palm_not_rotated_down' =>
        'Rotate your left palm more toward the floor while keeping the arm long.',
      'right_palm_not_rotated_down' =>
        'Rotate your right palm more toward the floor while keeping the arm long.',
      'left_palm_over_rotated' =>
        'Turn your left palm gently back toward the floor.',
      'right_palm_over_rotated' =>
        'Turn your right palm gently back toward the floor.',
      'left_arm_unstable' =>
        'Soften your left shoulder, reach through the fingertips, and reduce small movements.',
      'right_arm_unstable' =>
        'Soften your right shoulder, reach through the fingertips, and reduce small movements.',
      'head_pitch_tilted' =>
        'Bring your head level and keep your gaze calm over the front hand.',
      'head_roll_tilted' =>
        'Keep your head upright without tilting it to the side.',
      'head_unstable' =>
        'Keep your neck long and make the head position quiet and steady.',
      'chair_left_arm_too_low' => 'Raise your left arm further overhead.',
      'chair_right_arm_too_low' => 'Raise your right arm further overhead.',
      'chair_arms_uneven' => 'Keep both arms at the same height.',
      'chair_hands_asymmetric' => 'Keep your arms steady and symmetrical.',
      'chair_head_tilted' => 'Keep your head straight and your gaze forward.',
      'chair_unstable' =>
        'Hold the pose more steadily, and also sit your hips back.',
      'triangle_upper_arm_too_low' => 'Stretch your upper arm further upward.',
      'triangle_lower_arm_too_high' =>
        'Move your lower hand closer toward your leg or the floor.',
      'triangle_arm_line_unclear' =>
        'Stretch both arms in opposite directions.',
      'triangle_head_uncontrolled' => 'Keep your neck long and controlled.',
      'triangle_unstable' => 'Hold the pose more steadily.',
      'cobra_head_not_lifted' => 'Lift your head and chest slightly more.',
      'cobra_head_overextended' =>
        'Avoid pushing your head too far into the neck.',
      'cobra_head_tilted' => 'Keep your head centered.',
      'cobra_hands_asymmetric' =>
        'Distribute your weight evenly on both hands.',
      'cobra_unstable' => 'Keep your hands steady on the floor.',
      'left_ring_data_missing' =>
        'Check the left ring connection, then repeat the hold so your left arm can be assessed.',
      'right_ring_data_missing' =>
        'Check the right ring connection, then repeat the hold so your right arm can be assessed.',
      'no_sensor_data' =>
        'Check sensor streaming, then repeat the pose with the devices connected.',
      _ => '${primary.message} Repeat the hold calmly.',
    };

    return YogaFeedback(
      recommendation: '$cue Your current $poseName score is $score.',
    );
  }

  @override
  Future<YogaFeedback> generatePoseSetupInstruction({
    required String poseName,
  }) async {
    if (poseName == warriorTwoPose.name) {
      return YogaFeedback(recommendation: warriorTwoPose.instruction);
    }
    if (poseName == trianglePose.name) {
      return YogaFeedback(recommendation: trianglePose.instruction);
    }
    if (poseName == chairPose.name) {
      return YogaFeedback(recommendation: chairPose.instruction);
    }
    if (poseName == cobraPose.name) {
      return YogaFeedback(recommendation: cobraPose.instruction);
    }

    return YogaFeedback(
      recommendation:
          'Set up $poseName with steady breath, clear alignment, and a calm gaze before starting the hold.',
    );
  }
}
