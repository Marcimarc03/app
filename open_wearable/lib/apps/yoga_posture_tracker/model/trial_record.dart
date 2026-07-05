import 'dart:convert';

import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

/// One scoring window inside a hold, as recorded for the study export.
class TrialWindowRecord {
  final int index;
  final bool isValid;
  final int? score;
  final int sampleCount;
  final List<String> errorCodes;

  const TrialWindowRecord({
    required this.index,
    required this.isValid,
    required this.score,
    required this.sampleCount,
    required this.errorCodes,
  });

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'isValid': isValid,
      'score': score,
      'sampleCount': sampleCount,
      'errorCodes': errorCodes,
    };
  }
}

/// One coaching cue that was generated during a hold.
class TrialFeedbackEvent {
  final String timestamp;
  final String text;

  /// 'llm', 'template', or 'static' (deterministic setup instruction).
  final String source;

  /// Whether the cue was handed to TTS and playback finished without being
  /// skipped or cancelled.
  final bool spoken;

  const TrialFeedbackEvent({
    required this.timestamp,
    required this.text,
    required this.source,
    required this.spoken,
  });

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp,
      'text': text,
      'source': source,
      'spoken': spoken,
    };
  }
}

/// Structured record of one yoga trial for the user study.
///
/// Contains no API keys and no personal information beyond the
/// researcher-assigned participant ID.
class TrialRecord {
  final String sessionId;
  final String appVersion;
  final String? participantId;
  final String? trialId;
  final int? trialOrder;
  final String condition;
  final String poseId;
  final Map<String, String> phaseTimestamps;
  final int calibrationAttempts;
  final bool calibrationValid;
  final Map<String, int> calibrationSampleCounts;
  final List<TrialWindowRecord> windows;
  final int validWindowCount;
  final int? finalScore;
  final List<PostureError> postureErrors;
  final List<TrialFeedbackEvent> feedbackEvents;
  final String? cancellationReason;

  /// 'completed', 'invalid', or 'cancelled'.
  final String completionStatus;

  const TrialRecord({
    required this.sessionId,
    required this.appVersion,
    required this.participantId,
    required this.trialId,
    required this.trialOrder,
    required this.condition,
    required this.poseId,
    required this.phaseTimestamps,
    required this.calibrationAttempts,
    required this.calibrationValid,
    required this.calibrationSampleCounts,
    required this.windows,
    required this.validWindowCount,
    required this.finalScore,
    required this.postureErrors,
    required this.feedbackEvents,
    required this.cancellationReason,
    required this.completionStatus,
  });

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'appVersion': appVersion,
      'participantId': participantId,
      'trialId': trialId,
      'trialOrder': trialOrder,
      'condition': condition,
      'poseId': poseId,
      'phaseTimestamps': phaseTimestamps,
      'calibrationAttempts': calibrationAttempts,
      'calibrationValid': calibrationValid,
      'calibrationSampleCounts': calibrationSampleCounts,
      'windows': windows.map((window) => window.toJson()).toList(),
      'validWindowCount': validWindowCount,
      'finalScore': finalScore,
      'postureErrors': [
        for (final error in postureErrors)
          {
            'code': error.code,
            'message': error.message,
            'severity': error.severity.name,
            'measuredValue': error.measuredValue,
            'threshold': error.threshold,
            'occurrenceCount': error.occurrenceCount,
            'evaluatedWindowCount': error.evaluatedWindowCount,
          },
      ],
      'feedbackEvents': feedbackEvents.map((event) => event.toJson()).toList(),
      'cancellationReason': cancellationReason,
      'completionStatus': completionStatus,
    };
  }

  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  static const String csvHeader =
      'sessionId,appVersion,participantId,trialId,trialOrder,condition,'
      'poseId,completionStatus,cancellationReason,calibrationAttempts,'
      'calibrationValid,windowCount,validWindowCount,finalScore,'
      'windowScores,errorCodes,holdStartedAt,resultAt';

  String toCsvRow() {
    final fields = [
      sessionId,
      appVersion,
      participantId ?? '',
      trialId ?? '',
      trialOrder?.toString() ?? '',
      condition,
      poseId,
      completionStatus,
      cancellationReason ?? '',
      calibrationAttempts.toString(),
      calibrationValid.toString(),
      windows.length.toString(),
      validWindowCount.toString(),
      finalScore?.toString() ?? '',
      windows.map((window) => window.score?.toString() ?? 'invalid').join(';'),
      postureErrors
          .map((error) => '${error.code}x${error.occurrenceCount}')
          .join(';'),
      phaseTimestamps[YogaSessionPhase.holdingPose.name] ?? '',
      phaseTimestamps[YogaSessionPhase.result.name] ?? '',
    ];
    return fields.map(_escapeCsvField).join(',');
  }

  static String toCsv(Iterable<TrialRecord> records) {
    return [
      csvHeader,
      for (final record in records) record.toCsvRow(),
    ].join('\n');
  }

  static String _escapeCsvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

