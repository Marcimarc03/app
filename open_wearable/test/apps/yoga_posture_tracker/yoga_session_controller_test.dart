import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart' hide logger;
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/calibration_countdown_sound_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/llm_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/tts_feedback_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_sensor_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/view_model/yoga_session_controller.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';

const _earableId = 'earable-1';
const _leftRingId = 'ring-left';
const _rightRingId = 'ring-right';

const List<double> _upVector = [0.0, 0.0, 1.0];
const List<double> _warriorArmVector = [0.0, 1.0, 0.0];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initLogger(Logger(output: MemoryOutput(), printer: SimplePrinter()));
  });

  late _FakeSensorService sensorService;
  late _FakeLlmService llmService;
  late _FakeTtsService ttsService;
  late _FakeSoundService soundService;
  late YogaSessionController controller;
  final provider = _FakeWearablesProvider();

  YogaSessionController createController() {
    return YogaSessionController(
      sensorService: sensorService,
      llmFeedbackService: llmService,
      ttsFeedbackService: ttsService,
      countdownSoundService: soundService,
    );
  }

  setUp(() {
    sensorService = _FakeSensorService();
    llmService = _FakeLlmService();
    ttsService = _FakeTtsService();
    soundService = _FakeSoundService();
    controller = createController();
  });

  /// Runs startSession + selectPose synchronously inside [async].
  void startAndSelectPose(FakeAsync async, {YogaPose? pose}) {
    unawaited(controller.startSession(provider));
    async.flushMicrotasks();
    expect(controller.phase, YogaSessionPhase.poseSelection);
    controller.selectPose(pose ?? warriorTwoPose);
    expect(controller.phase, YogaSessionPhase.calibrationInstructions);
  }

  /// Runs a full successful calibration and returns at poseInstructions.
  void calibrate(FakeAsync async) {
    unawaited(controller.beginCalibration(provider));
    async.flushMicrotasks();
    async.elapse(const Duration(seconds: 9));
    expect(controller.phase, YogaSessionPhase.poseInstructions);
  }

  group('device checks', () {
    test('startSession reaches poseSelection with a complete device set', () {
      fakeAsync((async) {
        unawaited(controller.startSession(provider));
        async.flushMicrotasks();
        expect(controller.phase, YogaSessionPhase.poseSelection);
        expect(controller.ringAssignment.isValid, isTrue);
      });
    });

    test('startSession stays idle when sensor capabilities are missing', () {
      sensorService.capabilityIssuesToReport = ['OpenRing L has no gyroscope.'];
      fakeAsync((async) {
        unawaited(controller.startSession(provider));
        async.flushMicrotasks();
        expect(controller.phase, YogaSessionPhase.idle);
        expect(controller.capabilityIssues, isNotEmpty);
      });
    });
  });

  group('LLM connection check', () {
    test('shows and speaks the LLM response', () async {
      await controller.checkLlmConnection();

      expect(controller.llmConnectionCheck?.isReachable, isTrue);
      expect(
        controller.llmConnectionCheck?.message,
        'The yoga coach is online.',
      );
      expect(ttsService.spoken, ['The yoga coach is online.']);
    });
  });

  group('calibration', () {
    test('does not record during the 5s preparation, then records 3s', () {
      fakeAsync((async) {
        startAndSelectPose(async);
        unawaited(controller.beginCalibration(provider));
        async.flushMicrotasks();
        expect(controller.phase, YogaSessionPhase.calibrationPreparing);

        async.elapse(const Duration(milliseconds: 4900));
        expect(
          sensorService.collectWindowCalls,
          0,
          reason: 'no recording during preparation',
        );
        expect(controller.phase, YogaSessionPhase.calibrationPreparing);

        async.elapse(const Duration(milliseconds: 200));
        expect(controller.phase, YogaSessionPhase.calibrating);
        expect(sensorService.collectWindowCalls, 1);

        async.elapse(const Duration(seconds: 4));
        expect(controller.phase, YogaSessionPhase.poseInstructions);
        // Only the three recorded baseline seconds emit ticks.
        expect(soundService.tickCount, 3);
        expect(soundService.completeCount, 1);
      });
    });

    test('is rejected without raw numbers when a stream is too thin', () {
      sensorService.baselineWindowFactory = () => _window(samplesPerStream: 2);
      fakeAsync((async) {
        startAndSelectPose(async);
        unawaited(controller.beginCalibration(provider));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));

        expect(controller.phase, YogaSessionPhase.calibrationInstructions);
        expect(controller.calibrationWarning, isNotNull);
        expect(controller.calibrationWarning, isNot(matches(RegExp(r'\d'))));
      });
    });

    test('is rejected when the head moves too much', () {
      sensorService.baselineWindowFactory =
          () => _window(headGyroVector: const [100, 0, 0]);
      fakeAsync((async) {
        startAndSelectPose(async);
        unawaited(controller.beginCalibration(provider));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));

        expect(controller.phase, YogaSessionPhase.calibrationInstructions);
        expect(controller.calibrationWarning, contains('head movement'));
        expect(controller.calibrationWarning, isNot(matches(RegExp(r'\d'))));
      });
    });
  });

  group('pose hold', () {
    test('runs an unscored 5s preparation before six 5s scored windows', () {
      fakeAsync((async) {
        startAndSelectPose(async);
        calibrate(async);

        unawaited(controller.beginPoseHold(provider));
        async.flushMicrotasks();
        expect(controller.phase, YogaSessionPhase.posePreparing);

        async.elapse(const Duration(seconds: 4));
        expect(controller.phase, YogaSessionPhase.posePreparing);
        expect(
          sensorService.streamSessions,
          isEmpty,
          reason: 'no scoring stream during pose preparation',
        );
        expect(
          ttsService.spoken,
          contains(warriorTwoPose.instruction),
          reason: 'setup instruction spoken during preparation',
        );

        async.elapse(const Duration(seconds: 2));
        expect(controller.phase, YogaSessionPhase.holdingPose);
        expect(sensorService.streamSessions, hasLength(1));

        async.elapse(const Duration(seconds: 35));
        expect(controller.phase, YogaSessionPhase.result);
        expect(sensorService.streamSessions.single.drainCount, 6);
        expect(sensorService.streamSessions.single.disposed, isTrue);
        expect(
          sensorService.turnOffCount,
          greaterThanOrEqualTo(1),
          reason: 'sensors turned off right after the hold',
        );

        final summary = controller.holdSummary!;
        expect(summary.isValid, isTrue);
        expect(summary.validWindowCount, 6);
        expect(summary.windowCount, 6);
        expect(summary.evaluation!.score, 100);
      });
    });

    test('excludes invalid windows and still scores with five valid ones', () {
      sensorService.holdWindows = [
        _window(),
        const SensorWindow(
          earableAccelerometerSamples: [],
          earableGyroscopeSamples: [],
          ringAccelerometerSamplesByDeviceId: {},
          ringGyroscopeSamplesByDeviceId: {},
        ),
        _window(),
        _window(),
        _window(),
        _window(),
      ];
      fakeAsync((async) {
        startAndSelectPose(async);
        calibrate(async);
        unawaited(controller.beginPoseHold(provider));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 45));

        final summary = controller.holdSummary!;
        expect(summary.isValid, isTrue);
        expect(summary.validWindowCount, 5);
        expect(controller.trialRecords.single.windows, hasLength(6));
        expect(
          controller.trialRecords.single.windows
              .where((window) => !window.isValid),
          hasLength(1),
        );
      });
    });

    test('marks the trial invalid below five valid windows', () {
      sensorService.holdWindows = [
        _window(),
        _window(),
        _window(),
        _window(),
        const SensorWindow(
          earableAccelerometerSamples: [],
          earableGyroscopeSamples: [],
          ringAccelerometerSamplesByDeviceId: {},
          ringGyroscopeSamplesByDeviceId: {},
        ),
        _window(samplesPerStream: 3),
      ];
      fakeAsync((async) {
        startAndSelectPose(async);
        calibrate(async);
        unawaited(controller.beginPoseHold(provider));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 45));

        expect(controller.phase, YogaSessionPhase.result);
        final summary = controller.holdSummary!;
        expect(summary.isValid, isFalse);
        expect(summary.evaluation, isNull);
        expect(summary.validWindowCount, 4);
        expect(
          controller.feedback!.recommendation,
          YogaSessionController.invalidTrialMessage,
        );
        final record = controller.trialRecords.single;
        expect(record.completionStatus, 'invalid');
        expect(record.finalScore, isNull);
      });
    });
  });

  group('cancellation', () {
    for (final (phaseName, prepare) in [
      (
        'calibrationPreparing',
        (FakeAsync async) {
          unawaited(controller.beginCalibration(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 2));
          expect(controller.phase, YogaSessionPhase.calibrationPreparing);
        }
      ),
      (
        'calibrating',
        (FakeAsync async) {
          unawaited(controller.beginCalibration(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 6));
          expect(controller.phase, YogaSessionPhase.calibrating);
        }
      ),
      (
        'posePreparing',
        (FakeAsync async) {
          calibrate(async);
          unawaited(controller.beginPoseHold(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 4));
          expect(controller.phase, YogaSessionPhase.posePreparing);
        }
      ),
      (
        'holdingPose',
        (FakeAsync async) {
          calibrate(async);
          unawaited(controller.beginPoseHold(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 17));
          expect(controller.phase, YogaSessionPhase.holdingPose);
        }
      ),
    ]) {
      test('cancel during $phaseName returns to calibrationInstructions', () {
        fakeAsync((async) {
          startAndSelectPose(async);
          prepare(async);

          unawaited(controller.cancelActivePhase(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));

          expect(controller.phase, YogaSessionPhase.calibrationInstructions);
          expect(ttsService.stopCount, greaterThanOrEqualTo(1));
          expect(sensorService.turnOffCount, greaterThanOrEqualTo(1));
          expect(controller.remainingSeconds, 0);

          // A cancelled hold must not keep counting or produce a result.
          async.elapse(const Duration(seconds: 60));
          expect(controller.phase, YogaSessionPhase.calibrationInstructions);
          expect(controller.holdSummary, isNull);
        });
      });
    }
  });

  group('ring assignment persistence', () {
    test('a swapped assignment survives restartSession', () {
      fakeAsync((async) {
        unawaited(controller.startSession(provider));
        async.flushMicrotasks();
        controller.updateRingAssignment(
          leftRingId: _rightRingId,
          rightRingId: _leftRingId,
        );
        expect(controller.ringAssignment.leftRingId, _rightRingId);

        unawaited(controller.restartSession(provider));
        async.flushMicrotasks();
        expect(controller.phase, YogaSessionPhase.poseSelection);
        expect(controller.ringAssignment.leftRingId, _rightRingId);
        expect(controller.ringAssignment.rightRingId, _leftRingId);
      });
    });
  });

  group('live coaching', () {
    void runFullTrial(FakeAsync async) {
      startAndSelectPose(async);
      calibrate(async);
      unawaited(controller.beginPoseHold(provider));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 45));
      expect(controller.phase, YogaSessionPhase.result);
    }

    test('speaks setup and live LLM cues', () {
      fakeAsync((async) {
        runFullTrial(async);

        expect(llmService.calls.length, greaterThan(1));
        expect(
          ttsService.spoken.where((text) => text.contains('Fake cue')),
          isNotEmpty,
        );
        final record = controller.trialRecords.single;
        expect(record.trialOrder, 1);
        expect(record.completionStatus, 'completed');
      });
    });
  });

  group('feedback timing', () {
    test('live cues wait for the setup instruction to finish', () {
      ttsService.speechDuration = const Duration(seconds: 16);
      fakeAsync((async) {
        startAndSelectPose(async);
        calibrate(async);
        unawaited(controller.beginPoseHold(provider));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 45));

        expect(
          ttsService.skipped,
          isEmpty,
          reason: 'cues must be gated, not dropped by overlap',
        );
        expect(ttsService.spoken.first, warriorTwoPose.instruction);
        expect(ttsService.spoken.length, greaterThan(1));
      });
    });

    test('discards LLM responses that arrive windows too late', () {
      llmService.delay = const Duration(seconds: 11);
      fakeAsync((async) {
        startAndSelectPose(async);
        calibrate(async);
        unawaited(controller.beginPoseHold(provider));
        async.flushMicrotasks();
        // Long enough for the hold plus the delayed final feedback request.
        async.elapse(const Duration(seconds: 60));

        expect(
          ttsService.spoken.where((text) => text.contains('Fake cue')),
          isEmpty,
          reason: 'stale cues must never be spoken',
        );
        final staleEvents = controller.trialRecords.single.feedbackEvents
            .where((event) => event.text.contains('Fake cue'));
        expect(staleEvents, isNotEmpty);
        expect(staleEvents.every((event) => !event.spoken), isTrue);
      });
    });
  });

  group('repeated trials integration', () {
    test('two trials share the assignment and export records', () {
      fakeAsync((async) {
        unawaited(controller.startSession(provider));
        async.flushMicrotasks();
        controller.updateRingAssignment(
          leftRingId: _rightRingId,
          rightRingId: _leftRingId,
        );

        for (final expectedOrder in [1, 2]) {
          controller.selectPose(chairPose);
          expect(controller.phase, YogaSessionPhase.calibrationInstructions);
          calibrate(async);
          unawaited(controller.beginPoseHold(provider));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 45));
          expect(controller.phase, YogaSessionPhase.result);
          expect(controller.trialRecords, hasLength(expectedOrder));

          unawaited(controller.restartSession(provider));
          async.flushMicrotasks();
          expect(controller.phase, YogaSessionPhase.poseSelection);
          expect(
            controller.ringAssignment.leftRingId,
            _rightRingId,
            reason: 'assignment preserved between trials',
          );
        }

        final orders =
            controller.trialRecords.map((record) => record.trialOrder);
        expect(orders, [1, 2]);
        expect(
          controller.trialRecords.every(
            (record) => record.phaseTimestamps
                .containsKey(YogaSessionPhase.holdingPose.name),
          ),
          isTrue,
        );
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeWearablesProvider implements WearablesProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWearable implements Wearable {
  @override
  final String name;
  @override
  final String deviceId;

  _FakeWearable(this.name, this.deviceId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A neutral-calibration-compatible IMU window with configurable content.
SensorWindow _window({
  int samplesPerStream = 30,
  List<double> headVector = _upVector,
  List<double> headGyroVector = const [0, 0, 0],
  List<double> leftArmVector = _warriorArmVector,
  List<double> rightArmVector = _warriorArmVector,
}) {
  List<ImuSample> samples(String deviceId, String sensor, List<double> values) {
    return [
      for (var i = 0; i < samplesPerStream; i++)
        ImuSample(
          deviceId: deviceId,
          deviceName: deviceId,
          sensorName: sensor,
          timestamp: i,
          values: values,
        ),
    ];
  }

  return SensorWindow(
    earableAccelerometerSamples: samples(_earableId, 'ACC', headVector),
    earableGyroscopeSamples: samples(_earableId, 'GYRO', headGyroVector),
    ringAccelerometerSamplesByDeviceId: {
      _leftRingId: samples(_leftRingId, 'ACC', leftArmVector),
      _rightRingId: samples(_rightRingId, 'ACC', rightArmVector),
    },
    ringGyroscopeSamplesByDeviceId: {
      _leftRingId: samples(_leftRingId, 'GYRO', const [0, 0, 0]),
      _rightRingId: samples(_rightRingId, 'GYRO', const [0, 0, 0]),
    },
  );
}

/// Baseline: everything neutral (arms down, head level, no rotation).
SensorWindow _neutralBaseline() {
  return _window(
    samplesPerStream: 20,
    leftArmVector: _upVector,
    rightArmVector: _upVector,
  );
}

class _FakeImuStreamSession implements YogaImuStreamSession {
  final List<SensorWindow> windows;
  int drainCount = 0;
  bool disposed = false;

  _FakeImuStreamSession(this.windows);

  @override
  SensorWindow drainWindow() {
    final window = drainCount < windows.length
        ? windows[drainCount]
        : windows.isEmpty
            ? _window()
            : windows.last;
    drainCount += 1;
    return window;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeSensorService implements YogaSensorService {
  // Delegate the pure quality assessment to the real implementation so the
  // window-validity rules under test match production behavior.
  final YogaSensorService _real = YogaSensorService();

  final YogaDeviceSet _devices = YogaDeviceSet(
    earable: _FakeWearable('OpenEarable-Test', _earableId),
    rings: [
      _FakeWearable('OpenRing L', _leftRingId),
      _FakeWearable('OpenRing R', _rightRingId),
    ],
  );

  SensorWindow Function() baselineWindowFactory = _neutralBaseline;
  List<SensorWindow>? holdWindows;
  List<String> capabilityIssuesToReport = const [];
  int collectWindowCalls = 0;
  int turnOffCount = 0;
  final List<_FakeImuStreamSession> streamSessions = [];

  @override
  YogaDeviceSet resolveDevices(WearablesProvider wearablesProvider) => _devices;

  @override
  RingAssignment defaultRingAssignment(YogaDeviceSet devices) {
    return const RingAssignment(
      leftRingId: _leftRingId,
      rightRingId: _rightRingId,
    );
  }

  @override
  List<String> capabilityIssues(YogaDeviceSet devices) =>
      capabilityIssuesToReport;

  @override
  Future<SensorWindow> collectWindow({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
    required Duration duration,
    Future<void>? cancelSignal,
  }) async {
    collectWindowCalls += 1;
    await Future<void>.delayed(duration);
    return baselineWindowFactory();
  }

  @override
  YogaImuStreamSession startContinuousImuStreaming({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
  }) {
    final session = _FakeImuStreamSession(holdWindows ?? []);
    streamSessions.add(session);
    return session;
  }

  @override
  SensorWindowQuality assessSignalQuality({
    required YogaDeviceSet devices,
    required SensorWindow window,
    required Duration duration,
  }) {
    return _real.assessSignalQuality(
      devices: devices,
      window: window,
      duration: duration,
    );
  }

  @override
  Future<void> turnOffYogaSensors({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
  }) async {
    turnOffCount += 1;
  }
}

class _FakeLlmService implements LlmFeedbackService {
  final List<String> calls = [];
  Duration delay = Duration.zero;

  @override
  Future<LlmConnectionCheck> checkConnection() async {
    return const LlmConnectionCheck(
      isReachable: true,
      message: 'The yoga coach is online.',
    );
  }

  @override
  Future<YogaFeedback> generateYogaFeedback({
    required List<PostureError> postureErrors,
    required String poseName,
    required int score,
  }) async {
    calls.add(poseName);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return YogaFeedback(
      recommendation: 'Fake cue for $poseName.',
      generatedByLlm: true,
    );
  }
}

class _FakeTtsService implements TtsFeedbackService {
  final List<String> spoken = [];
  final List<String> skipped = [];
  Duration speechDuration = Duration.zero;
  int stopCount = 0;
  bool _busy = false;

  @override
  Future<bool> speak(String text) async {
    if (_busy) {
      skipped.add(text);
      return false;
    }
    _busy = true;
    spoken.add(text);
    if (speechDuration > Duration.zero) {
      await Future<void>.delayed(speechDuration);
    }
    _busy = false;
    return true;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeSoundService implements CalibrationCountdownSoundService {
  int tickCount = 0;
  int completeCount = 0;
  int stopCount = 0;

  @override
  Future<void> playCountdownTick() async {
    tickCount += 1;
  }

  @override
  Future<void> playCalibrationComplete() async {
    completeCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> dispose() async {}
}
