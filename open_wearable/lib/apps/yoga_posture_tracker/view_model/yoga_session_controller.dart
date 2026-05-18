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
  static const Duration holdDuration = Duration(seconds: 30);
  static const Duration coachingWindowDuration = Duration(seconds: 5);

  final YogaSensorService _sensorService;
  final RuleBasedPoseEvaluator _poseEvaluator;
  final LlmFeedbackService _llmFeedbackService;
  final TtsFeedbackService _ttsFeedbackService;

  YogaSessionPhase _phase = YogaSessionPhase.idle;
  YogaDeviceSet _devices = const YogaDeviceSet(earable: null, rings: []);
  CalibrationData? _calibrationData;
  PoseEvaluationResult? _evaluationResult;
  YogaFeedback? _feedback;
  SensorWindowQuality? _latestSignalQuality;
  RingAssignment _ringAssignment = const RingAssignment();
  int _remainingSeconds = 0;
  int _operationGeneration = 0;
  bool _isDisposed = false;
  bool _stopRequested = false;
  Completer<void>? _cancelCompleter;

  YogaSessionController({
    YogaSensorService? sensorService,
    RuleBasedPoseEvaluator? poseEvaluator,
    LlmFeedbackService? llmFeedbackService,
    TtsFeedbackService? ttsFeedbackService,
  })  : _sensorService = sensorService ?? YogaSensorService(),
        _poseEvaluator = poseEvaluator ?? const RuleBasedPoseEvaluator(),
        _llmFeedbackService = llmFeedbackService ?? GeminiLlmFeedbackService(),
        _ttsFeedbackService =
            ttsFeedbackService ?? const LoggingTtsFeedbackService() {
    _cancelCompleter = Completer<void>();
  }

  YogaSessionPhase get phase => _phase;
  YogaDeviceSet get devices => _devices;
  PoseEvaluationResult? get evaluationResult => _evaluationResult;
  YogaFeedback? get feedback => _feedback;
  SensorWindowQuality? get latestSignalQuality => _latestSignalQuality;
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
    _notifyListeners();
  }

  Future<void> startSession(WearablesProvider wearablesProvider) async {
    _startNewOperation();
    logger.i('Yoga session start');
    _evaluationResult = null;
    _feedback = null;
    _latestSignalQuality = null;
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
    _notifyListeners();
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
    final generation = _operationGeneration;
    _setPhase(YogaSessionPhase.calibrating);
    logger.i('Yoga calibration start');
    final collectionFuture = _sensorService.collectWindow(
      devices: _devices,
      wearablesProvider: wearablesProvider,
      duration: calibrationDuration,
      cancelSignal: _cancelSignal,
    );
    final completed = await _countDown(
      calibrationDuration,
      generation: generation,
    );
    final baselineWindow = await collectionFuture;
    if (!completed || !_isOperationActive(generation)) {
      return;
    }
    _latestSignalQuality = _sensorService.assessSignalQuality(
      devices: _devices,
      window: baselineWindow,
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

    final generation = _operationGeneration;
    _setPhase(YogaSessionPhase.holdingPose);
    _remainingSeconds = holdDuration.inSeconds;
    _notifyListeners();

    final windowResults = <PoseEvaluationResult>[];
    var secondsCollected = 0;
    while (secondsCollected < holdDuration.inSeconds &&
        _isOperationActive(generation)) {
      final remaining = holdDuration.inSeconds - secondsCollected;
      final windowSeconds = remaining < coachingWindowDuration.inSeconds
          ? remaining
          : coachingWindowDuration.inSeconds;
      final windowDuration = Duration(seconds: windowSeconds);

      final collectionFuture = _sensorService.collectWindow(
        devices: _devices,
        wearablesProvider: wearablesProvider,
        duration: windowDuration,
        cancelSignal: _cancelSignal,
      );
      final completed = await _countDownSegment(
        windowDuration,
        generation: generation,
      );
      final poseWindow = await collectionFuture;
      if (!completed || !_isOperationActive(generation)) {
        return;
      }
      secondsCollected += windowSeconds;
      _latestSignalQuality = _sensorService.assessSignalQuality(
        devices: _devices,
        window: poseWindow,
        duration: windowDuration,
      );

      final result = _poseEvaluator.evaluateWarriorTwo(
        calibration: calibrationData,
        poseWindow: poseWindow,
      );
      windowResults.add(result);
      _evaluationResult = result;
      logger.i(
        'Yoga live evaluation result: score=${result.score}, '
        'errors=${result.errors.map((error) => error.code).join(', ')}',
      );

      final generatedFeedback = await _llmFeedbackService.generateYogaFeedback(
        postureErrors: result.errors,
        poseName: pose.name,
        score: result.score,
      );
      if (!_isOperationActive(generation)) {
        return;
      }
      _feedback = generatedFeedback;
      logger.i(
        'Yoga live feedback generated: ${generatedFeedback.recommendation}',
      );
      _notifyListeners();
      await _ttsFeedbackService.speak(generatedFeedback.recommendation);
    }

    if (!_isOperationActive(generation)) {
      return;
    }
    _setPhase(YogaSessionPhase.evaluating);
    final finalResult = _poseEvaluator.aggregateWindowResults(windowResults);
    _evaluationResult = finalResult;
    final finalFeedback = await _llmFeedbackService.generateYogaFeedback(
      postureErrors: finalResult.errors,
      poseName: pose.name,
      score: finalResult.score,
    );
    if (!_isOperationActive(generation)) {
      return;
    }
    _feedback = finalFeedback;
    logger.i(
      'Yoga final evaluation result: score=${finalResult.score}, '
      'errors=${finalResult.errors.map((error) => error.code).join(', ')}',
    );
    _setPhase(YogaSessionPhase.feedback);
    _setPhase(YogaSessionPhase.result);
  }

  Future<void> restartSession(WearablesProvider wearablesProvider) async {
    _calibrationData = null;
    _evaluationResult = null;
    _feedback = null;
    _latestSignalQuality = null;
    _ringAssignment = const RingAssignment();
    await startSession(wearablesProvider);
  }

  Future<void> stopSession(WearablesProvider wearablesProvider) async {
    final devices = _devices;
    _requestStop();
    await _sensorService.turnOffYogaSensors(
      devices: devices,
      wearablesProvider: wearablesProvider,
    );
    _remainingSeconds = 0;
    _latestSignalQuality = null;
    _setPhase(YogaSessionPhase.idle);
  }

  Future<void> shutdown(WearablesProvider wearablesProvider) async {
    final devices = _devices;
    _requestStop();
    await _sensorService.turnOffYogaSensors(
      devices: devices,
      wearablesProvider: wearablesProvider,
    );
  }

  void _setPhase(YogaSessionPhase phase) {
    if (_isDisposed) {
      return;
    }
    _phase = phase;
    _notifyListeners();
  }

  Future<bool> _countDown(
    Duration duration, {
    required int generation,
  }) async {
    _remainingSeconds = duration.inSeconds;
    _notifyListeners();
    for (var second = duration.inSeconds; second > 0; second--) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!_isOperationActive(generation)) {
        return false;
      }
      _remainingSeconds = second - 1;
      _notifyListeners();
    }
    return true;
  }

  Future<bool> _countDownSegment(
    Duration duration, {
    required int generation,
  }) async {
    for (var second = 0; second < duration.inSeconds; second++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!_isOperationActive(generation)) {
        return false;
      }
      _remainingSeconds =
          (_remainingSeconds - 1).clamp(0, holdDuration.inSeconds);
      _notifyListeners();
    }
    return true;
  }

  Future<void>? get _cancelSignal => _cancelCompleter?.future;

  int _startNewOperation() {
    _requestStop();
    _stopRequested = false;
    _cancelCompleter = Completer<void>();
    _operationGeneration += 1;
    return _operationGeneration;
  }

  void _requestStop() {
    _stopRequested = true;
    _operationGeneration += 1;
    final cancelCompleter = _cancelCompleter;
    if (cancelCompleter != null && !cancelCompleter.isCompleted) {
      cancelCompleter.complete();
    }
  }

  bool _isOperationActive(int generation) {
    return !_isDisposed &&
        !_stopRequested &&
        generation == _operationGeneration;
  }

  void _notifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _requestStop();
    super.dispose();
  }
}
