import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/calibration_countdown_sound_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/llm_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/rule_based_pose_evaluator.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/tts_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_sensor_service.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';

class YogaSessionController with ChangeNotifier {
  static const Duration calibrationDuration = Duration(seconds: 3);
  static const Duration holdDuration = Duration(seconds: 30);
  static const Duration firstCoachingWindowDuration = Duration(seconds: 7);
  static const Duration coachingWindowDuration = Duration(seconds: 5);
  static const String _finalWindowMotivation = 'Good job, keep going.';

  final YogaSensorService _sensorService;
  final RuleBasedPoseEvaluator _poseEvaluator;
  final LlmFeedbackService _llmFeedbackService;
  final TtsFeedbackService _ttsFeedbackService;
  final CalibrationCountdownSoundService _countdownSoundService;

  YogaSessionPhase _phase = YogaSessionPhase.idle;
  YogaDeviceSet _devices = const YogaDeviceSet(earable: null, rings: []);
  CalibrationData? _calibrationData;
  PoseEvaluationResult? _evaluationResult;
  YogaFeedback? _feedback;
  YogaFeedback? _poseSetupFeedback;
  SensorWindowQuality? _latestSignalQuality;
  String? _calibrationWarning;
  final ValueNotifier<List<PoseMarkerFeedback>> _livePoseMarkerFeedback =
      ValueNotifier<List<PoseMarkerFeedback>>(const []);
  RingAssignment _ringAssignment = const RingAssignment();
  YogaPose _selectedPose = warriorTwoPose;
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
    CalibrationCountdownSoundService? countdownSoundService,
  })  : _sensorService = sensorService ?? YogaSensorService(),
        _poseEvaluator = poseEvaluator ?? const RuleBasedPoseEvaluator(),
        _llmFeedbackService = llmFeedbackService ?? GeminiLlmFeedbackService(),
        _ttsFeedbackService = ttsFeedbackService ??
            YogaTtsFeedbackServiceFactory.fromEnvironment(),
        _countdownSoundService =
            countdownSoundService ?? GeneratedBeepCountdownSoundService() {
    _cancelCompleter = Completer<void>();
  }

  YogaSessionPhase get phase => _phase;
  YogaDeviceSet get devices => _devices;
  PoseEvaluationResult? get evaluationResult => _evaluationResult;
  YogaFeedback? get feedback => _feedback;
  YogaFeedback? get poseSetupFeedback => _poseSetupFeedback;
  SensorWindowQuality? get latestSignalQuality => _latestSignalQuality;
  String? get calibrationWarning => _calibrationWarning;
  ValueListenable<List<PoseMarkerFeedback>> get livePoseMarkerFeedback =>
      _livePoseMarkerFeedback;
  RingAssignment get ringAssignment => _ringAssignment;
  int get remainingSeconds => _remainingSeconds;
  YogaPose get pose => _selectedPose;
  List<YogaPose> get availablePoses => yogaPostureTrackerPoses;
  String get poseSetupInstruction {
    return _poseSetupFeedback?.recommendation ?? pose.instruction;
  }

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

  bool get canNavigateBack {
    return switch (_phase) {
      YogaSessionPhase.idle => false,
      _ => true,
    };
  }

  void refreshDevices(WearablesProvider wearablesProvider) {
    _devices = _sensorService.resolveDevices(wearablesProvider);
    _notifyListeners();
  }

  Future<void> startSession(
    WearablesProvider wearablesProvider, {
    RingAssignment? ringAssignment,
  }) async {
    _startNewOperation();
    await _stopFeedbackPlayback();
    logger.i('Yoga session start');
    _evaluationResult = null;
    _feedback = null;
    _poseSetupFeedback = null;
    _latestSignalQuality = null;
    _calibrationWarning = null;
    _setLivePoseMarkerFeedback(const []);
    _setPhase(YogaSessionPhase.checkingDevices);
    _devices = _sensorService.resolveDevices(wearablesProvider);
    _ringAssignment = _ringAssignmentForDevices(
      ringAssignment ?? _ringAssignment,
      devices: _devices,
    );
    if (!_ringAssignment.isValid) {
      _ringAssignment = _sensorService.defaultRingAssignment(_devices);
    }
    _devices = _devices.copyWith(ringAssignment: _ringAssignment);
    logger.i(
      'Yoga devices: earable=${_devices.earable?.name ?? 'none'}, '
      'rings=${_devices.rings.map((ring) => ring.name).join(', ')}',
    );
    if (!_devices.hasEarable ||
        !_devices.hasTwoRings ||
        !_ringAssignment.isValid) {
      _setPhase(YogaSessionPhase.idle);
      return;
    }
    _setPhase(YogaSessionPhase.poseSelection);
  }

  void selectPose(YogaPose pose) {
    _selectedPose = pose;
    _calibrationData = null;
    _evaluationResult = null;
    _feedback = null;
    _poseSetupFeedback = null;
    _latestSignalQuality = null;
    _calibrationWarning = null;
    _setLivePoseMarkerFeedback(const []);
    _remainingSeconds = 0;
    _setPhase(YogaSessionPhase.calibrationInstructions);
  }

  void updateRingAssignment({
    String? leftRingId,
    String? rightRingId,
  }) {
    var assignment = _ringAssignment;
    if (leftRingId != null) {
      assignment = assignment.assignLeftRing(leftRingId);
    }
    if (rightRingId != null) {
      assignment = assignment.assignRightRing(rightRingId);
    }
    _ringAssignment = assignment;
    _devices = _devices.copyWith(ringAssignment: _ringAssignment);
    _notifyListeners();
  }

  Future<void> beginCalibration(WearablesProvider wearablesProvider) async {
    if (!_devices.hasEarable ||
        !_devices.hasTwoRings ||
        !_ringAssignment.isValid) {
      _setPhase(YogaSessionPhase.idle);
      return;
    }
    if (!pose.isEvaluationAvailable) {
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }
    final generation = _operationGeneration;
    await _stopFeedbackPlayback();
    await _stopCalibrationCountdownSound();
    if (!_isOperationActive(generation)) {
      return;
    }
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
      playCalibrationSounds: true,
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
    final calibrationErrors = _poseEvaluator.evaluateCalibrationStability(
      baselineWindow: baselineWindow,
      ringAssignment: _ringAssignment,
    );
    if (calibrationErrors.isNotEmpty) {
      _calibrationData = null;
      _calibrationWarning = _buildCalibrationWarning(calibrationErrors);
      logger.i(
        'Yoga calibration rejected: '
        '${calibrationErrors.map((error) => error.code).join(', ')}',
      );
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }
    _calibrationWarning = null;
    _calibrationData = CalibrationData.fromWindow(
      baselineWindow: baselineWindow,
      ringAssignment: _ringAssignment,
    );
    logger.i(
      'Yoga calibration end with ${baselineWindow.totalSampleCount} samples',
    );
    _setPhase(YogaSessionPhase.poseInstructions);
  }

  Future<void> beginPoseHold(WearablesProvider wearablesProvider) async {
    if (!pose.isEvaluationAvailable) {
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }

    final calibrationData = _calibrationData;
    if (calibrationData == null) {
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }
    await _stopCalibrationCountdownSound();

    final generation = _operationGeneration;
    _setPhase(YogaSessionPhase.holdingPose);
    _remainingSeconds = holdDuration.inSeconds;
    _notifyListeners();
    unawaited(
      _speakPoseSetupInstruction(
        generation,
        requiredPhase: YogaSessionPhase.holdingPose,
      ),
    );

    final poseStream = _sensorService.startContinuousImuStreaming(
      devices: _devices,
      wearablesProvider: wearablesProvider,
    );
    final liveMarkerSubscription = _startLivePoseMarkerFeedbackUpdates(
      generation: generation,
      calibration: calibrationData,
      poseStream: poseStream,
    );
    final windowResults = <PoseEvaluationResult>[];
    var secondsCollected = 0;
    var liveFeedbackInFlight = false;
    var finalWindowMotivationSpoken = false;
    try {
      while (secondsCollected < holdDuration.inSeconds &&
          _isOperationActive(generation)) {
        final remaining = holdDuration.inSeconds - secondsCollected;
        final coachingDuration = secondsCollected == 0
            ? firstCoachingWindowDuration
            : coachingWindowDuration;
        final windowSeconds = remaining < coachingDuration.inSeconds
            ? remaining
            : coachingDuration.inSeconds;
        final windowDuration = Duration(seconds: windowSeconds);

        final completed = await _countDownSegment(
          windowDuration,
          generation: generation,
        );
        if (!completed || !_isOperationActive(generation)) {
          return;
        }
        secondsCollected += windowSeconds;
        final poseWindow = poseStream.drainWindow();
        _latestSignalQuality = _sensorService.assessSignalQuality(
          devices: _devices,
          window: poseWindow,
          duration: windowDuration,
        );

        final result = _poseEvaluator.evaluatePose(
          pose: pose,
          calibration: calibrationData,
          poseWindow: poseWindow,
        );
        windowResults.add(result);
        _evaluationResult = result;
        logger.i(
          'Yoga live evaluation result: score=${result.score}, '
          'errors=${result.errors.map((error) => error.code).join(', ')}',
        );
        _notifyListeners();

        final isFinalWindow = secondsCollected >= holdDuration.inSeconds;
        final isEnteringFinalWindow = !isFinalWindow &&
            holdDuration.inSeconds - secondsCollected <=
                coachingWindowDuration.inSeconds;
        if (isEnteringFinalWindow && !finalWindowMotivationSpoken) {
          finalWindowMotivationSpoken = true;
          unawaited(_speakFinalWindowMotivation(generation));
        } else if (!isFinalWindow && !liveFeedbackInFlight) {
          liveFeedbackInFlight = true;
          unawaited(
            _generateAndSpeakLiveFeedback(
              generation: generation,
              result: result,
              shouldSpeak: () =>
                  _remainingSeconds > coachingWindowDuration.inSeconds,
            ).whenComplete(() {
              liveFeedbackInFlight = false;
            }),
          );
        }
      }
    } finally {
      await liveMarkerSubscription?.cancel();
      _setLivePoseMarkerFeedback(const []);
      await poseStream.dispose();
    }

    if (!_isOperationActive(generation)) {
      return;
    }
    _setPhase(YogaSessionPhase.evaluating);
    await _stopFeedbackPlayback();
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

  Future<void> _generateAndSpeakLiveFeedback({
    required int generation,
    required PoseEvaluationResult result,
    bool Function()? shouldSpeak,
  }) async {
    try {
      final generatedFeedback = await _llmFeedbackService.generateYogaFeedback(
        postureErrors: result.errors,
        poseName: pose.name,
        score: result.score,
      );
      if (!_isOperationActive(generation) ||
          _phase != YogaSessionPhase.holdingPose ||
          !(shouldSpeak?.call() ?? true)) {
        return;
      }
      _feedback = generatedFeedback;
      logger.i(
        'Yoga live feedback generated: ${generatedFeedback.recommendation}',
      );
      _notifyListeners();
      await _ttsFeedbackService.speak(generatedFeedback.recommendation);
    } catch (error, stackTrace) {
      logger.w(
        'Yoga live feedback generation failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  StreamSubscription<SensorWindow>? _startLivePoseMarkerFeedbackUpdates({
    required int generation,
    required CalibrationData calibration,
    required YogaImuStreamSession poseStream,
  }) {
    if (pose.id != warriorTwoPose.id) {
      _setLivePoseMarkerFeedback(const []);
      return null;
    }

    return poseStream.liveWindows.listen((poseWindow) {
      if (!_isOperationActive(generation) ||
          _phase != YogaSessionPhase.holdingPose) {
        return;
      }
      _setLivePoseMarkerFeedback(
        _poseEvaluator.evaluatePoseMarkers(
          pose: pose,
          calibration: calibration,
          poseWindow: poseWindow,
        ),
      );
    });
  }

  Future<void> _speakFinalWindowMotivation(int generation) async {
    try {
      if (!_isOperationActive(generation) ||
          _phase != YogaSessionPhase.holdingPose) {
        return;
      }
      _feedback = const YogaFeedback(recommendation: _finalWindowMotivation);
      logger.i('Yoga final hold motivation: $_finalWindowMotivation');
      _notifyListeners();
      await _ttsFeedbackService.speak(_finalWindowMotivation);
    } catch (error, stackTrace) {
      logger.w(
        'Yoga final hold motivation playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _speakPoseSetupInstruction(
    int generation, {
    required YogaSessionPhase requiredPhase,
  }) async {
    try {
      final instruction = pose.instruction.trim();
      if (instruction.isEmpty ||
          !_isOperationActive(generation) ||
          _phase != requiredPhase) {
        return;
      }
      _poseSetupFeedback = YogaFeedback(
        recommendation: instruction,
      );
      logger.i(
        'Yoga pose setup instruction spoken from static pose instruction: '
        '$instruction',
      );
      _notifyListeners();
      await _ttsFeedbackService.speak(instruction);
    } catch (error, stackTrace) {
      logger.w(
        'Yoga pose setup instruction playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> restartSession(WearablesProvider wearablesProvider) async {
    await _stopFeedbackPlayback();
    _calibrationData = null;
    _evaluationResult = null;
    _feedback = null;
    _poseSetupFeedback = null;
    _latestSignalQuality = null;
    _calibrationWarning = null;
    _setLivePoseMarkerFeedback(const []);
    _ringAssignment = const RingAssignment();
    await startSession(wearablesProvider);
  }

  Future<void> stopSession(WearablesProvider wearablesProvider) async {
    final devices = _devices;
    _requestStop();
    await _stopFeedbackPlayback();
    await _stopCalibrationCountdownSound();
    await _sensorService.turnOffYogaSensors(
      devices: devices,
      wearablesProvider: wearablesProvider,
    );
    _remainingSeconds = 0;
    _latestSignalQuality = null;
    _setLivePoseMarkerFeedback(const []);
    _setPhase(YogaSessionPhase.idle);
  }

  Future<void> navigateBack(WearablesProvider wearablesProvider) async {
    if (!canNavigateBack) {
      return;
    }

    switch (_phase) {
      case YogaSessionPhase.checkingDevices:
        _startNewOperation();
        await _stopFeedbackPlayback();
        _setPhase(YogaSessionPhase.idle);
        return;
      case YogaSessionPhase.poseSelection:
        _calibrationData = null;
        _evaluationResult = null;
        _feedback = null;
        _poseSetupFeedback = null;
        _latestSignalQuality = null;
        _calibrationWarning = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        _setPhase(YogaSessionPhase.idle);
        return;
      case YogaSessionPhase.calibrationInstructions:
        _calibrationData = null;
        _poseSetupFeedback = null;
        _calibrationWarning = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        _setPhase(YogaSessionPhase.poseSelection);
        return;
      case YogaSessionPhase.calibrating:
        _startNewOperation();
        _calibrationData = null;
        _poseSetupFeedback = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        await _stopFeedbackPlayback();
        await _stopCalibrationCountdownSound();
        _setPhase(YogaSessionPhase.calibrationInstructions);
        return;
      case YogaSessionPhase.poseInstructions:
        _calibrationData = null;
        _poseSetupFeedback = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        await _stopFeedbackPlayback();
        _setPhase(YogaSessionPhase.calibrationInstructions);
        return;
      case YogaSessionPhase.holdingPose:
      case YogaSessionPhase.evaluating:
      case YogaSessionPhase.feedback:
        _startNewOperation();
        await _stopFeedbackPlayback();
        await _sensorService.turnOffYogaSensors(
          devices: _devices,
          wearablesProvider: wearablesProvider,
        );
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        _setPhase(YogaSessionPhase.poseInstructions);
        return;
      case YogaSessionPhase.result:
        _feedback = null;
        _evaluationResult = null;
        _latestSignalQuality = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        await _stopFeedbackPlayback();
        _setPhase(YogaSessionPhase.poseSelection);
        return;
      case YogaSessionPhase.idle:
        return;
    }
  }

  Future<void> shutdown(WearablesProvider wearablesProvider) async {
    final devices = _devices;
    _requestStop();
    await _stopFeedbackPlayback();
    await _stopCalibrationCountdownSound();
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
    bool playCalibrationSounds = false,
  }) async {
    _remainingSeconds = duration.inSeconds;
    _notifyListeners();
    for (var second = duration.inSeconds; second > 0; second--) {
      final tickStartedAt = DateTime.now();
      if (playCalibrationSounds) {
        unawaited(_playCalibrationCountdownTick(generation));
      }
      final tickElapsed = DateTime.now().difference(tickStartedAt);
      final remainingTickDelay = const Duration(seconds: 1) - tickElapsed;
      if (remainingTickDelay > Duration.zero) {
        await Future<void>.delayed(remainingTickDelay);
      }
      if (!_isOperationActive(generation)) {
        return false;
      }
      _remainingSeconds = second - 1;
      _notifyListeners();
    }
    if (playCalibrationSounds && _isOperationActive(generation)) {
      unawaited(_countdownSoundService.playCalibrationComplete());
    }
    return true;
  }

  Future<void> _playCalibrationCountdownTick(int generation) async {
    if (!_isOperationActive(generation) ||
        _phase != YogaSessionPhase.calibrating) {
      return;
    }
    await _countdownSoundService.playCountdownTick();
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

  Future<void> _stopFeedbackPlayback() async {
    try {
      await _ttsFeedbackService.stop();
    } catch (error, stackTrace) {
      logger.w(
        'Yoga TTS feedback stop failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _stopCalibrationCountdownSound() async {
    try {
      await _countdownSoundService.stop();
    } catch (error, stackTrace) {
      logger.w(
        'Yoga calibration countdown sound stop failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String _buildCalibrationWarning(List<PostureError> errors) {
    final primary = errors.first;
    final measured = primary.measuredValue.toStringAsFixed(1);
    final threshold = primary.threshold.toStringAsFixed(1);
    return '${primary.message} Measured $measured / threshold $threshold.';
  }

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

  RingAssignment _ringAssignmentForDevices(
    RingAssignment assignment, {
    required YogaDeviceSet devices,
  }) {
    final ringIds = devices.rings.map((ring) => ring.deviceId).toSet();
    return RingAssignment(
      leftRingId: ringIds.contains(assignment.leftRingId)
          ? assignment.leftRingId
          : null,
      rightRingId: ringIds.contains(assignment.rightRingId)
          ? assignment.rightRingId
          : null,
    );
  }

  void _setLivePoseMarkerFeedback(List<PoseMarkerFeedback> markerFeedback) {
    if (!_isDisposed) {
      _livePoseMarkerFeedback.value = markerFeedback;
    }
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
    unawaited(_ttsFeedbackService.dispose());
    unawaited(_countdownSoundService.dispose());
    _livePoseMarkerFeedback.dispose();
    super.dispose();
  }
}
