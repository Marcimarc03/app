import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/trial_record.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/calibration_countdown_sound_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/llm_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/rule_based_pose_evaluator.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/tts_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_sensor_service.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

class YogaSessionController with ChangeNotifier {
  /// Preparation before baseline recording; no sensor data is collected.
  static const Duration calibrationPreparationDuration = Duration(seconds: 5);

  /// The final preparation seconds announced with countdown ticks.
  static const int calibrationAnnouncedSeconds = 3;

  /// Still-baseline recording window.
  static const Duration calibrationDuration = Duration(seconds: 3);

  /// Unscored time to move into the pose before the scored hold starts.
  static const Duration posePreparationDuration = Duration(seconds: 10);

  static const Duration scoringWindowDuration = Duration(seconds: 5);
  static const int scoringWindowCount = 6;

  /// A trial with fewer valid windows carries no numerical score.
  static const int minimumValidWindowCount = 5;

  static const Duration holdDuration =
      Duration(seconds: 30); // scoringWindowCount * scoringWindowDuration

  static const String _finalWindowMotivation = 'Good job, keep going.';
  static const String invalidTrialMessage =
      'Not enough valid sensor data was recorded to score this hold. '
      'Check the device connections and repeat the trial.';
  static const String _calibrationDataMissingMessage =
      'Not enough sensor data was received from all devices during '
      'calibration. Check that the earable and both rings are connected, '
      'then recalibrate.';

  final YogaSensorService _sensorService;
  final RuleBasedPoseEvaluator _poseEvaluator;
  final LlmFeedbackService _llmFeedbackService;
  final TtsFeedbackService _ttsFeedbackService;
  final CalibrationCountdownSoundService _countdownSoundService;

  YogaSessionPhase _phase = YogaSessionPhase.idle;
  YogaDeviceSet _devices = const YogaDeviceSet(earable: null, rings: []);
  CalibrationData? _calibrationData;
  YogaHoldSummary? _holdSummary;
  YogaFeedback? _feedback;
  SensorWindowQuality? _latestSignalQuality;
  String? _calibrationWarning;
  List<String> _capabilityIssues = const [];
  final ValueNotifier<List<PoseMarkerFeedback>> _livePoseMarkerFeedback =
      ValueNotifier<List<PoseMarkerFeedback>>(const []);
  RingAssignment _ringAssignment = const RingAssignment();
  YogaPose _selectedPose = warriorTwoPose;
  int _remainingSeconds = 0;
  int _operationGeneration = 0;
  bool _isDisposed = false;
  bool _stopRequested = false;
  Completer<void>? _cancelCompleter;

