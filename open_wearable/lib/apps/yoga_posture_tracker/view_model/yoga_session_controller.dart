import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/llm_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/rule_based_pose_evaluator.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/tts_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_sensor_service.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';

class YogaSessionController with ChangeNotifier {
  static const Duration calibrationDuration = Duration(seconds: 3);
  static const Duration holdDuration = Duration(seconds: 5);

  final YogaSensorService _sensorService;
  final RuleBasedPoseEvaluator _poseEvaluator;
  final LlmFeedbackService _llmFeedbackService;
  final TtsFeedbackService _ttsFeedbackService;

  YogaSessionPhase _phase = YogaSessionPhase.idle;
  YogaDeviceSet _devices = const YogaDeviceSet(earable: null, rings: []);
  CalibrationData? _calibrationData;
  PoseEvaluationResult? _evaluationResult;
  YogaFeedback? _feedback;
  RingAssignment _ringAssignment = const RingAssignment();
  int _remainingSeconds = 0;

  YogaSessionController({
    YogaSensorService? sensorService,
    RuleBasedPoseEvaluator? poseEvaluator,
    LlmFeedbackService? llmFeedbackService,
    TtsFeedbackService? ttsFeedbackService,
  })  : _sensorService = sensorService ?? YogaSensorService(),
        _poseEvaluator = poseEvaluator ?? const RuleBasedPoseEvaluator(),
        _llmFeedbackService =
            llmFeedbackService ?? const TemplateLlmFeedbackService(),
        _ttsFeedbackService =
            ttsFeedbackService ?? const LoggingTtsFeedbackService();

  YogaSessionPhase get phase => _phase;
  YogaDeviceSet get devices => _devices;
  PoseEvaluationResult? get evaluationResult => _evaluationResult;
  YogaFeedback? get feedback => _feedback;
  RingAssignment get ringAssignment => _ringAssignment;
  int get remainingSeconds => _remainingSeconds;
  YogaPose get pose => warriorTwoPose;

  bool get isBusy {
    return switch (_phase) {
      YogaSessionPhase.checkingDevices ||
      YogaSessionPhase.calibrating ||
      YogaSessionPhase.holdingPose ||
      YogaSessionPhase.evaluating =>
        true,
      _ => false,
    };
  }

  void refreshDevices(WearablesProvider wearablesProvider) {
    _devices = _sensorService.resolveDevices(wearablesProvider);
    notifyListeners();
  }

  Future<void> startSession(WearablesProvider wearablesProvider) async {
    logger.i('Yoga session start');
    _evaluationResult = null;
    _feedback = null;
    _setPhase(YogaSessionPhase.checkingDevices);
    _devices = _sensorService.resolveDevices(wearablesProvider);
    _ringAssignment = const RingAssignment();
    logger.i(
      'Yoga devices: earable=${_devices.earable?.name ?? 'none'}, '
      'rings=${_devices.rings.map((ring) => ring.name).join(', ')}',
    );
    if (!_devices.hasEarable || !_devices.hasTwoRings) {
      _setPhase(YogaSessionPhase.idle);
      return;
    }
    _setPhase(YogaSessionPhase.assigningRings);
  }

  void updateRingAssignment({
    String? leftRingId,
    String? rightRingId,
  }) {
    _ringAssignment = _ringAssignment.copyWith(
      leftRingId: leftRingId,
      rightRingId: rightRingId,
    );
    _devices = _devices.copyWith(ringAssignment: _ringAssignment);
    notifyListeners();
  }

  void confirmRingAssignment() {
    if (!_devices.hasTwoRings || !_ringAssignment.isValid) {
      return;
    }
    _devices = _devices.copyWith(ringAssignment: _ringAssignment);
    _setPhase(YogaSessionPhase.calibrationInstructions);
  }

  Future<void> beginCalibration(WearablesProvider wearablesProvider) async {
    if (!_devices.hasEarable ||
        !_devices.hasTwoRings ||
        !_ringAssignment.isValid) {
      _setPhase(YogaSessionPhase.assigningRings);
      return;
    }
    _setPhase(YogaSessionPhase.calibrating);
    logger.i('Yoga calibration start');
    await _countDown(calibrationDuration);
    final baselineWindow = await _sensorService.collectWindow(
      devices: _devices,
      wearablesProvider: wearablesProvider,
      duration: calibrationDuration,
    );
    _calibrationData = CalibrationData(
      baselineWindow: baselineWindow,
      ringAssignment: _ringAssignment,
    );
    logger.i(
      'Yoga calibration end with ${baselineWindow.totalSampleCount} samples',
    );
    _setPhase(YogaSessionPhase.poseInstructions);
  }

  Future<void> beginPoseHold(WearablesProvider wearablesProvider) async {
    final calibrationData = _calibrationData;
    if (calibrationData == null) {
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }

    _setPhase(YogaSessionPhase.holdingPose);
    final collectionFuture = _sensorService.collectWindow(
      devices: _devices,
      wearablesProvider: wearablesProvider,
      duration: holdDuration,
    );
    await _countDown(holdDuration);
    final poseWindow = await collectionFuture;

    _setPhase(YogaSessionPhase.evaluating);
    final result = _poseEvaluator.evaluateWarriorTwo(
      calibration: calibrationData,
      poseWindow: poseWindow,
    );
    _evaluationResult = result;
    logger.i(
      'Yoga evaluation result: score=${result.score}, '
      'errors=${result.errors.map((error) => error.code).join(', ')}',
    );

    final generatedFeedback = await _llmFeedbackService.generateYogaFeedback(
      postureErrors: result.errors,
      poseName: pose.name,
      score: result.score,
    );
    _feedback = generatedFeedback;
    logger.i('Yoga feedback generated: ${generatedFeedback.recommendation}');
    _setPhase(YogaSessionPhase.feedback);
    await _ttsFeedbackService.speak(generatedFeedback.recommendation);
    _setPhase(YogaSessionPhase.result);
  }

  Future<void> restartSession(WearablesProvider wearablesProvider) async {
    _calibrationData = null;
    _evaluationResult = null;
    _feedback = null;
    _ringAssignment = const RingAssignment();
    await startSession(wearablesProvider);
  }

  Future<void> stopSession(WearablesProvider wearablesProvider) async {
    await _sensorService.turnOffYogaSensors(
      devices: _devices,
      wearablesProvider: wearablesProvider,
    );
    _remainingSeconds = 0;
    _setPhase(YogaSessionPhase.idle);
  }

  void _setPhase(YogaSessionPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  Future<void> _countDown(Duration duration) async {
    _remainingSeconds = duration.inSeconds;
    notifyListeners();
    for (var second = duration.inSeconds; second > 0; second--) {
      await Future<void>.delayed(const Duration(seconds: 1));
      _remainingSeconds = second - 1;
      notifyListeners();
    }
  }
}
