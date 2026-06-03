import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

void main() {
  group('Yoga pose catalog', () {
    test('keeps the requested 2x2 selection order', () {
      expect(
        yogaPostureTrackerPoses.map((pose) => pose.imageAsset),
        [
          'lib/apps/yoga_posture_tracker/assets/warrior_ii_pose2.png',
          'lib/apps/yoga_posture_tracker/assets/triangle_pose.png',
          'lib/apps/yoga_posture_tracker/assets/chair_pose.png',
          'lib/apps/yoga_posture_tracker/assets/cobra_pose.png',
        ],
      );
    });

    test('makes all catalog poses available for evaluation', () {
      expect(
        yogaPostureTrackerPoses.every((pose) => pose.isEvaluationAvailable),
        isTrue,
      );
    });

    test('exposes difficulty labels for the pose selection cards', () {
      expect(
        yogaPostureTrackerPoses.map((pose) => pose.difficulty.label),
        [
          'Intermediate',
          'Intermediate',
          'Beginner',
          'Beginner',
        ],
      );
    });
  });

  group('RingAssignment', () {
    test('swaps rings when assigning the right ring to the left hand', () {
      const assignment = RingAssignment(
        leftRingId: 'left-ring',
        rightRingId: 'right-ring',
      );

      final updated = assignment.assignLeftRing('right-ring');

      expect(updated.leftRingId, 'right-ring');
      expect(updated.rightRingId, 'left-ring');
      expect(updated.isValid, isTrue);
    });

    test('swaps rings when assigning the left ring to the right hand', () {
      const assignment = RingAssignment(
        leftRingId: 'left-ring',
        rightRingId: 'right-ring',
      );

      final updated = assignment.assignRightRing('left-ring');

      expect(updated.leftRingId, 'right-ring');
      expect(updated.rightRingId, 'left-ring');
      expect(updated.isValid, isTrue);
    });
  });
}
