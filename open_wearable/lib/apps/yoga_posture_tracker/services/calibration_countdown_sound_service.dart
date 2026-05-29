import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:open_wearable/models/logger.dart';

abstract class CalibrationCountdownSoundService {
  Future<void> playCountdownTick();
  Future<void> playCalibrationComplete();
  Future<void> stop();
  Future<void> dispose();
}

class GeneratedBeepCountdownSoundService
    implements CalibrationCountdownSoundService {
  static final Uint8List _countdownBeep = _SineWaveWav.create(
    frequencyHz: 880,
    duration: const Duration(milliseconds: 160),
  );
  static final Uint8List _completeBeep = _SineWaveWav.create(
    frequencyHz: 1320,
    duration: const Duration(milliseconds: 260),
  );

  final AudioPlayer _player;
  bool _isDisposed = false;

  GeneratedBeepCountdownSoundService({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  @override
  Future<void> playCountdownTick() {
    return _play(_countdownBeep);
  }

  @override
  Future<void> playCalibrationComplete() {
    return _play(_completeBeep);
  }

  @override
  Future<void> stop() async {
    if (_isDisposed) {
      return;
    }
    try {
      await _player.stop();
    } catch (error, stackTrace) {
      logger.w(
        'Yoga calibration countdown sound stop failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    try {
      await _player.dispose();
    } catch (error, stackTrace) {
      logger.w(
        'Yoga calibration countdown sound dispose failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _play(Uint8List bytes) async {
    if (_isDisposed) {
      return;
    }
    try {
      await _player.stop();
      await _player.play(
        BytesSource(bytes, mimeType: 'audio/wav'),
        mode: PlayerMode.lowLatency,
        volume: 1,
      );
    } catch (error, stackTrace) {
      logger.w(
        'Yoga calibration countdown sound playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class _SineWaveWav {
  static const int _sampleRate = 44100;
  static const int _bitsPerSample = 16;
  static const int _channels = 1;
  static const int _wavHeaderSize = 44;
  static const double _amplitude = 0.62;

  _SineWaveWav._();

  static Uint8List create({
    required double frequencyHz,
    required Duration duration,
  }) {
    final sampleCount =
        (_sampleRate * duration.inMicroseconds / Duration.microsecondsPerSecond)
            .round();
    final bytesPerSample = _bitsPerSample ~/ 8;
    final dataSize = sampleCount * _channels * bytesPerSample;
    final byteData = ByteData(_wavHeaderSize + dataSize);

    _writeAscii(byteData, 0, 'RIFF');
    byteData.setUint32(4, 36 + dataSize, Endian.little);
    _writeAscii(byteData, 8, 'WAVE');
    _writeAscii(byteData, 12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, _channels, Endian.little);
    byteData.setUint32(24, _sampleRate, Endian.little);
    byteData.setUint32(
      28,
      _sampleRate * _channels * bytesPerSample,
      Endian.little,
    );
    byteData.setUint16(32, _channels * bytesPerSample, Endian.little);
    byteData.setUint16(34, _bitsPerSample, Endian.little);
    _writeAscii(byteData, 36, 'data');
    byteData.setUint32(40, dataSize, Endian.little);

    final fadeSamples = math.min(
      sampleCount ~/ 2,
      (_sampleRate * 0.008).round(),
    );
    for (var index = 0; index < sampleCount; index++) {
      final seconds = index / _sampleRate;
      final fade = _fadeFactor(index, sampleCount, fadeSamples);
      final sample =
          math.sin(2 * math.pi * frequencyHz * seconds) * _amplitude * fade;
      final pcm = (sample * 32767).round().clamp(-32768, 32767);
      byteData.setInt16(
        _wavHeaderSize + index * bytesPerSample,
        pcm,
        Endian.little,
      );
    }

    return byteData.buffer.asUint8List();
  }

  static double _fadeFactor(int index, int sampleCount, int fadeSamples) {
    if (fadeSamples <= 0) {
      return 1;
    }
    if (index < fadeSamples) {
      return index / fadeSamples;
    }
    final samplesFromEnd = sampleCount - index - 1;
    if (samplesFromEnd < fadeSamples) {
      return samplesFromEnd / fadeSamples;
    }
    return 1;
  }

  static void _writeAscii(ByteData byteData, int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      byteData.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}
