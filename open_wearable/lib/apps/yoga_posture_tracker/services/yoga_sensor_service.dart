import 'dart:async';
import 'dart:math';

import 'package:open_earable_flutter/open_earable_flutter.dart' hide logger;
import 'package:open_wearable/apps/widgets/app_compatibility.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/models/device_name_formatter.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/models/sensor_streams.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';

class YogaSensorService {
  static const String defaultLeftRingName = 'OpenRing-6033F92';
  static const String defaultRightRingName = 'OpenRing-6036A35';

  YogaDeviceSet resolveDevices(WearablesProvider wearablesProvider) {
    Wearable? earable;
    final rings = <Wearable>[];

    for (final wearable in wearablesProvider.wearables) {
      if (wearableNameStartsWithPrefix(wearable.name, 'OpenEarable')) {
        earable ??= wearable;
        continue;
      }
      if (wearableNameStartsWithPrefix(wearable.name, 'OpenRing')) {
        rings.add(wearable);
      }
    }

    return YogaDeviceSet(
      earable: earable,
      rings: rings,
    );
  }

  RingAssignment defaultRingAssignment(YogaDeviceSet devices) {
    return RingAssignment(
      leftRingId: _findRingIdByDisplayName(devices, defaultLeftRingName),
      rightRingId: _findRingIdByDisplayName(devices, defaultRightRingName),
    );
  }

  /// Human-readable issues for devices that lack the sensor capabilities the
  /// yoga evaluation needs. Empty when all connected devices are usable.
  List<String> capabilityIssues(YogaDeviceSet devices) {
    final issues = <String>[];
    final wearables = [
      if (devices.earable != null) devices.earable!,
      ...devices.rings,
    ];
    for (final wearable in wearables) {
      final displayName = formatWearableDisplayName(wearable.name);
      if (!wearable.hasCapability<SensorManager>()) {
        issues.add('$displayName exposes no sensors.');
        continue;
      }
      final sensors = wearable.requireCapability<SensorManager>().sensors;
      if (_findSensor(sensors, const ['accelerometer', 'acc']) == null) {
        issues.add('$displayName has no accelerometer.');
      }
      if (_findSensor(sensors, const ['gyroscope', 'gyro', 'gyr']) == null) {
        issues.add('$displayName has no gyroscope.');
      }
    }
    return issues;
  }

  Future<SensorWindow> collectWindow({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
    required Duration duration,
    Future<void>? cancelSignal,
  }) async {
    final stream = startContinuousImuStreaming(
      devices: devices,
      wearablesProvider: wearablesProvider,
    );
    try {
      await _delayOrCancel(duration, cancelSignal);
      final window = stream.drainWindow();
      logger.i(
        'Yoga sensor window collected ${window.totalSampleCount} samples '
        'over ${duration.inMilliseconds}ms',
      );
      return window;
    } finally {
      await stream.dispose();
    }
  }

  YogaImuStreamSession startContinuousImuStreaming({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
  }) {
    final buffers = _YogaImuSampleBuffers.forDevices(devices);
    final subscriptions = <StreamSubscription<SensorValue>>[];

    void subscribe({
      required Wearable wearable,
      required Sensor sensor,
      required List<ImuSample> target,
    }) {
      subscriptions.add(
        SensorStreams.shared(wearable: wearable, sensor: sensor).listen(
          (value) {
            final values = _sensorValuesAsDoubles(value);
            if (values == null) {
              return;
            }
            final sample = ImuSample(
              deviceId: wearable.deviceId,
              deviceName: wearable.name,
              sensorName: sensor.sensorName,
              timestamp: value.timestamp,
              values: values,
            );
            target.add(sample);
          },
        ),
      );
    }

    final earable = devices.earable;
    if (earable != null && earable.hasCapability<SensorManager>()) {
      final sensors = earable.requireCapability<SensorManager>().sensors;
      final configProvider =
          wearablesProvider.getSensorConfigurationProvider(earable);
      final accelerometer =
          _findSensor(sensors, const ['accelerometer', 'acc']);
      final gyroscope =
          _findSensor(sensors, const ['gyroscope', 'gyro', 'gyr']);
      if (accelerometer != null) {
        _configureSensorForStreaming(accelerometer, configProvider);
        subscribe(
          wearable: earable,
          sensor: accelerometer,
          target: buffers.earableAccelerometer,
        );
      }
      if (gyroscope != null) {
        _configureSensorForStreaming(gyroscope, configProvider);
        subscribe(
          wearable: earable,
          sensor: gyroscope,
          target: buffers.earableGyroscope,
        );
      }
    }

    for (final ring in devices.rings) {
      if (!ring.hasCapability<SensorManager>()) {
        continue;
      }
      final sensors = ring.requireCapability<SensorManager>().sensors;
      final configProvider = wearablesProvider.getSensorConfigurationProvider(
        ring,
      );
      final accelerometer =
          _findSensor(sensors, const ['accelerometer', 'acc']);
      final gyroscope =
          _findSensor(sensors, const ['gyroscope', 'gyro', 'gyr']);
      if (accelerometer != null) {
        _configureSensorForStreaming(accelerometer, configProvider);
        subscribe(
          wearable: ring,
          sensor: accelerometer,
          target: buffers.ringAccelerometers[ring.deviceId]!,
        );
      }
      if (gyroscope != null) {
        _configureSensorForStreaming(gyroscope, configProvider);
        subscribe(
          wearable: ring,
          sensor: gyroscope,
          target: buffers.ringGyroscopes[ring.deviceId]!,
        );
      }
    }

    logger.i(
      'Yoga continuous IMU stream started with ${subscriptions.length} streams',
    );
    return YogaImuStreamSession._(
      buffers: buffers,
      subscriptions: subscriptions,
    );
  }

