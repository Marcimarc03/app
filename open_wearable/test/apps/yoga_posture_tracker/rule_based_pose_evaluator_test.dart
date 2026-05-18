import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/rule_based_pose_evaluator.dart';

void main() {
  group('RuleBasedPoseEvaluator', () {
    const evaluator = RuleBasedPoseEvaluator();
    const leftRingId = 'left-ring';
    const rightRingId = 'right-ring';
    const calibration = CalibrationData(
      baselineWindow: SensorWindow(
        earableAccelerometerSamples: [
          ImuSample(
            deviceId: 'earable',
            deviceName: 'OpenEarable',
            sensorName: 'accelerometer',
            timestamp: 1,
            values: [0, 0, 1],
          ),
        ],
        earableGyroscopeSamples: [
          ImuSample(
            deviceId: 'earable',
            deviceName: 'OpenEarable',
            sensorName: 'gyroscope',
            timestamp: 1,
            values: [0, 0, 0],
          ),
        ],
        ringAccelerometerSamplesByDeviceId: {
          leftRingId: [
            ImuSample(
              deviceId: leftRingId,
              deviceName: 'OpenRing L',
              sensorName: 'accelerometer',
              timestamp: 1,
              values: [0, 0, 1],
            ),
          ],
          rightRingId: [
            ImuSample(
              deviceId: rightRingId,
              deviceName: 'OpenRing R',
              sensorName: 'accelerometer',
              timestamp: 1,
              values: [0, 0, 1],
            ),
          ],
        },
        ringGyroscopeSamplesByDeviceId: {
          leftRingId: [
            ImuSample(
              deviceId: leftRingId,
              deviceName: 'OpenRing L',
              sensorName: 'gyroscope',
              timestamp: 1,
              values: [0, 0, 0],
            ),
          ],
          rightRingId: [
            ImuSample(
              deviceId: rightRingId,
              deviceName: 'OpenRing R',
              sensorName: 'gyroscope',
              timestamp: 1,
              values: [0, 0, 0],
            ),
          ],
        },
      ),
      ringAssignment: RingAssignment(
        leftRingId: leftRingId,
        rightRingId: rightRingId,
      ),
    );

    test('scores a stable Warrior II window without errors', () {
      final result = evaluator.evaluateWarriorTwo(
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _sixtyDegreePitchVector,
          rightArmVector: _sixtyDegreePitchVector,
        ),
      );

      expect(result.score, 100);
      expect(result.errors, isEmpty);
    });

    test('detects both arms as too low', () {
      final result = evaluator.evaluateWarriorTwo(
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: [0, 0, 1],
          rightArmVector: [0, 0, 1],
        ),
      );

      expect(result.score, 60);
      expect(
        result.errors.map((error) => error.code),
        containsAll(['left_arm_too_low', 'right_arm_too_low']),
      );
    });

    test('detects missing live sensor data', () {
      const emptyWindow = SensorWindow(
        earableAccelerometerSamples: [],
        earableGyroscopeSamples: [],
        ringAccelerometerSamplesByDeviceId: {},
        ringGyroscopeSamplesByDeviceId: {},
      );

      final result = evaluator.evaluateWarriorTwo(
        calibration: calibration,
        poseWindow: emptyWindow,
      );

      expect(result.score, 10);
      expect(
        result.errors.map((error) => error.code),
        containsAll([
          'left_ring_data_missing',
          'right_ring_data_missing',
          'no_sensor_data',
        ]),
      );
    });

    test('aggregates scores and error occurrence counts across windows', () {
      const headTilt = PostureError(
        code: 'head_tilted',
        message: 'Your head is tilted too far from the calibrated neutral.',
        severity: PostureErrorSeverity.medium,
        measuredValue: 24,
        threshold: 20,
      );
      const severeHeadTilt = PostureError(
        code: 'head_tilted',
        message: 'Your head is tilted too far from the calibrated neutral.',
        severity: PostureErrorSeverity.severe,
        measuredValue: 38,
        threshold: 20,
      );

      final result = evaluator.aggregateWindowResults(
        const [
          PoseEvaluationResult(score: 100, errors: []),
          PoseEvaluationResult(score: 80, errors: [headTilt]),
          PoseEvaluationResult(score: 70, errors: [severeHeadTilt]),
        ],
      );

      expect(result.score, 83);
      expect(result.errors, hasLength(1));
      expect(result.errors.single.code, 'head_tilted');
      expect(result.errors.single.severity, PostureErrorSeverity.severe);
      expect(result.errors.single.occurrenceCount, 2);
      expect(result.errors.single.evaluatedWindowCount, 3);
      expect(result.errors.single.measuredValue, 31);
    });
  });
}

const List<double> _sixtyDegreePitchVector = [-0.8660254038, 0.0, 0.5];

SensorWindow _poseWindow({
  required List<double> leftArmVector,
  required List<double> rightArmVector,
}) {
  return SensorWindow(
    earableAccelerometerSamples: const [
      ImuSample(
        deviceId: 'earable',
        deviceName: 'OpenEarable',
        sensorName: 'accelerometer',
        timestamp: 2,
        values: [0, 0, 1],
      ),
    ],
    earableGyroscopeSamples: const [
      ImuSample(
        deviceId: 'earable',
        deviceName: 'OpenEarable',
        sensorName: 'gyroscope',
        timestamp: 2,
        values: [0, 0, 0],
      ),
    ],
    ringAccelerometerSamplesByDeviceId: {
      'left-ring': [
        ImuSample(
          deviceId: 'left-ring',
          deviceName: 'OpenRing L',
          sensorName: 'accelerometer',
          timestamp: 2,
          values: leftArmVector,
        ),
      ],
      'right-ring': [
        ImuSample(
          deviceId: 'right-ring',
          deviceName: 'OpenRing R',
          sensorName: 'accelerometer',
          timestamp: 2,
          values: rightArmVector,
        ),
      ],
    },
    ringGyroscopeSamplesByDeviceId: const {
      'left-ring': [
        ImuSample(
          deviceId: 'left-ring',
          deviceName: 'OpenRing L',
          sensorName: 'gyroscope',
          timestamp: 2,
          values: [0, 0, 0],
        ),
      ],
      'right-ring': [
        ImuSample(
          deviceId: 'right-ring',
          deviceName: 'OpenRing R',
          sensorName: 'gyroscope',
          timestamp: 2,
          values: [0, 0, 0],
        ),
      ],
    },
  );
}
