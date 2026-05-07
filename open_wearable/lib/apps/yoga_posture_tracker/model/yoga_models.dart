import 'dart:math';

import 'package:open_earable_flutter/open_earable_flutter.dart';

enum YogaSessionPhase {
  idle,
  checkingDevices,
  assigningRings,
  calibrationInstructions,
  calibrating,
  poseInstructions,
  holdingPose,
  evaluating,
  feedback,
  result,
}

class YogaPose {
  final String name;
  final String instruction;

  const YogaPose({
    required this.name,
    required this.instruction,
  });
}

class YogaDeviceSet {
  final Wearable? earable;
  final List<Wearable> rings;
  final RingAssignment ringAssignment;

  const YogaDeviceSet({
    required this.earable,
    required this.rings,
    this.ringAssignment = const RingAssignment(),
  });

  bool get hasEarable => earable != null;
  bool get hasTwoRings => rings.length >= 2;
  bool get hasValidRingAssignment => ringAssignment.isValid;
  bool get hasRequiredSetup =>
      hasEarable && hasTwoRings && hasValidRingAssignment;

  YogaDeviceSet copyWith({
    Wearable? earable,
    List<Wearable>? rings,
    RingAssignment? ringAssignment,
  }) {
    return YogaDeviceSet(
      earable: earable ?? this.earable,
      rings: rings ?? this.rings,
      ringAssignment: ringAssignment ?? this.ringAssignment,
    );
  }
}

class RingAssignment {
  final String? leftRingId;
  final String? rightRingId;

  const RingAssignment({
    this.leftRingId,
    this.rightRingId,
  });

  bool get hasBothRings => leftRingId != null && rightRingId != null;
  bool get hasDifferentRings => hasBothRings && leftRingId != rightRingId;
  bool get isValid => hasBothRings && hasDifferentRings;

  RingAssignment copyWith({
    String? leftRingId,
    String? rightRingId,
  }) {
    return RingAssignment(
      leftRingId: leftRingId ?? this.leftRingId,
      rightRingId: rightRingId ?? this.rightRingId,
    );
  }
}

class ImuSample {
  final String deviceId;
  final String deviceName;
  final String sensorName;
  final int timestamp;
  final List<double> values;

  const ImuSample({
    required this.deviceId,
    required this.deviceName,
    required this.sensorName,
    required this.timestamp,
    required this.values,
  });

  double get magnitude {
    if (values.isEmpty) {
      return 0;
    }
    final sum = values.fold<double>(0, (acc, value) => acc + value * value);
    return sqrt(sum);
  }
}

class SensorWindow {
  final List<ImuSample> earableAccelerometerSamples;
  final List<ImuSample> earableGyroscopeSamples;
  final Map<String, List<ImuSample>> ringAccelerometerSamplesByDeviceId;
  final Map<String, List<ImuSample>> ringGyroscopeSamplesByDeviceId;

  const SensorWindow({
    required this.earableAccelerometerSamples,
    required this.earableGyroscopeSamples,
    required this.ringAccelerometerSamplesByDeviceId,
    required this.ringGyroscopeSamplesByDeviceId,
  });

  int get totalSampleCount =>
      earableAccelerometerSamples.length +
      earableGyroscopeSamples.length +
      ringAccelerometerSamplesByDeviceId.values.fold<int>(
        0,
        (total, samples) => total + samples.length,
      ) +
      ringGyroscopeSamplesByDeviceId.values.fold<int>(
        0,
        (total, samples) => total + samples.length,
      );

  List<ImuSample> ringAccelerometerSamplesFor(String deviceId) {
    return ringAccelerometerSamplesByDeviceId[deviceId] ?? const [];
  }

  List<ImuSample> ringGyroscopeSamplesFor(String deviceId) {
    return ringGyroscopeSamplesByDeviceId[deviceId] ?? const [];
  }
}

class CalibrationData {
  final SensorWindow baselineWindow;
  final RingAssignment ringAssignment;

  const CalibrationData({
    required this.baselineWindow,
    required this.ringAssignment,
  });
}

enum PostureErrorSeverity {
  minor,
  medium,
  severe,
}

class PostureError {
  final String code;
  final String message;
  final PostureErrorSeverity severity;
  final double measuredValue;
  final double threshold;

  const PostureError({
    required this.code,
    required this.message,
    required this.severity,
    required this.measuredValue,
    required this.threshold,
  });

  int get scorePenalty {
    return switch (severity) {
      PostureErrorSeverity.minor => 10,
      PostureErrorSeverity.medium => 20,
      PostureErrorSeverity.severe => 30,
    };
  }
}

class PoseEvaluationResult {
  final int score;
  final List<PostureError> errors;

  const PoseEvaluationResult({
    required this.score,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
}

class YogaFeedback {
  final String recommendation;

  const YogaFeedback({
    required this.recommendation,
  });
}

class YogaPostureTrackerThresholds {
  static const double expectedWarriorArmLiftDegrees = 50;
  static const double armTooLowToleranceDegrees = 20;
  static const double headTiltDegrees = 20;
  static const double armGyroInstability = 120;
  static const double headGyroInstability = 120;
}

const YogaPose warriorTwoPose = YogaPose(
  name: 'Warrior II',
  instruction: 'Move into Warrior II and hold the pose for 5 seconds.',
);