  StudyTrialConfig? _studyConfig;
  int _trialCounter = 0;
  TrialRecordBuilder? _trialBuilder;
  final List<TrialRecord> _trialRecords = [];
  final String _sessionId =
      DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  String _appVersion = 'unknown';
  Future<bool>? _setupSpeech;
  int _completedWindowCount = 0;

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
    unawaited(_loadAppVersion());
  }

  YogaSessionPhase get phase => _phase;
  YogaDeviceSet get devices => _devices;
  YogaHoldSummary? get holdSummary => _holdSummary;
  YogaFeedback? get feedback => _feedback;
  SensorWindowQuality? get latestSignalQuality => _latestSignalQuality;
  String? get calibrationWarning => _calibrationWarning;
  List<String> get capabilityIssues => _capabilityIssues;
  ValueListenable<List<PoseMarkerFeedback>> get livePoseMarkerFeedback =>
      _livePoseMarkerFeedback;
  RingAssignment get ringAssignment => _ringAssignment;
  int get remainingSeconds => _remainingSeconds;
  YogaPose get pose => _selectedPose;
  List<YogaPose> get availablePoses => yogaPostureTrackerPoses;
  String get poseSetupInstruction => pose.instruction;
  StudyTrialConfig? get studyConfig => _studyConfig;
  bool get isControlledTrial => _studyConfig != null;
  List<TrialRecord> get trialRecords => List.unmodifiable(_trialRecords);

  /// Live coaching is disabled in the noLiveCoaching study condition.
  bool get liveCoachingEnabled =>
      _studyConfig == null ||
      _studyConfig!.condition == StudyCondition.llmLiveCoaching;

  /// Live correction text and marker overlays are hidden in controlled
  /// trials for both conditions; llmLiveCoaching keeps spoken cues only.
  bool get showLiveFeedbackUi => !isControlledTrial;

  bool get isBusy {
    return switch (_phase) {
      YogaSessionPhase.checkingDevices ||
      YogaSessionPhase.calibrationPreparing ||
      YogaSessionPhase.calibrating ||
      YogaSessionPhase.posePreparing ||
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
    _capabilityIssues = _sensorService.capabilityIssues(_devices);
    _notifyListeners();
  }

  void configureStudyTrial({
    required String participantId,
    required StudyCondition condition,
  }) {
    _studyConfig = StudyTrialConfig(
      participantId: participantId.trim(),
      condition: condition,
      trialOrder: 0,
    );
    _notifyListeners();
  }

  void disableStudyMode() {
    _studyConfig = null;
    _notifyListeners();
  }

  Future<void> playTestSound() {
    return _countdownSoundService.playCalibrationComplete();
  }

  Future<void> startSession(
    WearablesProvider wearablesProvider, {
    RingAssignment? ringAssignment,
  }) async {
    _startNewOperation();
    await _stopFeedbackPlayback();
    logger.i('Yoga session start');
    _holdSummary = null;
    _feedback = null;
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
    _capabilityIssues = _sensorService.capabilityIssues(_devices);
    logger.i(
      'Yoga devices: earable=${_devices.earable?.name ?? 'none'}, '
      'rings=${_devices.rings.map((ring) => ring.name).join(', ')}',
    );
    if (!_devices.hasRequiredSetup || _capabilityIssues.isNotEmpty) {
      _setPhase(YogaSessionPhase.idle);
      return;
    }
    _setPhase(YogaSessionPhase.poseSelection);
  }

  void selectPose(YogaPose pose) {
    _selectedPose = pose;
    _calibrationData = null;
    _holdSummary = null;
    _feedback = null;
    _latestSignalQuality = null;
    _calibrationWarning = null;
    _setLivePoseMarkerFeedback(const []);
    _remainingSeconds = 0;
    _trialCounter += 1;
    _trialBuilder = _newTrialBuilder();
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
    if (!_devices.hasRequiredSetup) {
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
    _trialBuilder ??= _newTrialBuilder();
    _calibrationWarning = null;

    // Preparation without recording; the final seconds are announced.
    _setPhase(YogaSessionPhase.calibrationPreparing);
    logger.i('Yoga calibration preparation start');
    final prepared = await _countDown(
      calibrationPreparationDuration,
      generation: generation,
      tickFromSecond: calibrationAnnouncedSeconds,
      tickPhase: YogaSessionPhase.calibrationPreparing,
    );
    if (!prepared || !_isOperationActive(generation)) {
      return;
    }

    _setPhase(YogaSessionPhase.calibrating);
    logger.i('Yoga calibration recording start');
    final collectionFuture = _sensorService.collectWindow(
      devices: _devices,
      wearablesProvider: wearablesProvider,
      duration: calibrationDuration,
      cancelSignal: _cancelSignal,
    );
    final completed = await _countDown(
      calibrationDuration,
      generation: generation,
      tickFromSecond: calibrationDuration.inSeconds,
      tickPhase: YogaSessionPhase.calibrating,
      playCompletionTone: true,
    );
    final baselineWindow = await collectionFuture;
    if (!completed || !_isOperationActive(generation)) {
      return;
    }
    final quality = _sensorService.assessSignalQuality(
      devices: _devices,
      window: baselineWindow,
      duration: calibrationDuration,
    );
    _latestSignalQuality = quality;
    final rejectionMessage = _calibrationRejectionMessage(
      quality: quality,
      baselineWindow: baselineWindow,
    );
    _trialBuilder?.recordCalibrationAttempt(
      accepted: rejectionMessage == null,
      quality: quality,
    );
    if (rejectionMessage != null) {
      _calibrationData = null;
      _calibrationWarning = rejectionMessage;
      logger.i('Yoga calibration rejected: $rejectionMessage');
      _setPhase(YogaSessionPhase.calibrationInstructions);
      return;
    }
    _calibrationData = CalibrationData.fromWindow(
      baselineWindow: baselineWindow,
      ringAssignment: _ringAssignment,
    );
    logger.i(
      'Yoga calibration end with ${baselineWindow.totalSampleCount} samples',
    );
    _setPhase(YogaSessionPhase.poseInstructions);
  }

  String? _calibrationRejectionMessage({
    required SensorWindowQuality quality,
    required SensorWindow baselineWindow,
  }) {
    if (quality.hasIssues) {
      return _calibrationDataMissingMessage;
    }
    final stabilityErrors = _poseEvaluator.evaluateCalibrationStability(
      baselineWindow: baselineWindow,
      ringAssignment: _ringAssignment,
    );
    // The evaluator messages are already user-facing and number-free.
    return stabilityErrors.isEmpty ? null : stabilityErrors.first.message;
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
    final builder = _trialBuilder ??= _newTrialBuilder();

    // Unscored preparation: the participant moves into the pose while the
    // deterministic setup instruction is spoken. Nothing here is evaluated.
    _setPhase(YogaSessionPhase.posePreparing);
    _setupSpeech = _speakSetupInstruction(generation);
    final prepared = await _countDown(
      posePreparationDuration,
      generation: generation,
    );
    if (!prepared || !_isOperationActive(generation)) {
      return;
    }

    _setPhase(YogaSessionPhase.holdingPose);
    _remainingSeconds = holdDuration.inSeconds;
    _completedWindowCount = 0;
    _notifyListeners();

    final poseStream = _sensorService.startContinuousImuStreaming(
      devices: _devices,
      wearablesProvider: wearablesProvider,
    );
    final liveMarkerSubscription = _startLivePoseMarkerFeedbackUpdates(
      generation: generation,
      calibration: calibrationData,
      poseStream: poseStream,
    );
    final validResults = <PoseEvaluationResult>[];
    var liveFeedbackInFlight = false;
    var finalWindowMotivationSpoken = false;
    var holdFinished = false;
    try {
      for (var windowIndex = 0;
          windowIndex < scoringWindowCount;
          windowIndex++) {
        final completed = await _countDownSegment(
          scoringWindowDuration,
          generation: generation,
        );
        if (!completed || !_isOperationActive(generation)) {
          return;
        }
        final poseWindow = poseStream.drainWindow();
        final quality = _sensorService.assessSignalQuality(
          devices: _devices,
          window: poseWindow,
          duration: scoringWindowDuration,
        );
        _latestSignalQuality = quality;
        final isValid = !quality.hasIssues;
        PoseEvaluationResult? result;
        if (isValid) {
          result = _poseEvaluator.evaluatePose(
            pose: pose,
            calibration: calibrationData,
            poseWindow: poseWindow,
          );
          validResults.add(result);
          logger.i(
            'Yoga window ${windowIndex + 1}/$scoringWindowCount: '
            'score=${result.score}, '
            'errors=${result.errors.map((error) => error.code).join(', ')}',
          );
        } else {
          logger.i(
            'Yoga window ${windowIndex + 1}/$scoringWindowCount invalid: '
            '${quality.issueStreams.map((stream) => stream.label).join(', ')}',
          );
        }
        builder.recordWindow(
          index: windowIndex,
          isValid: isValid,
          sampleCount: poseWindow.totalSampleCount,
          result: result,
        );
        _completedWindowCount = windowIndex + 1;
        _notifyListeners();

        if (!liveCoachingEnabled) {
          continue;
        }
        final isEnteringFinalWindow = windowIndex == scoringWindowCount - 2;
        final isFinalWindow = windowIndex == scoringWindowCount - 1;
        if (isEnteringFinalWindow && !finalWindowMotivationSpoken) {
          finalWindowMotivationSpoken = true;
          unawaited(_speakFinalWindowMotivation(generation));
        } else if (!isFinalWindow &&
            !isEnteringFinalWindow &&
            result != null &&
            !liveFeedbackInFlight) {
          liveFeedbackInFlight = true;
          unawaited(
            _generateAndSpeakLiveFeedback(
              generation: generation,
              windowIndex: windowIndex,
              result: result,
            ).whenComplete(() {
              liveFeedbackInFlight = false;
            }),
          );
        }
      }
      holdFinished = true;
    } finally {
      // Broadcast-stream cancellation takes effect synchronously; awaiting
      // its future would resume on the root zone and break fake_async tests.
      if (liveMarkerSubscription != null) {
        unawaited(liveMarkerSubscription.cancel());
      }
      _setLivePoseMarkerFeedback(const []);
      await poseStream.dispose();
      // Devices stop streaming right after the hold, also on cancellation.
      await _sensorService.turnOffYogaSensors(
        devices: _devices,
        wearablesProvider: wearablesProvider,
      );
    }

    if (!holdFinished || !_isOperationActive(generation)) {
      return;
    }
    _setPhase(YogaSessionPhase.evaluating);
    await _stopFeedbackPlayback();

    final summary = _summarizeHold(validResults);
    _holdSummary = summary;
    if (summary.isValid) {
      final evaluation = summary.evaluation!;
      builder
        ..finalScore = evaluation.score
        ..postureErrors = evaluation.errors
        ..completionStatus = 'completed';
      final finalFeedback = await _llmFeedbackService.generateYogaFeedback(
        postureErrors: evaluation.errors,
        poseName: pose.name,
        score: evaluation.score,
      );
      if (!_isOperationActive(generation)) {
        return;
      }
      _feedback = finalFeedback;
      builder.recordFeedback(
        text: finalFeedback.recommendation,
        source: finalFeedback.generatedByLlm ? 'llm' : 'template',
        spoken: false,
      );
      logger.i(
        'Yoga final result: score=${evaluation.score}, '
        'validWindows=${summary.validWindowCount}/${summary.windowCount}, '
        'errors=${evaluation.errors.map((error) => error.code).join(', ')}',
      );
    } else {
      builder
        ..completionStatus = 'invalid'
        ..cancellationReason = 'insufficient_valid_windows';
      _feedback = const YogaFeedback(recommendation: invalidTrialMessage);
      logger.i(
        'Yoga trial invalid: '
        'validWindows=${summary.validWindowCount}/${summary.windowCount}',
      );
    }
    _finishTrialRecord();
    _setPhase(YogaSessionPhase.result);
  }

  YogaHoldSummary _summarizeHold(List<PoseEvaluationResult> validResults) {
    if (validResults.length < minimumValidWindowCount) {
      return YogaHoldSummary(
        evaluation: null,
        validWindowCount: validResults.length,
        windowCount: scoringWindowCount,
        invalidReason: invalidTrialMessage,
      );
    }
    return YogaHoldSummary(
      evaluation: _poseEvaluator.aggregateWindowResults(validResults),
      validWindowCount: validResults.length,
      windowCount: scoringWindowCount,
    );
  }

  Future<void> _generateAndSpeakLiveFeedback({
    required int generation,
    required int windowIndex,
    required PoseEvaluationResult result,
  }) async {
    try {
      final generated = await _llmFeedbackService.generateYogaFeedback(
        postureErrors: result.errors,
        poseName: pose.name,
        score: result.score,
      );
      final source = generated.generatedByLlm ? 'llm' : 'template';
      // Setup speech must finish first so cues never overlap or replace it.
      await (_setupSpeech ?? Future<bool>.value(false));
      if (_isStaleLiveFeedback(generation, windowIndex)) {
        logger.i('Yoga live feedback discarded as stale (source=$source).');
        _trialBuilder?.recordFeedback(
          text: generated.recommendation,
          source: source,
          spoken: false,
        );
        return;
      }
      _feedback = generated;
      logger.i(
        'Yoga live feedback (source=$source): ${generated.recommendation}',
      );
      _notifyListeners();
      final spoken = await _ttsFeedbackService.speak(generated.recommendation);
      _trialBuilder?.recordFeedback(
        text: generated.recommendation,
        source: source,
        spoken: spoken,
      );
    } catch (error, stackTrace) {
      logger.w(
        'Yoga live feedback generation failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// A live cue is stale when its trial stopped, its window result is more
  /// than one window old, or too little hold time remains for a correction.
  bool _isStaleLiveFeedback(int generation, int windowIndex) {
    return !_isOperationActive(generation) ||
        _phase != YogaSessionPhase.holdingPose ||
        _completedWindowCount - (windowIndex + 1) > 1 ||
        _remainingSeconds <= scoringWindowDuration.inSeconds;
  }

  StreamSubscription<SensorWindow>? _startLivePoseMarkerFeedbackUpdates({
    required int generation,
    required CalibrationData calibration,
    required YogaImuStreamSession poseStream,
  }) {
    if (isControlledTrial || pose.id != warriorTwoPose.id) {
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
      final spoken = await _ttsFeedbackService.speak(_finalWindowMotivation);
      _trialBuilder?.recordFeedback(
        text: _finalWindowMotivation,
        source: 'static',
        spoken: spoken,
      );
    } catch (error, stackTrace) {
      logger.w(
        'Yoga final hold motivation playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _speakSetupInstruction(int generation) async {
    try {
      final instruction = poseSetupInstruction.trim();
      if (instruction.isEmpty || !_isOperationActive(generation)) {
        return false;
      }
      logger.i('Yoga setup instruction (source=static): $instruction');
      final spoken = await _ttsFeedbackService.speak(instruction);
      _trialBuilder?.recordFeedback(
        text: instruction,
        source: 'static',
        spoken: spoken,
      );
      return spoken;
    } catch (error, stackTrace) {
      logger.w(
        'Yoga setup instruction playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> restartSession(WearablesProvider wearablesProvider) async {
    await _stopFeedbackPlayback();
    _calibrationData = null;
    _holdSummary = null;
    _feedback = null;
    _latestSignalQuality = null;
    _calibrationWarning = null;
    _setLivePoseMarkerFeedback(const []);
    // The ring assignment is deliberately kept across trials.
    await startSession(wearablesProvider);
  }

  /// Cancels whatever is currently running and returns to the calibration
  /// screen of the selected pose so the trial can be retried quickly.
  Future<void> cancelActivePhase(
    WearablesProvider wearablesProvider, {
    String reason = 'user_cancelled',
  }) async {
    switch (_phase) {
      case YogaSessionPhase.calibrationPreparing:
      case YogaSessionPhase.calibrating:
      case YogaSessionPhase.posePreparing:
      case YogaSessionPhase.holdingPose:
      case YogaSessionPhase.evaluating:
        break;
      default:
        return;
    }
    _startNewOperation();
    await _stopFeedbackPlayback();
    await _stopCalibrationCountdownSound();
    await _sensorService.turnOffYogaSensors(
      devices: _devices,
      wearablesProvider: wearablesProvider,
    );
    _abortTrialRecord(reason);
    _trialBuilder = _newTrialBuilder();
    _calibrationData = null;
    _holdSummary = null;
    _feedback = null;
    _latestSignalQuality = null;
    _remainingSeconds = 0;
    _setLivePoseMarkerFeedback(const []);
    _setPhase(YogaSessionPhase.calibrationInstructions);
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
    _abortTrialRecord('session_stopped');
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
        _holdSummary = null;
        _feedback = null;
        _latestSignalQuality = null;
        _calibrationWarning = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        _setPhase(YogaSessionPhase.idle);
        return;
      case YogaSessionPhase.calibrationInstructions:
        _calibrationData = null;
        _calibrationWarning = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        _setPhase(YogaSessionPhase.poseSelection);
        return;
      case YogaSessionPhase.calibrationPreparing:
      case YogaSessionPhase.calibrating:
        _startNewOperation();
        _calibrationData = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        await _stopFeedbackPlayback();
        await _stopCalibrationCountdownSound();
        _setPhase(YogaSessionPhase.calibrationInstructions);
        return;
      case YogaSessionPhase.poseInstructions:
        _calibrationData = null;
        _remainingSeconds = 0;
        _setLivePoseMarkerFeedback(const []);
        await _stopFeedbackPlayback();
        _setPhase(YogaSessionPhase.calibrationInstructions);
        return;
      case YogaSessionPhase.posePreparing:
      case YogaSessionPhase.holdingPose:
      case YogaSessionPhase.evaluating:
        await cancelActivePhase(wearablesProvider, reason: 'navigated_back');
        return;
      case YogaSessionPhase.result:
        _feedback = null;
        _holdSummary = null;
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
    _abortTrialRecord('app_closed');
  }

  TrialRecordBuilder _newTrialBuilder() {
    return TrialRecordBuilder(
      sessionId: _sessionId,
      appVersion: _appVersion,
      poseId: _selectedPose.id,
      studyConfig: _studyConfig?.copyWith(trialOrder: _trialCounter),
    );
  }

  /// Finalizes an unfinished trial as cancelled; no-op when nothing ran yet.
  void _abortTrialRecord(String reason) {
    final builder = _trialBuilder;
    if (builder == null ||
        (builder.calibrationAttempts == 0 && builder.windows.isEmpty)) {
      return;
    }
    builder
      ..cancellationReason = reason
      ..completionStatus = 'cancelled';
    _finishTrialRecord();
  }

  void _finishTrialRecord() {
    final builder = _trialBuilder;
    if (builder == null) {
      return;
    }
    _trialRecords.add(builder.build());
    _trialBuilder = null;
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Platform plugin unavailable (e.g. tests); keep 'unknown'.
    }
  }

  void _setPhase(YogaSessionPhase phase) {
    if (_isDisposed) {
      return;
    }
    _phase = phase;
    _trialBuilder?.markPhase(phase);
    _notifyListeners();
  }

  /// Counts [duration] down one second at a time. Ticks are played for the
  /// final [tickFromSecond] seconds while the phase is still [tickPhase].
  Future<bool> _countDown(
    Duration duration, {
    required int generation,
    int tickFromSecond = 0,
    YogaSessionPhase? tickPhase,
    bool playCompletionTone = false,
  }) async {
    _remainingSeconds = duration.inSeconds;
    _notifyListeners();
    for (var second = duration.inSeconds; second > 0; second--) {
      if (second <= tickFromSecond && tickPhase != null) {
        unawaited(_playCountdownTick(generation, tickPhase));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!_isOperationActive(generation)) {
        return false;
      }
      _remainingSeconds = second - 1;
      _notifyListeners();
    }
    if (playCompletionTone && _isOperationActive(generation)) {
      unawaited(_countdownSoundService.playCalibrationComplete());
    }
    return true;
  }

  Future<void> _playCountdownTick(
    int generation,
    YogaSessionPhase requiredPhase,
  ) async {
    if (!_isOperationActive(generation) || _phase != requiredPhase) {
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
