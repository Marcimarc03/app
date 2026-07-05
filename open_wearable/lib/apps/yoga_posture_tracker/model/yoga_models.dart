import 'dart:math';

import 'package:open_earable_flutter/open_earable_flutter.dart';

enum YogaSessionPhase {
  idle,
  checkingDevices,
  poseSelection,
  calibrationInstructions,
  calibrationPreparing,
  calibrating,
  poseInstructions,
  posePreparing,
  holdingPose,
  evaluating,
  result,
}

enum StudyCondition {
  noLiveCoaching('No live coaching'),
  llmLiveCoaching('LLM live coaching');

  final String label;

  const StudyCondition(this.label);
}

/// Researcher-provided configuration for one controlled study trial.
class StudyTrialConfig {
  final String participantId;
  final StudyCondition condition;
  final int trialOrder;

  const StudyTrialConfig({
    required this.participantId,
    required this.condition,
    required this.trialOrder,
  });

  String get trialId => '$participantId-T$trialOrder';

  StudyTrialConfig copyWith({int? trialOrder}) {
    return StudyTrialConfig(
      participantId: participantId,
      condition: condition,
      trialOrder: trialOrder ?? this.trialOrder,
    );
  }
}

enum YogaPoseDifficulty {
  beginner('Beginner', 1),
  intermediate('Intermediate', 2),
  advanced('Advanced', 3);

  final String label;
  final int indicatorCount;

  const YogaPoseDifficulty(this.label, this.indicatorCount);
}

class YogaPose {
  final String id;
  final String name;
  final String instruction;
  final String imageAsset;
  final YogaPoseDifficulty difficulty;
  final bool isEvaluationAvailable;

