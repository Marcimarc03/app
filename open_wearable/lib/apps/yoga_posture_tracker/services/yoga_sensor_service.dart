import 'dart:async';

import 'package:open_earable_flutter/open_earable_flutter.dart' hide logger;
import 'package:open_wearable/apps/widgets/app_compatibility.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/models/sensor_streams.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';

class YogaSensorService {
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

  Future<SensorWindow> collectWindow({
    required YogaDeviceSet devices,
    required WearablesProvider wearablesProvider,
    required Duration duration,
  }) async {
    final earableAccelerometer = <ImuSample>[];
    final earableGyroscope = <ImuSample>[];
    final ringAccelerometers = <String, List<ImuSample>>{
      for (final ring in devices.rings) ring.deviceId: <ImuSample>[],
    };
    final ringGyroscopes = <String, List<ImuSample>>{
      for (final ring in devices.rings) ring.deviceId: <ImuSample>[],
    };
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
            target.add(
              ImuSample(
                deviceId: wearable.deviceId,
                deviceName: wearable.name,
                sensorName: sensor.sensorName,
                timestamp: value.timestamp,
                values: values,
              ),
            );
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
          target: earableAccelerometer,
        );
      }
      if (gyroscope != null) {
        _configureSensorForStreaming(gyroscope, configProvider);
        subscribe(
          wearable: earable,
          sensor: gyroscope,
          target: earableGyroscope,
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
          target: ringAccelerometers[ring.deviceId]!,
        );
      }
      if (gyroscope != null) {
        _configureSensorForStreaming(gyroscope, configProvider);
        subscribe(
          wearable: ring,
          sensor: gyroscope,
          target: ringGyroscopes[ring.deviceId]!,
        );
      }
    }

    await Future<void>.delayed(duration);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    final window = SensorWindow(
      earableAccelerometerSamples: earableAccelerometer,
      earableGyroscopeSamples: earableGyroscope,
      ringAccelerometerSamplesByDeviceId: ringAccelerometers,
      ringGyroscopeSamplesByDeviceId: ringGyroscopes,
    );
    logger.i(
      'Yoga sensor window collected ${window.totalSampleCount} samples '
      'over ${duration.inMilliseconds}ms',
    );
    return window;
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
