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
      final result = evaluator.evaluatePose(
        pose: warriorTwoPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _warriorTwoArmVector,
          rightArmVector: _warriorTwoArmVector,
        ),
      );

      expect(result.score, 100);
      expect(result.errors, isEmpty);
    });

    test('returns green marker statuses for aligned Warrior II data', () {
      final markers = evaluator.evaluatePoseMarkers(
        pose: warriorTwoPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _warriorTwoArmVector,
          rightArmVector: _warriorTwoArmVector,
        ),
      );

      expect(
        _markerStatus(markers, PoseMarkerType.head),
        PoseMarkerStatus.good,
      );
      expect(
        _markerStatus(markers, PoseMarkerType.leftHand),
        PoseMarkerStatus.good,
      );
      expect(
        _markerStatus(markers, PoseMarkerType.rightHand),
        PoseMarkerStatus.good,
      );
    });

    test('returns red marker status for a clearly misaligned Warrior II hand',
        () {
      final markers = evaluator.evaluatePoseMarkers(
        pose: warriorTwoPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _armDownVector,
          rightArmVector: _warriorTwoArmVector,
        ),
      );

      expect(
        _markerStatus(markers, PoseMarkerType.leftHand),
        PoseMarkerStatus.bad,
      );
      expect(
        _markerStatus(markers, PoseMarkerType.rightHand),
        PoseMarkerStatus.good,
      );
    });

    test('returns gray marker statuses when live Warrior II data is missing',
        () {
      const emptyWindow = SensorWindow(
        earableAccelerometerSamples: [],
        earableGyroscopeSamples: [],
        ringAccelerometerSamplesByDeviceId: {},
        ringGyroscopeSamplesByDeviceId: {},
      );

      final markers = evaluator.evaluatePoseMarkers(
        pose: warriorTwoPose,
        calibration: calibration,
        poseWindow: emptyWindow,
      );

      expect(
        _markerStatus(markers, PoseMarkerType.head),
        PoseMarkerStatus.noData,
      );
      expect(
        _markerStatus(markers, PoseMarkerType.leftHand),
        PoseMarkerStatus.noData,
      );
      expect(
        _markerStatus(markers, PoseMarkerType.rightHand),
        PoseMarkerStatus.noData,
      );
    });

    test('scores a stable Chair window without errors', () {
      final result = evaluator.evaluatePose(
        pose: chairPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _overheadArmVector,
          rightArmVector: _overheadArmVector,
        ),
      );

      expect(result.score, 100);
      expect(result.errors, isEmpty);
    });

    test('scores a stable Triangle window without errors', () {
      final result = evaluator.evaluatePose(
        pose: trianglePose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _overheadArmVector,
          rightArmVector: _armDownVector,
        ),
      );

      expect(result.score, 100);
      expect(result.errors, isEmpty);
    });

    test('scores a stable Cobra window without errors', () {
      final result = evaluator.evaluatePose(
        pose: cobraPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          headVector: _cobraHeadLiftVector,
          leftArmVector: _armDownVector,
          rightArmVector: _armDownVector,
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

      expect(result.score, 38);
      expect(
        result.errors.map((error) => error.code),
        containsAll([
          'left_arm_too_low',
          'right_arm_too_low',
          'left_palm_not_rotated_down',
          'right_palm_not_rotated_down',
        ]),
      );
    });

    test('detects arms above shoulder height', () {
      final result = evaluator.evaluateWarriorTwo(
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: [0, 0.5, -0.8660254038],
          rightArmVector: _warriorTwoArmVector,
        ),
      );

      expect(
        result.errors.map((error) => error.code),
        contains('left_arm_too_high'),
      );
    });

    test('detects uneven hand height', () {
      final result = evaluator.evaluateWarriorTwo(
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _warriorTwoArmVector,
          rightArmVector: [0, 0.5, 0.8660254038],
        ),
      );

      expect(
        result.errors.map((error) => error.code),
        contains('left_arm_higher'),
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

      expect(result.score, 0);
      expect(
        result.errors.map((error) => error.code),
        containsAll([
          'left_ring_data_missing',
          'right_ring_data_missing',
          'no_sensor_data',
        ]),
      );
    });

    test('adds pose-specific stability errors for unstable gyro data', () {
      final result = evaluator.evaluatePose(
        pose: chairPose,
        calibration: calibration,
        poseWindow: _poseWindow(
          leftArmVector: _overheadArmVector,
          rightArmVector: _overheadArmVector,
          leftGyroVector: [160, 0, 0],
        ),
      );

      expect(
        result.errors.map((error) => error.code),
        contains('chair_unstable'),
      );
    });

    test('handles missing ring data for non-Warrior poses without crashing',
        () {
      const emptyWindow = SensorWindow(
        earableAccelerometerSamples: [],
        earableGyroscopeSamples: [],
        ringAccelerometerSamplesByDeviceId: {},
        ringGyroscopeSamplesByDeviceId: {},
      );

      final result = evaluator.evaluatePose(
        pose: trianglePose,
        calibration: calibration,
        poseWindow: emptyWindow,
      );

      expect(result.score, 0);
      expect(
        result.errors.map((error) => error.code),
        containsAll([
          'triangle_left_ring_data_missing',
          'triangle_right_ring_data_missing',
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

    test('rejects calibration windows with too much movement', () {
      const movingBaseline = SensorWindow(
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
            values: [100, 0, 0],
          ),
        ],
        ringAccelerometerSamplesByDeviceId: {},
        ringGyroscopeSamplesByDeviceId: {},
      );

      final errors = evaluator.evaluateCalibrationStability(
        baselineWindow: movingBaseline,
        ringAssignment: const RingAssignment(
          leftRingId: leftRingId,
          rightRingId: rightRingId,
        ),
      );

      expect(errors, hasLength(1));
      expect(errors.single.code, 'calibration_head_moving');
    });
  });
}

