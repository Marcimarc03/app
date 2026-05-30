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
  static const double _chairArmsOverheadWeight = 30;
  static const double _chairArmHeightSymmetryWeight = 20;
  static const double _chairHandSymmetryWeight = 15;
  static const double _chairHeadNeutralWeight = 20;
  static const double _chairStabilityWeight = 15;
  static const double _triangleUpperArmWeight = 25;
  static const double _triangleLowerArmWeight = 20;
  static const double _triangleArmLineWeight = 20;
  static const double _triangleHeadControlWeight = 20;
  static const double _triangleStabilityWeight = 15;
  static const double _cobraHeadLiftWeight = 30;
  static const double _cobraHeadRollWeight = 20;
  static const double _cobraHeadControlWeight = 15;
  static const double _cobraHandSymmetryWeight = 20;
  static const double _cobraStabilityWeight = 15;

  const RuleBasedPoseEvaluator();

  PoseEvaluationResult evaluatePose({
    required YogaPose pose,
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    return switch (pose.id) {
      'warrior_ii' => evaluateWarriorTwo(
          calibration: calibration,
          poseWindow: poseWindow,
        ),
      'triangle' => evaluateTriangle(
          calibration: calibration,
          poseWindow: poseWindow,
        ),
      'chair' => evaluateChair(
          calibration: calibration,
          poseWindow: poseWindow,
        ),
      'cobra' => evaluateCobra(
          calibration: calibration,
          poseWindow: poseWindow,
        ),
      _ => PoseEvaluationResult(
          score: 0,
          errors: [
            PostureError(
              code: 'unknown_pose',
              message: 'This pose is not available for scoring yet.',
              severity: PostureErrorSeverity.severe,
              measuredValue: 0,
              threshold: 1,
            ),
          ],
        ),
    };
  }

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

  PoseEvaluationResult evaluateChair({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    final errors = <PostureError>[];
    var earnedScore = 0.0;

    final leftArm = _ringArmMetrics(
      side: 'left',
      ringId: calibration.ringAssignment.leftRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'chair',
    );
    final rightArm = _ringArmMetrics(
      side: 'right',
      ringId: calibration.ringAssignment.rightRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'chair',
    );

    if (leftArm != null) {
      earnedScore += _minimumThresholdScore(
        value: leftArm.elevationDegrees,
        perfectMin:
            YogaPostureTrackerThresholds.chairArmElevationPerfectMinDegrees,
        goodMin: YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees,
        weight: _chairArmsOverheadWeight / 2,
      );
      if (leftArm.elevationDegrees <
          YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees) {
        errors.add(
          PostureError(
            code: 'chair_left_arm_too_low',
            message: 'Raise your left arm further overhead.',
            severity: leftArm.elevationDegrees < 130
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: leftArm.elevationDegrees,
            threshold:
                YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees,
          ),
        );
      }
    }
    if (rightArm != null) {
      earnedScore += _minimumThresholdScore(
        value: rightArm.elevationDegrees,
        perfectMin:
            YogaPostureTrackerThresholds.chairArmElevationPerfectMinDegrees,
        goodMin: YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees,
        weight: _chairArmsOverheadWeight / 2,
      );
      if (rightArm.elevationDegrees <
          YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees) {
        errors.add(
          PostureError(
            code: 'chair_right_arm_too_low',
            message: 'Raise your right arm further overhead.',
            severity: rightArm.elevationDegrees < 130
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: rightArm.elevationDegrees,
            threshold:
                YogaPostureTrackerThresholds.chairArmElevationGoodMinDegrees,
          ),
        );
      }
    }

    if (leftArm != null && rightArm != null) {
      earnedScore += _armElevationSymmetryScore(
        leftArm: leftArm,
        rightArm: rightArm,
        perfectMax: YogaPostureTrackerThresholds.chairArmSymmetryPerfectDegrees,
        goodMax: YogaPostureTrackerThresholds.chairArmSymmetryGoodDegrees,
        weight: _chairArmHeightSymmetryWeight,
        errorCode: 'chair_arms_uneven',
        errorMessage: 'Keep both arms at the same height.',
        errors: errors,
      );
      earnedScore += _handSymmetryScore(
        leftArm: leftArm,
        rightArm: rightArm,
        perfectMax:
            YogaPostureTrackerThresholds.chairHandSymmetryPerfectDegrees,
        goodMax: YogaPostureTrackerThresholds.chairHandSymmetryGoodDegrees,
        weight: _chairHandSymmetryWeight,
        errorCode: 'chair_hands_asymmetric',
        errorMessage: 'Keep your arms steady and symmetrical.',
        errors: errors,
      );
    }

    earnedScore += _evaluateGenericHeadControl(
      calibration: calibration,
      poseWindow: poseWindow,
      pitchPerfectMax: YogaPostureTrackerThresholds.headPitchRollPerfectDegrees,
      pitchGoodMax: YogaPostureTrackerThresholds.chairHeadPitchGoodDegrees,
      rollPerfectMax: YogaPostureTrackerThresholds.headPitchRollPerfectDegrees,
      rollGoodMax: YogaPostureTrackerThresholds.chairHeadRollGoodDegrees,
      weight: _chairHeadNeutralWeight,
      errorCode: 'chair_head_tilted',
      errorMessage: 'Keep your head straight and your gaze forward.',
      errors: errors,
    );

    earnedScore += _poseStabilityScore(
      code: 'chair_unstable',
      message: 'Hold the pose more steadily.',
      poseWindow: poseWindow,
      leftArm: leftArm,
      rightArm: rightArm,
      weight: _chairStabilityWeight,
      errors: errors,
    );

    _addNoSensorDataErrorIfNeeded(poseWindow, errors);
    return PoseEvaluationResult(
      score: _clampedScore(earnedScore),
      errors: errors,
    );
  }

  PoseEvaluationResult evaluateTriangle({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    final errors = <PostureError>[];
    var earnedScore = 0.0;

    final leftArm = _ringArmMetrics(
      side: 'left',
      ringId: calibration.ringAssignment.leftRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'triangle',
    );
    final rightArm = _ringArmMetrics(
      side: 'right',
      ringId: calibration.ringAssignment.rightRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'triangle',
    );

    if (leftArm != null && rightArm != null) {
      final upperArm = leftArm.elevationDegrees >= rightArm.elevationDegrees
          ? leftArm
          : rightArm;
      final lowerArm = identical(upperArm, leftArm) ? rightArm : leftArm;
      final armLineDifference =
          (upperArm.elevationDegrees - lowerArm.elevationDegrees).abs();

      earnedScore += _minimumThresholdScore(
        value: upperArm.elevationDegrees,
        perfectMin:
            YogaPostureTrackerThresholds.triangleUpperArmPerfectMinDegrees,
        goodMin: YogaPostureTrackerThresholds.triangleUpperArmGoodMinDegrees,
        weight: _triangleUpperArmWeight,
      );
      if (upperArm.elevationDegrees <
          YogaPostureTrackerThresholds.triangleUpperArmGoodMinDegrees) {
        errors.add(
          PostureError(
            code: 'triangle_${upperArm.side}_upper_arm_too_low',
            message: 'Stretch your ${upperArm.side} upper arm further upward.',
            severity: upperArm.elevationDegrees < 130
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: upperArm.elevationDegrees,
            threshold:
                YogaPostureTrackerThresholds.triangleUpperArmGoodMinDegrees,
          ),
        );
      }

      earnedScore += _maximumThresholdScore(
        value: lowerArm.elevationDegrees,
        perfectMax:
            YogaPostureTrackerThresholds.triangleLowerArmPerfectMaxDegrees,
        goodMax: YogaPostureTrackerThresholds.triangleLowerArmGoodMaxDegrees,
        weight: _triangleLowerArmWeight,
      );
      if (lowerArm.elevationDegrees >
          YogaPostureTrackerThresholds.triangleLowerArmGoodMaxDegrees) {
        errors.add(
          PostureError(
            code: 'triangle_${lowerArm.side}_lower_arm_too_high',
            message:
                'Move your ${lowerArm.side} lower hand closer toward your leg or the floor.',
            severity: lowerArm.elevationDegrees > 65
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: lowerArm.elevationDegrees,
            threshold:
                YogaPostureTrackerThresholds.triangleLowerArmGoodMaxDegrees,
          ),
        );
      }

      earnedScore += _minimumThresholdScore(
        value: armLineDifference,
        perfectMin: YogaPostureTrackerThresholds
            .triangleArmLinePerfectDifferenceDegrees,
        goodMin:
            YogaPostureTrackerThresholds.triangleArmLineGoodDifferenceDegrees,
        weight: _triangleArmLineWeight,
      );
      if (armLineDifference <
          YogaPostureTrackerThresholds.triangleArmLineGoodDifferenceDegrees) {
        errors.add(
          PostureError(
            code: 'triangle_arm_line_unclear',
            message: 'Stretch both arms in opposite directions.',
            severity: armLineDifference < 110
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: armLineDifference,
            threshold: YogaPostureTrackerThresholds
                .triangleArmLineGoodDifferenceDegrees,
          ),
        );
      }
    }

    earnedScore += _evaluateGenericHeadControl(
      calibration: calibration,
      poseWindow: poseWindow,
      pitchPerfectMax:
          YogaPostureTrackerThresholds.triangleHeadPitchPerfectDegrees,
      pitchGoodMax: YogaPostureTrackerThresholds.triangleHeadPitchGoodDegrees,
      rollPerfectMax:
          YogaPostureTrackerThresholds.triangleHeadRollPerfectDegrees,
      rollGoodMax: YogaPostureTrackerThresholds.triangleHeadRollGoodDegrees,
      weight: _triangleHeadControlWeight,
      errorCode: 'triangle_head_uncontrolled',
      errorMessage: 'Keep your neck long and controlled.',
      errors: errors,
    );

    earnedScore += _poseStabilityScore(
      code: 'triangle_unstable',
      message: 'Hold the pose more steadily.',
      poseWindow: poseWindow,
      leftArm: leftArm,
      rightArm: rightArm,
      weight: _triangleStabilityWeight,
      errors: errors,
    );

    _addNoSensorDataErrorIfNeeded(poseWindow, errors);
    return PoseEvaluationResult(
      score: _clampedScore(earnedScore),
      errors: errors,
    );
  }

  PoseEvaluationResult evaluateCobra({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    final errors = <PostureError>[];
    var earnedScore = 0.0;

    final leftHand = _ringArmMetrics(
      side: 'left',
      ringId: calibration.ringAssignment.leftRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'cobra',
    );
    final rightHand = _ringArmMetrics(
      side: 'right',
      ringId: calibration.ringAssignment.rightRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
      missingCodePrefix: 'cobra',
    );

    final headDelta = _headDelta(calibration, poseWindow);
    if (headDelta != null) {
      // This is an accelerometer-based head tilt proxy. It cannot directly
      // measure chest lift, spinal extension, or shoulder alignment.
      final headLift = headDelta.pitch.abs();
      earnedScore += _rangeScore(
        value: headLift,
        perfectMin: YogaPostureTrackerThresholds.cobraHeadLiftPerfectMinDegrees,
        perfectMax: YogaPostureTrackerThresholds.cobraHeadLiftPerfectMaxDegrees,
        goodMin: YogaPostureTrackerThresholds.cobraHeadLiftGoodMinDegrees,
        goodMax: YogaPostureTrackerThresholds.cobraHeadLiftGoodMaxDegrees,
        weight: _cobraHeadLiftWeight,
      );
      if (headLift < YogaPostureTrackerThresholds.cobraHeadLiftGoodMinDegrees) {
        errors.add(
          PostureError(
            code: 'cobra_head_not_lifted',
            message: 'Lift your head and chest slightly more.',
            severity: PostureErrorSeverity.medium,
            measuredValue: headLift,
            threshold: YogaPostureTrackerThresholds.cobraHeadLiftGoodMinDegrees,
          ),
        );
      } else if (headLift >
          YogaPostureTrackerThresholds.cobraHeadLiftGoodMaxDegrees) {
        errors.add(
          PostureError(
            code: 'cobra_head_overextended',
            message: 'Avoid pushing your head too far into the neck.',
            severity: PostureErrorSeverity.medium,
            measuredValue: headLift,
            threshold: YogaPostureTrackerThresholds.cobraHeadLiftGoodMaxDegrees,
          ),
        );
      }

      final headRoll = headDelta.roll.abs();
      earnedScore += _absoluteThresholdScore(
        value: headRoll,
        perfectMax: YogaPostureTrackerThresholds.cobraHeadRollPerfectDegrees,
        goodMax: YogaPostureTrackerThresholds.cobraHeadRollGoodDegrees,
        weight: _cobraHeadRollWeight,
      );
      if (headRoll > YogaPostureTrackerThresholds.cobraHeadRollGoodDegrees) {
        errors.add(
          PostureError(
            code: 'cobra_head_tilted',
            message: 'Keep your head centered.',
            severity: headRoll > 20
                ? PostureErrorSeverity.severe
                : PostureErrorSeverity.medium,
            measuredValue: headRoll,
            threshold: YogaPostureTrackerThresholds.cobraHeadRollGoodDegrees,
          ),
        );
      }

      earnedScore += headLift >=
              YogaPostureTrackerThresholds.cobraHeadLiftGoodMinDegrees
          ? _absoluteThresholdScore(
              value: headLift,
              perfectMax:
                  YogaPostureTrackerThresholds.cobraHeadLiftPerfectMaxDegrees,
              goodMax: YogaPostureTrackerThresholds.cobraHeadLiftGoodMaxDegrees,
              weight: _cobraHeadControlWeight,
            )
          : 0;
    }

    if (leftHand != null && rightHand != null) {
      earnedScore += _handSymmetryScore(
        leftArm: leftHand,
        rightArm: rightHand,
        perfectMax:
            YogaPostureTrackerThresholds.cobraHandSymmetryPerfectDegrees,
        goodMax: YogaPostureTrackerThresholds.cobraHandSymmetryGoodDegrees,
        weight: _cobraHandSymmetryWeight,
        errorCode: 'cobra_hands_asymmetric',
        errorMessage: 'Distribute your weight evenly on both hands.',
        errors: errors,
      );
    }

    earnedScore += _poseStabilityScore(
      code: 'cobra_unstable',
      message: 'Keep your hands steady on the floor.',
      poseWindow: poseWindow,
      leftArm: leftHand,
      rightArm: rightHand,
      weight: _cobraStabilityWeight,
      errors: errors,
    );

    _addNoSensorDataErrorIfNeeded(poseWindow, errors);
    return PoseEvaluationResult(
      score: _clampedScore(earnedScore),
      errors: errors,
    );
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

  OrientationDelta? _headDelta(
    CalibrationData calibration,
    SensorWindow poseWindow,
  ) {
    final baselineMean = _baselineMean(
      calibration: calibration,
      key: SensorStartOrientation.earableAccelerometerKey,
      fallbackSamples: calibration.baselineWindow.earableAccelerometerSamples,
    );
    final poseStats = vectorStats(poseWindow.earableAccelerometerSamples);
    if (baselineMean.isEmpty || !poseStats.hasData) {
      return null;
    }
    return orientationDeltaDegrees(
      baselineMean: baselineMean,
      poseMean: poseStats.mean,
    );
  }

  double _evaluateGenericHeadControl({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
    required double pitchPerfectMax,
    required double pitchGoodMax,
    required double rollPerfectMax,
    required double rollGoodMax,
    required double weight,
    required String errorCode,
    required String errorMessage,
    required List<PostureError> errors,
  }) {
    final delta = _headDelta(calibration, poseWindow);
    if (delta == null) {
      return 0;
    }

    final pitch = delta.pitch.abs();
    final roll = delta.roll.abs();
    final pitchWeight = weight / 2;
    final rollWeight = weight / 2;
    final score = _absoluteThresholdScore(
          value: pitch,
          perfectMax: pitchPerfectMax,
          goodMax: pitchGoodMax,
          weight: pitchWeight,
        ) +
        _absoluteThresholdScore(
          value: roll,
          perfectMax: rollPerfectMax,
          goodMax: rollGoodMax,
          weight: rollWeight,
        );

    if (pitch > pitchGoodMax || roll > rollGoodMax) {
      final measuredValue = max(pitch, roll);
      errors.add(
        PostureError(
          code: errorCode,
          message: errorMessage,
          severity: measuredValue > 30
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: measuredValue,
          threshold: max(pitchGoodMax, rollGoodMax),
        ),
      );
    }
    return score;
  }

  _RingPoseMetrics? _ringArmMetrics({
    required String side,
    required String? ringId,
    required CalibrationData calibration,
    required SensorWindow poseWindow,
    required List<PostureError> errors,
    required String missingCodePrefix,
  }) {
    if (ringId == null) {
      errors.add(
        PostureError(
          code: '${missingCodePrefix}_${side}_ring_data_missing',
          message: 'No $side ring was assigned for this pose.',
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
          code: '${missingCodePrefix}_${side}_ring_data_missing',
          message: 'No accelerometer data was available for the $side ring.',
          severity: PostureErrorSeverity.severe,
          measuredValue: 0,
          threshold: 1,
        ),
      );
      return null;
    }

    final orientationDelta = orientationDeltaDegrees(
      baselineMean: baselineMean,
      poseMean: poseStats.mean,
    );
    final gyroMeanMagnitude =
        vectorStats(poseWindow.ringGyroscopeSamplesFor(ringId)).meanMagnitude;
    return _RingPoseMetrics(
      side: side,
      elevationDegrees: angleBetweenVectorsDegrees(
        baselineMean,
        poseStats.mean,
      ),
      handPitchDelta: orientationDelta.pitch,
      handRollDelta: orientationDelta.roll,
      gyroMeanMagnitude: gyroMeanMagnitude,
      isStable:
          gyroMeanMagnitude <= YogaPostureTrackerThresholds.armGyroInstability,
    );
  }

  double _armElevationSymmetryScore({
    required _RingPoseMetrics leftArm,
    required _RingPoseMetrics rightArm,
    required double perfectMax,
    required double goodMax,
    required double weight,
    required String errorCode,
    required String errorMessage,
    required List<PostureError> errors,
  }) {
    final difference =
        (leftArm.elevationDegrees - rightArm.elevationDegrees).abs();
    final score = _absoluteThresholdScore(
      value: difference,
      perfectMax: perfectMax,
      goodMax: goodMax,
      weight: weight,
    );
    if (difference > goodMax) {
      errors.add(
        PostureError(
          code: errorCode,
          message: errorMessage,
          severity: difference > 20
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: difference,
          threshold: goodMax,
        ),
      );
    }
    return score;
  }

  double _handSymmetryScore({
    required _RingPoseMetrics leftArm,
    required _RingPoseMetrics rightArm,
    required double perfectMax,
    required double goodMax,
    required double weight,
    required String errorCode,
    required String errorMessage,
    required List<PostureError> errors,
  }) {
    final pitchDifference =
        (leftArm.handPitchDelta - rightArm.handPitchDelta).abs();
    final rollDifference =
        (leftArm.handRollDelta - rightArm.handRollDelta).abs();
    final measuredValue = max(pitchDifference, rollDifference);
    final score = measuredValue <= perfectMax
        ? weight
        : measuredValue <= goodMax
            ? weight * 0.8
            : 0.0;
    if (measuredValue > goodMax) {
      errors.add(
        PostureError(
          code: errorCode,
          message: errorMessage,
          severity: measuredValue > goodMax * 2
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: measuredValue,
          threshold: goodMax,
        ),
      );
    }
    return score;
  }

  double _poseStabilityScore({
    required String code,
    required String message,
    required SensorWindow poseWindow,
    required _RingPoseMetrics? leftArm,
    required _RingPoseMetrics? rightArm,
    required double weight,
    required List<PostureError> errors,
  }) {
    final headGyroStats = vectorStats(poseWindow.earableGyroscopeSamples);
    final headStable = headGyroStats.hasData &&
        headGyroStats.meanMagnitude <=
            YogaPostureTrackerThresholds.headGyroInstability;
    final leftStable = leftArm?.isStable ?? false;
    final rightStable = rightArm?.isStable ?? false;
    if (headStable && leftStable && rightStable) {
      return weight;
    }
    final measuredValue = max(
      headGyroStats.meanMagnitude,
      max(leftArm?.gyroMeanMagnitude ?? 0, rightArm?.gyroMeanMagnitude ?? 0),
    );
    if (headGyroStats.hasData || leftArm != null || rightArm != null) {
      errors.add(
        PostureError(
          code: code,
          message: message,
          severity: PostureErrorSeverity.minor,
          measuredValue: measuredValue,
          threshold: YogaPostureTrackerThresholds.armGyroInstability,
        ),
      );
    }
    return 0;
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

  void _addNoSensorDataErrorIfNeeded(
    SensorWindow poseWindow,
    List<PostureError> errors,
  ) {
    if (poseWindow.totalSampleCount != 0) {
      return;
    }
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

  int _clampedScore(double earnedScore) {
    return max(0, min(100, earnedScore.round()));
  }

  double _minimumThresholdScore({
    required double value,
    required double perfectMin,
    required double goodMin,
    required double weight,
  }) {
    if (value >= perfectMin) {
      return weight;
    }
    if (value >= goodMin) {
      return weight * 0.8;
    }
    return 0;
  }

  double _maximumThresholdScore({
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

class _RingPoseMetrics {
  final String side;
  final double elevationDegrees;
  final double handPitchDelta;
  final double handRollDelta;
  final double gyroMeanMagnitude;
  final bool isStable;

  const _RingPoseMetrics({
    required this.side,
    required this.elevationDegrees,
    required this.handPitchDelta,
    required this.handRollDelta,
    required this.gyroMeanMagnitude,
    required this.isStable,
  });
}
