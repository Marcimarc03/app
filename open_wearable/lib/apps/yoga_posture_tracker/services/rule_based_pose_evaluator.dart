import 'dart:math';

import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_math.dart';

class RuleBasedPoseEvaluator {
  static const double _armElevationWeight = 15;
  static const double _armHeightSymmetryWeight = 15;
  static const double _palmRotationWeight = 10;
  static const double _headPitchWeight = 5;
  static const double _headRollWeight = 5;
  static const double _stabilityWeight = 5;
  static const double _measurableScoreTotal = 80;

  const RuleBasedPoseEvaluator();

  PoseEvaluationResult evaluateWarriorTwo({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    final errors = <PostureError>[];
    var earnedScore = 0.0;

    earnedScore += _evaluateHeadNeutral(calibration, poseWindow, errors);
    final headStable = _evaluateHeadStability(poseWindow, errors);

    final leftArm = _evaluateRingArm(
      side: 'left',
      ringId: calibration.ringAssignment.leftRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
    );
    if (leftArm != null) {
      earnedScore += leftArm.elevationScore + leftArm.palmRotationScore;
    }

    final rightArm = _evaluateRingArm(
      side: 'right',
      ringId: calibration.ringAssignment.rightRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
    );
    if (rightArm != null) {
      earnedScore += rightArm.elevationScore + rightArm.palmRotationScore;
    }

    if (leftArm != null && rightArm != null) {
      earnedScore += _evaluateArmHeightSymmetry(
        leftArm: leftArm,
        rightArm: rightArm,
        errors: errors,
      );
    }

    if (headStable &&
        (leftArm?.isStable ?? false) &&
        (rightArm?.isStable ?? false)) {
      earnedScore += _stabilityWeight;
    }

    if (poseWindow.totalSampleCount == 0) {
      errors.add(
        const PostureError(
          code: 'no_sensor_data',
          message: 'No live IMU samples were collected during the pose hold.',
          severity: PostureErrorSeverity.severe,
          measuredValue: 0,
          threshold: 1,
        ),
      );
    }

    final score = max(
      0,
      min(100, (earnedScore / _measurableScoreTotal * 100).round()),
    );

    return PoseEvaluationResult(score: score, errors: errors);
  }

  List<PostureError> evaluateCalibrationStability({
    required SensorWindow baselineWindow,
    required RingAssignment ringAssignment,
  }) {
    final errors = <PostureError>[];
    _evaluateCalibrationGyro(
      code: 'calibration_head_moving',
      message:
          'Too much head movement was detected during calibration. Please stand still and recalibrate.',
      samples: baselineWindow.earableGyroscopeSamples,
      errors: errors,
    );
    _evaluateCalibrationRing(
      side: 'left',
      ringId: ringAssignment.leftRingId,
      baselineWindow: baselineWindow,
      errors: errors,
    );
    _evaluateCalibrationRing(
      side: 'right',
      ringId: ringAssignment.rightRingId,
      baselineWindow: baselineWindow,
      errors: errors,
    );
    return errors;
  }

  PoseEvaluationResult aggregateWindowResults(
    List<PoseEvaluationResult> results,
  ) {
    if (results.isEmpty) {
      return const PoseEvaluationResult(
        score: 0,
        errors: [
          PostureError(
            code: 'no_sensor_windows',
            message: 'No pose windows were available for final scoring.',
            severity: PostureErrorSeverity.severe,
            measuredValue: 0,
            threshold: 1,
          ),
        ],
      );
    }

    final score = max(
      0,
      min(
        100,
        (results.fold<int>(0, (total, result) => total + result.score) /
                results.length)
            .round(),
      ),
    );

    final groupedErrors = <String, List<PostureError>>{};
    for (final result in results) {
      for (final error in result.errors) {
        groupedErrors.putIfAbsent(error.code, () => []).add(error);
      }
    }

    final errors = groupedErrors.entries.map((entry) {
      return _aggregateError(
        errors: entry.value,
        evaluatedWindowCount: results.length,
      );
    }).toList()
      ..sort((a, b) {
        final occurrenceCompare = b.occurrenceCount.compareTo(
          a.occurrenceCount,
        );
        if (occurrenceCompare != 0) {
          return occurrenceCompare;
        }
        final severityCompare = _severityRank(b.severity).compareTo(
          _severityRank(a.severity),
        );
        if (severityCompare != 0) {
          return severityCompare;
        }
        return a.code.compareTo(b.code);
      });

    return PoseEvaluationResult(score: score, errors: errors);
  }

  double _evaluateHeadNeutral(
    CalibrationData calibration,
    SensorWindow poseWindow,
    List<PostureError> errors,
  ) {
    final baselineMean = _baselineMean(
      calibration: calibration,
      key: SensorStartOrientation.earableAccelerometerKey,
      fallbackSamples: calibration.baselineWindow.earableAccelerometerSamples,
    );
    final poseStats = vectorStats(poseWindow.earableAccelerometerSamples);
    if (baselineMean.isEmpty || !poseStats.hasData) {
      return 0;
    }

    final delta = orientationDeltaDegrees(
      baselineMean: baselineMean,
      poseMean: poseStats.mean,
    );
    final pitch = delta.pitch.abs();
    final roll = delta.roll.abs();

    final pitchScore = _absoluteThresholdScore(
      value: pitch,
      perfectMax: YogaPostureTrackerThresholds.headPitchRollPerfectDegrees,
      goodMax: YogaPostureTrackerThresholds.headPitchRollGoodDegrees,
      weight: _headPitchWeight,
    );
    final rollScore = _absoluteThresholdScore(
      value: roll,
      perfectMax: YogaPostureTrackerThresholds.headPitchRollPerfectDegrees,
      goodMax: YogaPostureTrackerThresholds.headPitchRollGoodDegrees,
      weight: _headRollWeight,
    );

    if (pitch > YogaPostureTrackerThresholds.headPitchRollGoodDegrees) {
      errors.add(
        PostureError(
          code: 'head_pitch_tilted',
          message:
              'Keep your head level instead of nodding up or down in Warrior II.',
          severity: pitch > 20
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: pitch,
          threshold: YogaPostureTrackerThresholds.headPitchRollGoodDegrees,
        ),
      );
    }
    if (roll > YogaPostureTrackerThresholds.headPitchRollGoodDegrees) {
      errors.add(
        PostureError(
          code: 'head_roll_tilted',
          message: 'Keep your head upright instead of tilting it to the side.',
          severity: roll > 20
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: roll,
          threshold: YogaPostureTrackerThresholds.headPitchRollGoodDegrees,
        ),
      );
    }

    return pitchScore + rollScore;
  }

  void _evaluateCalibrationRing({
    required String side,
    required String? ringId,
    required SensorWindow baselineWindow,
    required List<PostureError> errors,
  }) {
    if (ringId == null) {
      return;
    }
    _evaluateCalibrationGyro(
      code: 'calibration_${side}_ring_moving',
      message:
          'Too much $side hand movement was detected during calibration. Please stand still and recalibrate.',
      samples: baselineWindow.ringGyroscopeSamplesFor(ringId),
      errors: errors,
    );
  }

  void _evaluateCalibrationGyro({
    required String code,
    required String message,
    required List<ImuSample> samples,
    required List<PostureError> errors,
  }) {
    final gyroStats = vectorStats(samples);
    if (!gyroStats.hasData) {
      return;
    }
    if (gyroStats.meanMagnitude >
        YogaPostureTrackerThresholds.calibrationGyroInstability) {
      errors.add(
        PostureError(
          code: code,
          message: message,
          severity: PostureErrorSeverity.medium,
          measuredValue: gyroStats.meanMagnitude,
          threshold: YogaPostureTrackerThresholds.calibrationGyroInstability,
        ),
      );
    }
  }

  PostureError _aggregateError({
    required List<PostureError> errors,
    required int evaluatedWindowCount,
  }) {
    final first = errors.first;
    final worst = errors.reduce(
      (current, next) =>
          _severityRank(next.severity) > _severityRank(current.severity)
              ? next
              : current,
    );
    final measuredAverage =
        errors.fold<double>(0, (total, error) => total + error.measuredValue) /
            errors.length;

    return PostureError(
      code: first.code,
      message: first.message,
      severity: worst.severity,
      measuredValue: measuredAverage,
      threshold: first.threshold,
      occurrenceCount: errors.length,
      evaluatedWindowCount: evaluatedWindowCount,
    );
  }

  int _severityRank(PostureErrorSeverity severity) {
    return switch (severity) {
      PostureErrorSeverity.minor => 1,
      PostureErrorSeverity.medium => 2,
      PostureErrorSeverity.severe => 3,
    };
  }

  bool _evaluateHeadStability(
    SensorWindow poseWindow,
    List<PostureError> errors,
  ) {
    return _evaluateGyroStability(
      code: 'head_unstable',
      message: 'Your head is moving too much during the hold.',
      samples: poseWindow.earableGyroscopeSamples,
      threshold: YogaPostureTrackerThresholds.headGyroInstability,
      errors: errors,
    );
  }

  _ArmPoseMetrics? _evaluateRingArm({
    required String side,
    required String? ringId,
    required CalibrationData calibration,
    required SensorWindow poseWindow,
    required List<PostureError> errors,
  }) {
    if (ringId == null) {
      errors.add(
        PostureError(
          code: '${side}_ring_data_missing',
          message: 'No $side ring was assigned for arm scoring.',
          severity: PostureErrorSeverity.severe,
          measuredValue: 0,
          threshold: 1,
        ),
      );
      return null;
    }

    final baselineMean = _baselineMean(
      calibration: calibration,
      key: SensorStartOrientation.ringAccelerometerKey(ringId),
      fallbackSamples:
          calibration.baselineWindow.ringAccelerometerSamplesFor(ringId),
    );
    final poseSamples = poseWindow.ringAccelerometerSamplesFor(ringId);
    final poseStats = vectorStats(poseSamples);
    if (baselineMean.isEmpty || !poseStats.hasData) {
      errors.add(
        PostureError(
          code: '${side}_ring_data_missing',
          message: 'No accelerometer data was available for the $side ring.',
          severity: PostureErrorSeverity.severe,
          measuredValue: 0,
          threshold: 1,
        ),
      );
      return null;
    }

    final elevationDegrees = angleBetweenVectorsDegrees(
      baselineMean,
      poseStats.mean,
    );
    final elevationScore = _rangeScore(
      value: elevationDegrees,
      perfectMin: YogaPostureTrackerThresholds.armElevationPerfectMinDegrees,
      perfectMax: YogaPostureTrackerThresholds.armElevationPerfectMaxDegrees,
      goodMin: YogaPostureTrackerThresholds.armElevationGoodMinDegrees,
      goodMax: YogaPostureTrackerThresholds.armElevationGoodMaxDegrees,
      weight: _armElevationWeight,
    );
    _addArmElevationErrors(
      side: side,
      elevationDegrees: elevationDegrees,
      errors: errors,
    );

    // Palm rotation is a ring-roll proxy relative to the calibrated hand pose.
    // With only hand-mounted rings this is still not an anatomical wrist model,
    // but it avoids evaluating absolute world angles.
    final palmRotationDegrees = orientationDeltaDegrees(
      baselineMean: baselineMean,
      poseMean: poseStats.mean,
    ).roll.abs();
    final palmRotationScore = _rangeScore(
      value: palmRotationDegrees,
      perfectMin: YogaPostureTrackerThresholds.palmRotationPerfectMinDegrees,
      perfectMax: YogaPostureTrackerThresholds.palmRotationPerfectMaxDegrees,
      goodMin: YogaPostureTrackerThresholds.palmRotationGoodMinDegrees,
      goodMax: YogaPostureTrackerThresholds.palmRotationGoodMaxDegrees,
      weight: _palmRotationWeight,
    );
    _addPalmRotationErrors(
      side: side,
      palmRotationDegrees: palmRotationDegrees,
      errors: errors,
    );

    final isStable = _evaluateArmStability(
      side: side,
      ringId: ringId,
      poseWindow: poseWindow,
      errors: errors,
    );

    return _ArmPoseMetrics(
      elevationDegrees: elevationDegrees,
      elevationScore: elevationScore,
      palmRotationScore: palmRotationScore,
      isStable: isStable,
    );
  }

  void _addArmElevationErrors({
    required String side,
    required double elevationDegrees,
    required List<PostureError> errors,
  }) {
    if (elevationDegrees <
        YogaPostureTrackerThresholds.armElevationGoodMinDegrees) {
      errors.add(
        PostureError(
          code: '${side}_arm_too_low',
          message: 'Raise your $side arm toward shoulder height.',
          severity: elevationDegrees < 70
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: elevationDegrees,
          threshold: YogaPostureTrackerThresholds.armElevationGoodMinDegrees,
        ),
      );
      return;
    }
    if (elevationDegrees >
        YogaPostureTrackerThresholds.armElevationGoodMaxDegrees) {
      errors.add(
        PostureError(
          code: '${side}_arm_too_high',
          message:
              'Your $side arm is above shoulder height. Lower it slightly and keep the shoulder relaxed.',
          severity: elevationDegrees > 110
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: elevationDegrees,
          threshold: YogaPostureTrackerThresholds.armElevationGoodMaxDegrees,
        ),
      );
    }
  }

  void _addPalmRotationErrors({
    required String side,
    required double palmRotationDegrees,
    required List<PostureError> errors,
  }) {
    if (palmRotationDegrees <
        YogaPostureTrackerThresholds.palmRotationGoodMinDegrees) {
      errors.add(
        PostureError(
          code: '${side}_palm_not_rotated_down',
          message:
              'Rotate your $side palm more toward the floor while keeping the arm long.',
          severity: palmRotationDegrees <=
                  YogaPostureTrackerThresholds.palmRotationSevereLowDegrees
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: palmRotationDegrees,
          threshold: YogaPostureTrackerThresholds.palmRotationGoodMinDegrees,
        ),
      );
      return;
    }
    if (palmRotationDegrees >
        YogaPostureTrackerThresholds.palmRotationGoodMaxDegrees) {
      errors.add(
        PostureError(
          code: '${side}_palm_over_rotated',
          message:
              'Rotate your $side palm back toward the floor; it appears turned too far.',
          severity: palmRotationDegrees >=
                  YogaPostureTrackerThresholds.palmRotationSevereHighDegrees
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: palmRotationDegrees,
          threshold: YogaPostureTrackerThresholds.palmRotationGoodMaxDegrees,
        ),
      );
    }
  }

  double _evaluateArmHeightSymmetry({
    required _ArmPoseMetrics leftArm,
    required _ArmPoseMetrics rightArm,
    required List<PostureError> errors,
  }) {
    final difference =
        (leftArm.elevationDegrees - rightArm.elevationDegrees).abs();
    final score = _absoluteThresholdScore(
      value: difference,
      perfectMax:
          YogaPostureTrackerThresholds.armHeightDifferencePerfectDegrees,
      goodMax: YogaPostureTrackerThresholds.armHeightDifferenceGoodDegrees,
      weight: _armHeightSymmetryWeight,
    );
    if (difference >
        YogaPostureTrackerThresholds.armHeightDifferenceGoodDegrees) {
      final leftIsHigher = leftArm.elevationDegrees > rightArm.elevationDegrees;
      errors.add(
        PostureError(
          code: leftIsHigher ? 'left_arm_higher' : 'right_arm_higher',
          message: leftIsHigher
              ? 'Your left hand appears higher than your right. Lower the left side slightly.'
              : 'Your right hand appears higher than your left. Lower the right side slightly.',
          severity: difference > 20
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: difference,
          threshold:
              YogaPostureTrackerThresholds.armHeightDifferenceGoodDegrees,
        ),
      );
    }
    return score;
  }

  bool _evaluateArmStability({
    required String side,
    required String ringId,
    required SensorWindow poseWindow,
    required List<PostureError> errors,
  }) {
    return _evaluateGyroStability(
      code: '${side}_arm_unstable',
      message: 'Your $side hand or arm is unstable during the hold.',
      samples: poseWindow.ringGyroscopeSamplesFor(ringId),
      threshold: YogaPostureTrackerThresholds.armGyroInstability,
      errors: errors,
    );
  }

  bool _evaluateGyroStability({
    required String code,
    required String message,
    required List<ImuSample> samples,
    required double threshold,
    required List<PostureError> errors,
  }) {
    final gyroStats = vectorStats(samples);
    if (!gyroStats.hasData) {
      return false;
    }
    if (gyroStats.meanMagnitude > threshold) {
      errors.add(
        PostureError(
          code: code,
          message: message,
          severity: PostureErrorSeverity.minor,
          measuredValue: gyroStats.meanMagnitude,
          threshold: threshold,
        ),
      );
      return false;
    }
    return true;
  }

  List<double> _baselineMean({
    required CalibrationData calibration,
    required String key,
    required List<ImuSample> fallbackSamples,
  }) {
    final startOrientation = calibration.startOrientations[key];
    if (startOrientation != null) {
      return startOrientation.meanVector;
    }
    return vectorStats(fallbackSamples).mean;
  }

  double _rangeScore({
    required double value,
    required double perfectMin,
    required double perfectMax,
    required double goodMin,
    required double goodMax,
    required double weight,
  }) {
    if (value >= perfectMin && value <= perfectMax) {
      return weight;
    }
    if (value >= goodMin && value <= goodMax) {
      return weight * 0.8;
    }
    return 0;
  }

  double _absoluteThresholdScore({
    required double value,
    required double perfectMax,
    required double goodMax,
    required double weight,
  }) {
    if (value <= perfectMax) {
      return weight;
    }
    if (value <= goodMax) {
      return weight * 0.8;
    }
    return 0;
  }
}

class _ArmPoseMetrics {
  final double elevationDegrees;
  final double elevationScore;
  final double palmRotationScore;
  final bool isStable;

  const _ArmPoseMetrics({
    required this.elevationDegrees,
    required this.elevationScore,
    required this.palmRotationScore,
    required this.isStable,
  });
}
