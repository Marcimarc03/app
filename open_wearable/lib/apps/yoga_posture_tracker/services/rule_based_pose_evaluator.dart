import 'dart:math';

import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_math.dart';

class RuleBasedPoseEvaluator {
  const RuleBasedPoseEvaluator();

  PoseEvaluationResult evaluateWarriorTwo({
    required CalibrationData calibration,
    required SensorWindow poseWindow,
  }) {
    final errors = <PostureError>[];
    _evaluateHeadTilt(calibration, poseWindow, errors);
    _evaluateHeadStability(poseWindow, errors);
    _evaluateRingArm(
      side: 'left',
      ringId: calibration.ringAssignment.leftRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
    );
    _evaluateRingArm(
      side: 'right',
      ringId: calibration.ringAssignment.rightRingId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
    );

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

    final penalty = errors.fold<int>(
      0,
      (total, error) => total + error.scorePenalty,
    );
    final score = max(0, min(100, 100 - penalty));

    return PoseEvaluationResult(score: score, errors: errors);
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

  void _evaluateHeadTilt(
    CalibrationData calibration,
    SensorWindow poseWindow,
    List<PostureError> errors,
  ) {
    final baselineStats =
        vectorStats(calibration.baselineWindow.earableAccelerometerSamples);
    final poseStats = vectorStats(poseWindow.earableAccelerometerSamples);
    if (!baselineStats.hasData || !poseStats.hasData) {
      return;
    }

    final tiltDegrees = largestOrientationDeltaDegrees(
      baselineMean: baselineStats.mean,
      poseMean: poseStats.mean,
    );
    if (tiltDegrees > YogaPostureTrackerThresholds.headTiltDegrees) {
      errors.add(
        PostureError(
          code: 'head_tilted',
          message: 'Your head is tilted too far from the calibrated neutral.',
          severity: tiltDegrees > 35
              ? PostureErrorSeverity.severe
              : PostureErrorSeverity.medium,
          measuredValue: tiltDegrees,
          threshold: YogaPostureTrackerThresholds.headTiltDegrees,
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

  void _evaluateHeadStability(
    SensorWindow poseWindow,
    List<PostureError> errors,
  ) {
    final gyroStats = vectorStats(poseWindow.earableGyroscopeSamples);
    if (!gyroStats.hasData) {
      return;
    }
    if (gyroStats.meanMagnitude >
        YogaPostureTrackerThresholds.headGyroInstability) {
      errors.add(
        PostureError(
          code: 'head_unstable',
          message: 'Your head is moving too much during the hold.',
          severity: PostureErrorSeverity.minor,
          measuredValue: gyroStats.meanMagnitude,
          threshold: YogaPostureTrackerThresholds.headGyroInstability,
        ),
      );
    }
  }

  void _evaluateRingArm({
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
      return;
    }

    _evaluateArmLift(
      side: side,
      ringId: ringId,
      calibration: calibration,
      poseWindow: poseWindow,
      errors: errors,
    );
    _evaluateArmStability(
      side: side,
      ringId: ringId,
      poseWindow: poseWindow,
      errors: errors,
    );
  }

  void _evaluateArmLift({
    required String side,
    required String ringId,
    required CalibrationData calibration,
    required SensorWindow poseWindow,
    required List<PostureError> errors,
  }) {
    final baselineSamples =
        calibration.baselineWindow.ringAccelerometerSamplesFor(ringId);
    final poseSamples = poseWindow.ringAccelerometerSamplesFor(ringId);
    if (baselineSamples.isEmpty || poseSamples.isEmpty) {
      errors.add(
        PostureError(
          code: '${side}_ring_data_missing',
          message: 'No accelerometer data was available for the $side ring.',
          severity: PostureErrorSeverity.severe,
          measuredValue: 0,
          threshold: 1,
        ),
      );
      return;
    }

    final baselineStats = vectorStats(baselineSamples);
    final poseStats = vectorStats(poseSamples);
    if (!baselineStats.hasData || !poseStats.hasData) {
      return;
    }

    // This is a gravity-vector proxy, not a full anatomical arm angle.
    // TODO: Replace with a calibrated ring orientation model once ring
    // placement and hand assignment are fixed for the study protocol.
    final liftDegrees = largestOrientationDeltaDegrees(
      baselineMean: baselineStats.mean,
      poseMean: poseStats.mean,
    );
    final minimumAcceptedLift =
        YogaPostureTrackerThresholds.expectedWarriorArmLiftDegrees -
            YogaPostureTrackerThresholds.armTooLowToleranceDegrees;
    if (liftDegrees < minimumAcceptedLift) {
      errors.add(
        PostureError(
          code: '${side}_arm_too_low',
          message: 'Your $side arm appears to be too low for Warrior II.',
          severity: PostureErrorSeverity.medium,
          measuredValue: liftDegrees,
          threshold: minimumAcceptedLift,
        ),
      );
    }
  }

  void _evaluateArmStability({
    required String side,
    required String ringId,
    required SensorWindow poseWindow,
    required List<PostureError> errors,
  }) {
    final gyroSamples = poseWindow.ringGyroscopeSamplesFor(ringId);
    if (gyroSamples.isEmpty) {
      return;
    }
    final gyroStats = vectorStats(gyroSamples);
    if (!gyroStats.hasData) {
      return;
    }
    if (gyroStats.meanMagnitude >
        YogaPostureTrackerThresholds.armGyroInstability) {
      errors.add(
        PostureError(
          code: '${side}_arm_unstable',
          message: 'Your $side hand or arm is unstable during the hold.',
          severity: PostureErrorSeverity.minor,
          measuredValue: gyroStats.meanMagnitude,
          threshold: YogaPostureTrackerThresholds.armGyroInstability,
        ),
      );
    }
  }
}