  SensorWindowQuality assessSignalQuality({
    required YogaDeviceSet devices,
    required SensorWindow window,
    required Duration duration,
  }) {
    final minimumSampleCount = max(1, duration.inSeconds * 5);
    final streams = <SensorSampleQuality>[
      SensorSampleQuality(
        label: 'Earable accelerometer',
        sampleCount: window.earableAccelerometerSamples.length,
        minimumSampleCount: minimumSampleCount,
      ),
      SensorSampleQuality(
        label: 'Earable gyroscope',
        sampleCount: window.earableGyroscopeSamples.length,
        minimumSampleCount: minimumSampleCount,
      ),
    ];

    final leftRingId = devices.ringAssignment.leftRingId;
    if (leftRingId != null) {
      streams.addAll(
        _ringQualityStreams(
          labelPrefix: 'Left ring',
          ringId: leftRingId,
          window: window,
          minimumSampleCount: minimumSampleCount,
        ),
      );
    }

    final rightRingId = devices.ringAssignment.rightRingId;
    if (rightRingId != null) {
      streams.addAll(
        _ringQualityStreams(
          labelPrefix: 'Right ring',
          ringId: rightRingId,
          window: window,
          minimumSampleCount: minimumSampleCount,
        ),
      );
    }

    return SensorWindowQuality(streams: streams);
  }

  Future<void> turnOffYogaSensors({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
  }) async {
    final wearables = [
      if (devices.earable != null) devices.earable!,
      ...devices.rings,
    ];
    for (final wearable in wearables) {
      await wearablesProvider.turnOffSensorsForDevice(wearable);
    }
  }

  Future<void> _delayOrCancel(
    Duration duration,
    Future<void>? cancelSignal,
  ) async {
    if (cancelSignal == null) {
      await Future<void>.delayed(duration);
      return;
    }
    await Future.any([
      Future<void>.delayed(duration),
      cancelSignal,
    ]);
  }

  List<SensorSampleQuality> _ringQualityStreams({
    required String labelPrefix,
    required String ringId,
    required SensorWindow window,
    required int minimumSampleCount,
  }) {
    return [
      SensorSampleQuality(
        label: '$labelPrefix accelerometer',
        sampleCount: window.ringAccelerometerSamplesFor(ringId).length,
        minimumSampleCount: minimumSampleCount,
      ),
      SensorSampleQuality(
        label: '$labelPrefix gyroscope',
        sampleCount: window.ringGyroscopeSamplesFor(ringId).length,
        minimumSampleCount: minimumSampleCount,
      ),
    ];
  }

  String? _findRingIdByDisplayName(
    YogaDeviceSet devices,
    String targetName,
  ) {
    final normalizedTargetName = targetName.trim().toLowerCase();
    for (final ring in devices.rings) {
      final normalizedDisplayName = formatWearableDisplayName(
        ring.name,
      ).trim().toLowerCase();
      if (normalizedDisplayName == normalizedTargetName) {
        return ring.deviceId;
      }
    }
    return null;
  }