const List<double> _warriorTwoArmVector = [0.0, 1.0, 0.0];
const List<double> _overheadArmVector = [0.0, 0.0, -1.0];
const List<double> _armDownVector = [0.0, 0.0, 1.0];
const List<double> _cobraHeadLiftVector = [-0.5, 0.0, 0.8660254038];

SensorWindow _poseWindow({
  List<double> headVector = _armDownVector,
  required List<double> leftArmVector,
  required List<double> rightArmVector,
  List<double> headGyroVector = const [0, 0, 0],
  List<double> leftGyroVector = const [0, 0, 0],
  List<double> rightGyroVector = const [0, 0, 0],
}) {
  return SensorWindow(
    earableAccelerometerSamples: [
      ImuSample(
        deviceId: 'earable',
        deviceName: 'OpenEarable',
        sensorName: 'accelerometer',
        timestamp: 2,
        values: headVector,
      ),
    ],
    earableGyroscopeSamples: [
      ImuSample(
        deviceId: 'earable',
        deviceName: 'OpenEarable',
        sensorName: 'gyroscope',
        timestamp: 2,
        values: headGyroVector,
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
    ringGyroscopeSamplesByDeviceId: {
      'left-ring': [
        ImuSample(
          deviceId: 'left-ring',
          deviceName: 'OpenRing L',
          sensorName: 'gyroscope',
          timestamp: 2,
          values: leftGyroVector,
        ),
      ],
      'right-ring': [
        ImuSample(
          deviceId: 'right-ring',
          deviceName: 'OpenRing R',
          sensorName: 'gyroscope',
          timestamp: 2,
          values: rightGyroVector,
        ),
      ],
    },
  );
}

PoseMarkerStatus _markerStatus(
  List<PoseMarkerFeedback> markers,
  PoseMarkerType type,
) {
  return markers.singleWhere((marker) => marker.type == type).status;
}