  const YogaPose({
    required this.id,
    required this.name,
    required this.instruction,
    required this.imageAsset,
    required this.difficulty,
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
}

class PoseEvaluationResult {
  final int score;
  final List<PostureError> errors;
  final List<PoseMarkerFeedback> markerFeedback;

  const PoseEvaluationResult({
    required this.score,
    required this.errors,
    this.markerFeedback = const [],
  });

  bool get hasErrors => errors.isNotEmpty;
}

/// Outcome of one 30-second hold. A trial without enough valid scoring
/// windows carries no numerical score ([evaluation] is null).
class YogaHoldSummary {
  final PoseEvaluationResult? evaluation;
  final int validWindowCount;
  final int windowCount;
  final String? invalidReason;

  const YogaHoldSummary({
    required this.evaluation,
    required this.validWindowCount,
    required this.windowCount,
    this.invalidReason,
  });

  bool get isValid => evaluation != null;
}

enum PoseMarkerType {
  head,
  leftHand,
  rightHand,
}

enum PoseMarkerStatus {
  good,
  warning,
  bad,
  noData,
}

class PoseMarkerFeedback {
  final PoseMarkerType type;
  final PoseMarkerStatus status;
  final String? message;
  final double? measuredValue;
  final double? distanceFromTargetDegrees;

  const PoseMarkerFeedback({
    required this.type,
    required this.status,
    this.message,
    this.measuredValue,
    this.distanceFromTargetDegrees,
  });
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
  static const double armElevationPerfectMinDegrees = 83;
  static const double armElevationPerfectMaxDegrees = 97;
  static const double armElevationGoodMinDegrees = 75;
  static const double armElevationGoodMaxDegrees = 105;
  static const double armHeightDifferencePerfectDegrees = 7;
  static const double armHeightDifferenceGoodDegrees = 14;
  static const double palmRotationPerfectMinDegrees = 78;
  static const double palmRotationPerfectMaxDegrees = 102;
  static const double palmRotationGoodMinDegrees = 65;
  static const double palmRotationGoodMaxDegrees = 115;
  static const double palmRotationSevereLowDegrees = 35;
  static const double palmRotationSevereHighDegrees = 125;
  static const double headPitchRollPerfectDegrees = 7;
  static const double headPitchRollGoodDegrees = 14;
  static const double armGyroInstability = 140;
  static const double headGyroInstability = 140;
  static const double calibrationGyroInstability = 80;

  static const double chairArmElevationPerfectMinDegrees = 160;
  static const double chairArmElevationGoodMinDegrees = 145;
  static const double chairArmSymmetryPerfectDegrees = 7;
  static const double chairArmSymmetryGoodDegrees = 14;
  static const double chairHandSymmetryPerfectDegrees = 12;
  static const double chairHandSymmetryGoodDegrees = 24;
  static const double chairHeadPitchGoodDegrees = 24;
  static const double chairHeadRollGoodDegrees = 14;

  static const double triangleUpperArmPerfectMinDegrees = 160;
  static const double triangleUpperArmGoodMinDegrees = 145;
  static const double triangleLowerArmPerfectMaxDegrees = 35;
  static const double triangleLowerArmGoodMaxDegrees = 50;
  static const double triangleArmLinePerfectDifferenceDegrees = 145;
  static const double triangleArmLineGoodDifferenceDegrees = 125;
  static const double triangleHeadPitchPerfectDegrees = 24;
  static const double triangleHeadPitchGoodDegrees = 35;
  static const double triangleHeadRollPerfectDegrees = 18;
  static const double triangleHeadRollGoodDegrees = 30;

  static const double cobraHeadLiftPerfectMinDegrees = 17;
  static const double cobraHeadLiftPerfectMaxDegrees = 43;
  static const double cobraHeadLiftGoodMinDegrees = 12;
  static const double cobraHeadLiftGoodMaxDegrees = 55;
  static const double cobraHeadRollPerfectDegrees = 7;
  static const double cobraHeadRollGoodDegrees = 14;
  static const double cobraHandSymmetryPerfectDegrees = 12;
  static const double cobraHandSymmetryGoodDegrees = 20;

  // Cutoffs above/below which an error is reported as severe instead of
  // medium. Kept together so the rule set stays documentable for the study.
  static const double armElevationSevereLowDegrees = 70;
  static const double armElevationSevereHighDegrees = 110;
  static const double armHeightDifferenceSevereDegrees = 20;
  static const double headTiltSevereDegrees = 20;
  static const double genericHeadTiltSevereDegrees = 30;
  static const double overheadArmSevereLowDegrees = 130;
  static const double triangleLowerArmSevereHighDegrees = 65;
  static const double triangleArmLineSevereDegrees = 110;
  static const double cobraHeadRollSevereDegrees = 20;
}

const YogaPose warriorTwoPose = YogaPose(
  id: 'warrior_ii',
  name: 'Warrior II',
  instruction:
      'Step into a wide stance, raise your arms to shoulder height, bend your front knee softly, and gaze over your front hand.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/warrior_ii_pose2.png',
  difficulty: YogaPoseDifficulty.intermediate,
  isEvaluationAvailable: true,
);

const YogaPose trianglePose = YogaPose(
  id: 'triangle',
  name: 'Triangle',
  instruction:
      'Stand in a wide stance, reach one hand toward your front leg, extend the other arm upward, and turn your gaze toward the upper hand.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/triangle_pose.png',
  difficulty: YogaPoseDifficulty.intermediate,
  isEvaluationAvailable: true,
);

const YogaPose chairPose = YogaPose(
  id: 'chair',
  name: 'Chair',
  instruction:
      'Bend your knees, sit your hips back, keep your chest lifted, and reach both arms upward.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/chair_pose.png',
  difficulty: YogaPoseDifficulty.beginner,
  isEvaluationAvailable: true,
);

const YogaPose cobraPose = YogaPose(
  id: 'cobra',
  name: 'Cobra',
  instruction:
      'Lie on your front, place your hands beside the ribs, and gently lift your head and chest forward.',
  imageAsset: 'lib/apps/yoga_posture_tracker/assets/cobra_pose.png',
  difficulty: YogaPoseDifficulty.beginner,
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