/// Mutable collector used by the session controller while a trial runs.
class TrialRecordBuilder {
  final String sessionId;
  final String appVersion;
  final String poseId;
  final StudyTrialConfig? studyConfig;
  final Map<String, String> phaseTimestamps = {};
  final Map<String, int> calibrationSampleCounts = {};
  final List<TrialWindowRecord> windows = [];
  final List<TrialFeedbackEvent> feedbackEvents = [];
  int calibrationAttempts = 0;
  bool calibrationValid = false;
  int? finalScore;
  List<PostureError> postureErrors = const [];
  String? cancellationReason;
  String completionStatus = 'cancelled';

  TrialRecordBuilder({
    required this.sessionId,
    required this.appVersion,
    required this.poseId,
    required this.studyConfig,
  });

  void markPhase(YogaSessionPhase phase) {
    phaseTimestamps[phase.name] = DateTime.now().toIso8601String();
  }

  void recordCalibrationAttempt({
    required bool accepted,
    required SensorWindowQuality quality,
  }) {
    calibrationAttempts += 1;
    calibrationValid = accepted;
    calibrationSampleCounts
      ..clear()
      ..addEntries(
        quality.streams.map(
          (stream) => MapEntry(stream.label, stream.sampleCount),
        ),
      );
  }

  void recordWindow({
    required int index,
    required bool isValid,
    required int sampleCount,
    PoseEvaluationResult? result,
  }) {
    windows.add(
      TrialWindowRecord(
        index: index,
        isValid: isValid,
        score: result?.score,
        sampleCount: sampleCount,
        errorCodes: [
          for (final error in result?.errors ?? const <PostureError>[])
            error.code,
        ],
      ),
    );
  }

  void recordFeedback({
    required String text,
    required String source,
    required bool spoken,
  }) {
    feedbackEvents.add(
      TrialFeedbackEvent(
        timestamp: DateTime.now().toIso8601String(),
        text: text,
        source: source,
        spoken: spoken,
      ),
    );
  }

  int get validWindowCount => windows.where((window) => window.isValid).length;

  TrialRecord build() {
    return TrialRecord(
      sessionId: sessionId,
      appVersion: appVersion,
      participantId: studyConfig?.participantId,
      trialId: studyConfig?.trialId,
      trialOrder: studyConfig?.trialOrder,
      condition: studyConfig?.condition.name ?? 'free',
      poseId: poseId,
      phaseTimestamps: Map.of(phaseTimestamps),
      calibrationAttempts: calibrationAttempts,
      calibrationValid: calibrationValid,
      calibrationSampleCounts: Map.of(calibrationSampleCounts),
      windows: List.of(windows),
      validWindowCount: validWindowCount,
      finalScore: finalScore,
      postureErrors: List.of(postureErrors),
      feedbackEvents: List.of(feedbackEvents),
      cancellationReason: cancellationReason,
      completionStatus: completionStatus,
    );
  }
}
