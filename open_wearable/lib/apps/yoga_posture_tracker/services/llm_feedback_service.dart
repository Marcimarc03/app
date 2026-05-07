import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

abstract class LlmFeedbackService {
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  });
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
