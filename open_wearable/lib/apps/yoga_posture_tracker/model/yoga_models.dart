import 'dart:math';

import 'package:open_earable_flutter/open_earable_flutter.dart';

enum YogaSessionPhase {
  idle,
  checkingDevices,
  poseSelection,
  calibrationInstructions,
  calibrating,
  poseInstructions,
  holdingPose,
  evaluating,
  feedback,
  result,
}

class YogaPose {
  final String id;
  final String name;
  final String instruction;
  final String imageAsset;
  final bool isEvaluationAvailable;

  const YogaPose({
    required this.id,
    required this.name,
    required this.instruction,
    required this.imageAsset,
    this.isEvaluationAvailable = false,
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

  RingAssignment assignLeftRing(String ringId) {
    return RingAssignment(
      leftRingId: ringId,
      rightRingId: rightRingId == ringId ? leftRingId : rightRingId,
    );
  }

  RingAssignment assignRightRing(String ringId) {
    return RingAssignment(
      leftRingId: leftRingId == ringId ? rightRingId : leftRingId,
      rightRingId: ringId,
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

class SensorSampleQuality {
  final String label;
  final int sampleCount;
  final int minimumSampleCount;
  final bool isRequired;

  const SensorSampleQuality({
    required this.label,
    required this.sampleCount,
    required this.minimumSampleCount,
    this.isRequired = true,
  });

  bool get isMissing => sampleCount == 0;
  bool get isLow => sampleCount > 0 && sampleCount < minimumSampleCount;
  bool get isOk => !isRequired || sampleCount >= minimumSampleCount;

  String get statusLabel {
    if (!isRequired) {
      return 'Optional';
    }
    if (isMissing) {
      return 'No data';
    }
    if (isLow) {
      return 'Low data';
    }
    return 'Live';
  }
}

class SensorWindowQuality {
  final List<SensorSampleQuality> streams;

  const SensorWindowQuality({
    required this.streams,
  });

  int get totalSampleCount {
    return streams.fold<int>(
      0,
      (total, stream) => total + stream.sampleCount,
    );
  }

  bool get hasIssues => streams.any((stream) => !stream.isOk);

  List<SensorSampleQuality> get issueStreams {
    return streams.where((stream) => !stream.isOk).toList(growable: false);
  }
}

class CalibrationData {
  final SensorWindow baselineWindow;
  final RingAssignment ringAssignment;
  final Map<String, SensorStartOrientation> startOrientations;

  const CalibrationData({
    required this.baselineWindow,
    required this.ringAssignment,
    this.startOrientations = const {},
  });

  factory CalibrationData.fromWindow({
    required SensorWindow baselineWindow,
    required RingAssignment ringAssignment,
  }) {
    final startOrientations = <String, SensorStartOrientation>{};
    _addStartOrientation(
      startOrientations,
      key: SensorStartOrientation.earableAccelerometerKey,
      samples: baselineWindow.earableAccelerometerSamples,
    );
    _addStartOrientation(
      startOrientations,
      key: SensorStartOrientation.earableGyroscopeKey,
      samples: baselineWindow.earableGyroscopeSamples,
    );
    for (final entry
        in baselineWindow.ringAccelerometerSamplesByDeviceId.entries) {
      _addStartOrientation(
        startOrientations,
        key: SensorStartOrientation.ringAccelerometerKey(entry.key),
        samples: entry.value,
      );
    }
    for (final entry in baselineWindow.ringGyroscopeSamplesByDeviceId.entries) {
      _addStartOrientation(
        startOrientations,
        key: SensorStartOrientation.ringGyroscopeKey(entry.key),
        samples: entry.value,
      );
    }

    return CalibrationData(
      baselineWindow: baselineWindow,
      ringAssignment: ringAssignment,
      startOrientations: startOrientations,
    );
  }

  static void _addStartOrientation(
    Map<String, SensorStartOrientation> startOrientations, {
    required String key,
    required List<ImuSample> samples,
  }) {
    if (samples.isEmpty) {
      return;
    }
    final width = samples.first.values.length;
    if (width == 0) {
      return;
    }
    final meanVector = List<double>.filled(width, 0);
    for (final sample in samples) {
      for (var i = 0; i < width && i < sample.values.length; i++) {
        meanVector[i] += sample.values[i];
      }
    }
    for (var i = 0; i < meanVector.length; i++) {
      meanVector[i] /= samples.length;
    }
    startOrientations[key] = SensorStartOrientation(
      key: key,
      meanVector: meanVector,
    );
  }
}

class SensorStartOrientation {
  static const String earableAccelerometerKey = 'earable:accelerometer';
  static const String earableGyroscopeKey = 'earable:gyroscope';

  final String key;
  final List<double> meanVector;

  const SensorStartOrientation({
    required this.key,
    required this.meanVector,
  });

  static String ringAccelerometerKey(String deviceId) {
    return 'ring:$deviceId:accelerometer';
  }

  static String ringGyroscopeKey(String deviceId) {
    return 'ring:$deviceId:gyroscope';
  }
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
  final int occurrenceCount;
  final int? evaluatedWindowCount;

  const PostureError({
    required this.code,
    required this.message,
    required this.severity,
    required this.measuredValue,
    required this.threshold,
    this.occurrenceCount = 1,
    this.evaluatedWindowCount,
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
  final bool generatedByLlm;

  const YogaFeedback({
    required this.recommendation,
    this.generatedByLlm = false,
  });
}

class YogaPostureTrackerThresholds {
  static const double armElevationPerfectMinDegrees = 85;
  static const double armElevationPerfectMaxDegrees = 95;
  static const double armElevationGoodMinDegrees = 80;
  static const double armElevationGoodMaxDegrees = 100;
  static const double armHeightDifferencePerfectDegrees = 5;
  static const double armHeightDifferenceGoodDegrees = 10;
  static const double palmRotationPerfectMinDegrees = 80;
  static const double palmRotationPerfectMaxDegrees = 100;
  static const double palmRotationGoodMinDegrees = 70;
  static const double palmRotationGoodMaxDegrees = 110;
  static const double palmRotationSevereLowDegrees = 40;
  static const double palmRotationSevereHighDegrees = 120;
  static const double headPitchRollPerfectDegrees = 5;
  static const double headPitchRollGoodDegrees = 10;
  static const double armGyroInstability = 120;
  static const double headGyroInstability = 120;
  static const double calibrationGyroInstability = 80;

  static const double chairArmElevationPerfectMinDegrees = 165;
  static const double chairArmElevationGoodMinDegrees = 150;
  static const double chairArmSymmetryPerfectDegrees = 5;
  static const double chairArmSymmetryGoodDegrees = 10;
  static const double chairHandSymmetryPerfectDegrees = 10;
  static const double chairHandSymmetryGoodDegrees = 20;
  static const double chairHeadPitchGoodDegrees = 20;
  static const double chairHeadRollGoodDegrees = 10;

  static const double triangleUpperArmPerfectMinDegrees = 165;
  static const double triangleUpperArmGoodMinDegrees = 150;
  static const double triangleLowerArmPerfectMaxDegrees = 30;
  static const double triangleLowerArmGoodMaxDegrees = 45;
  static const double triangleArmLinePerfectDifferenceDegrees = 150;
  static const double triangleArmLineGoodDifferenceDegrees = 130;
  static const double triangleHeadPitchPerfectDegrees = 20;
  static const double triangleHeadPitchGoodDegrees = 30;
  static const double triangleHeadRollPerfectDegrees = 15;
  static const double triangleHeadRollGoodDegrees = 25;

  static const double cobraHeadLiftPerfectMinDegrees = 20;
  static const double cobraHeadLiftPerfectMaxDegrees = 40;
  static const double cobraHeadLiftGoodMinDegrees = 15;
  static const double cobraHeadLiftGoodMaxDegrees = 50;
  static const double cobraHeadRollPerfectDegrees = 5;
  static const double cobraHeadRollGoodDegrees = 10;
  static const double cobraHandSymmetryPerfectDegrees = 10;
  static const double cobraHandSymmetryGoodDegrees = 15;
}

const YogaPose warriorTwoPose = YogaPose(
  id: 'warrior_ii',
  name: 'Warrior II',
  instruction:
      'Step into a wide stance, raise your arms to shoulder height, bend your front knee softly, and gaze over your front hand.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/warrior_ii_pose2.png',
  isEvaluationAvailable: true,
);

const YogaPose trianglePose = YogaPose(
  id: 'triangle',
  name: 'Triangle',
  instruction:
      'Stand in a wide stance, reach one hand toward your front leg, extend the other arm upward, and turn your gaze toward the upper hand.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/triangle_pose.png',
  isEvaluationAvailable: true,
);

const YogaPose chairPose = YogaPose(
  id: 'chair',
  name: 'Chair',
  instruction:
      'Bend your knees, sit your hips back, keep your chest lifted, and reach both arms upward.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/chair_pose.png',
  isEvaluationAvailable: true,
);

const YogaPose cobraPose = YogaPose(
  id: 'cobra',
  name: 'Cobra',
  instruction:
      'Lie on your front, place your hands beside the ribs, and gently lift your head and chest forward.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/cobra_pose.png',
  isEvaluationAvailable: true,
);

const List<YogaPose> yogaPostureTrackerPoses = [
  warriorTwoPose,
  trianglePose,
  chairPose,
  cobraPose,
];

const String yogaCalibrationPoseAsset =
    'lib/apps/yoga_posture_tracker/assets/calibration_pose.png';

const String yogaCalibrationPoseSemanticLabel = 'Calibration pose';
