import 'dart:math';

import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

class VectorStats {
  final List<double> mean;
  final List<double> standardDeviation;
  final double meanMagnitude;

  const VectorStats({
    required this.mean,
    required this.standardDeviation,
    required this.meanMagnitude,
  });

  bool get hasData => mean.isNotEmpty;
}

VectorStats vectorStats(List<ImuSample> samples) {
  if (samples.isEmpty) {
    return const VectorStats(
      mean: [],
      standardDeviation: [],
      meanMagnitude: 0,
    );
  }

  final width = samples.first.values.length;
  if (width == 0) {
    return const VectorStats(
      mean: [],
      standardDeviation: [],
      meanMagnitude: 0,
    );
  }

  final mean = List<double>.filled(width, 0);
  for (final sample in samples) {
    for (var i = 0; i < width && i < sample.values.length; i++) {
      mean[i] += sample.values[i];
    }
  }
  for (var i = 0; i < mean.length; i++) {
    mean[i] /= samples.length;
  }

  final variance = List<double>.filled(width, 0);
  for (final sample in samples) {
    for (var i = 0; i < width && i < sample.values.length; i++) {
      final delta = sample.values[i] - mean[i];
      variance[i] += delta * delta;
    }
  }
  final standardDeviation = variance
      .map((value) => sqrt(value / samples.length))
      .toList(growable: false);

  final meanMagnitude =
      samples.fold<double>(0, (sum, sample) => sum + sample.magnitude) /
          samples.length;

  return VectorStats(
    mean: mean,
    standardDeviation: standardDeviation,
    meanMagnitude: meanMagnitude,
  );
}

double estimatePitchDegrees(List<double> values) {
  if (values.length < 3) {
    return 0;
  }
  final ax = values[0];
  final ay = values[1];
  final az = values[2];
  return atan2(-ax, sqrt(ay * ay + az * az)) * 180 / pi;
}

double estimateRollDegrees(List<double> values) {
  if (values.length < 3) {
    return 0;
  }
  final ay = values[1];
  final az = values[2];
  return atan2(ay, az) * 180 / pi;
}

double angleBetweenVectorsDegrees(
  List<double> first,
  List<double> second,
) {
  if (first.length < 3 || second.length < 3) {
    return 0;
  }
  final firstMagnitude = _vectorMagnitude(first);
  final secondMagnitude = _vectorMagnitude(second);
  if (firstMagnitude == 0 || secondMagnitude == 0) {
    return 0;
  }
  final dotProduct =
      first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
  final normalizedDot =
      (dotProduct / (firstMagnitude * secondMagnitude)).clamp(-1.0, 1.0);
  return acos(normalizedDot) * 180 / pi;
}

OrientationDelta orientationDeltaDegrees({
  required List<double> baselineMean,
  required List<double> poseMean,
}) {
  return OrientationDelta(
    pitch: wrappedAngleDeltaDegrees(
      estimatePitchDegrees(poseMean),
      estimatePitchDegrees(baselineMean),
    ),
    roll: wrappedAngleDeltaDegrees(
      estimateRollDegrees(poseMean),
      estimateRollDegrees(baselineMean),
    ),
  );
}

double wrappedAngleDeltaDegrees(double current, double baseline) {
  var delta = current - baseline;
  while (delta > 180) {
    delta -= 360;
  }
  while (delta < -180) {
    delta += 360;
  }
  return delta;
}

double _vectorMagnitude(List<double> values) {
  if (values.length < 3) {
    return 0;
  }
  return sqrt(
    values[0] * values[0] + values[1] * values[1] + values[2] * values[2],
  );
}

class OrientationDelta {
  final double pitch;
  final double roll;

  const OrientationDelta({
    required this.pitch,
    required this.roll,
  });
}