  Sensor? _findSensor(List<Sensor> sensors, List<String> keywords) {
    for (final sensor in sensors) {
      final text =
          '${sensor.sensorName} ${sensor.chartTitle} ${sensor.shortChartTitle}'
              .toLowerCase();
      if (keywords.any(text.contains)) {
        return sensor;
      }
    }
    return null;
  }

  List<double>? _sensorValuesAsDoubles(SensorValue value) {
    if (value is SensorDoubleValue) {
      return value.values;
    }
    if (value is SensorIntValue) {
      return value.values.map((item) => item.toDouble()).toList();
    }
    return null;
  }

  void _configureSensorForStreaming(
    Sensor sensor,
    SensorConfigurationProvider configProvider,
  ) {
    final configuration = sensor.relatedConfigurations.firstOrNull;
    if (configuration == null) {
      return;
    }

    if (configuration is ConfigurableSensorConfiguration &&
        configuration.availableOptions.contains(StreamSensorConfigOption())) {
      configProvider.addSensorConfigurationOption(
        configuration,
        StreamSensorConfigOption(),
        markPending: false,
      );
    }

    final values = configProvider.getSensorConfigurationValues(
      configuration,
      distinct: true,
    );
    if (values.isEmpty) {
      return;
    }

    final selected = _selectHighestFrequencyValue(values);
    configProvider.addSensorConfiguration(
      configuration,
      selected,
      markPending: false,
    );
    configuration.setConfiguration(selected);
  }

  SensorConfigurationValue _selectHighestFrequencyValue(
    List<SensorConfigurationValue> values,
  ) {
    final frequencyValues =
        values.whereType<SensorFrequencyConfigurationValue>().toList();
    if (frequencyValues.isEmpty) {
      return values.first;
    }
    frequencyValues.sort((a, b) => b.frequencyHz.compareTo(a.frequencyHz));
    return frequencyValues.first;
  }
}

class YogaImuStreamSession {
  final _YogaImuSampleBuffers _buffers;
  final List<StreamSubscription<SensorValue>> _subscriptions;
  bool _disposed = false;

  YogaImuStreamSession._({
    required _YogaImuSampleBuffers buffers,
    required List<StreamSubscription<SensorValue>> subscriptions,
  })  : _buffers = buffers,
        _subscriptions = subscriptions;

  SensorWindow drainWindow() {
    final window = _buffers.drainWindow();
    logger.i(
      'Yoga continuous IMU stream drained ${window.totalSampleCount} samples',
    );
    return window;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    logger.i('Yoga continuous IMU stream stopped');
  }
}

class _YogaImuSampleBuffers {
  final List<ImuSample> earableAccelerometer;
  final List<ImuSample> earableGyroscope;
  final Map<String, List<ImuSample>> ringAccelerometers;
  final Map<String, List<ImuSample>> ringGyroscopes;

  _YogaImuSampleBuffers({
    required this.earableAccelerometer,
    required this.earableGyroscope,
    required this.ringAccelerometers,
    required this.ringGyroscopes,
  });

  factory _YogaImuSampleBuffers.forDevices(YogaDeviceSet devices) {
    return _YogaImuSampleBuffers(
      earableAccelerometer: <ImuSample>[],
      earableGyroscope: <ImuSample>[],
      ringAccelerometers: <String, List<ImuSample>>{
        for (final ring in devices.rings) ring.deviceId: <ImuSample>[],
      },
      ringGyroscopes: <String, List<ImuSample>>{
        for (final ring in devices.rings) ring.deviceId: <ImuSample>[],
      },
    );
  }

  SensorWindow drainWindow() {
    final window = SensorWindow(
      earableAccelerometerSamples: List<ImuSample>.of(earableAccelerometer),
      earableGyroscopeSamples: List<ImuSample>.of(earableGyroscope),
      ringAccelerometerSamplesByDeviceId: {
        for (final entry in ringAccelerometers.entries)
          entry.key: List<ImuSample>.of(entry.value),
      },
      ringGyroscopeSamplesByDeviceId: {
        for (final entry in ringGyroscopes.entries)
          entry.key: List<ImuSample>.of(entry.value),
      },
    );
    earableAccelerometer.clear();
    earableGyroscope.clear();
    for (final samples in ringAccelerometers.values) {
      samples.clear();
    }
    for (final samples in ringGyroscopes.values) {
      samples.clear();
    }
    return window;
  }
}
