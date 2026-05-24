import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:open_wearable/models/logger.dart';

double _parseEnvironmentDouble(String value, double fallback) {
  return double.tryParse(value.trim()) ?? fallback;
}

abstract class TtsFeedbackService {
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> dispose();
}

class YogaTtsFeedbackServiceFactory {
  static const String _provider = String.fromEnvironment(
    'YOGA_TTS_PROVIDER',
    defaultValue: 'auto',
  );

  YogaTtsFeedbackServiceFactory._();

  static TtsFeedbackService fromEnvironment() {
    final provider = _provider.trim().toLowerCase();

    return switch (provider) {
      'auto' ||
      'native' ||
      'platform' ||
      'flutter_tts' =>
        FlutterTtsFeedbackService(),
      'logging' || 'off' || 'disabled' => const LoggingTtsFeedbackService(),
      _ => _serviceForUnknownProvider(provider),
    };
  }

  static TtsFeedbackService _serviceForUnknownProvider(String provider) {
    logger.w(
      'Unknown Yoga TTS provider "$provider". Using local platform TTS.',
    );
    return FlutterTtsFeedbackService();
  }
}

class FlutterTtsFeedbackService implements TtsFeedbackService {
  static const String _language = String.fromEnvironment(
    'YOGA_TTS_LANGUAGE',
    defaultValue: 'en-US',
  );
  static const String _voiceName = String.fromEnvironment(
    'YOGA_TTS_VOICE_NAME',
    defaultValue: '',
  );
  static const String _voiceLocale = String.fromEnvironment(
    'YOGA_TTS_VOICE_LOCALE',
    defaultValue: '',
  );
  static final double _speechRate = _parseEnvironmentDouble(
    const String.fromEnvironment(
      'YOGA_TTS_SPEECH_RATE',
      defaultValue: '0.45',
    ),
    0.45,
  );
  static final double _pitch = _parseEnvironmentDouble(
    const String.fromEnvironment(
      'YOGA_TTS_PITCH',
      defaultValue: '1',
    ),
    1,
  );
  static final double _volume = _parseEnvironmentDouble(
    const String.fromEnvironment(
      'YOGA_TTS_VOLUME',
      defaultValue: '1',
    ),
    1,
  );

  final FlutterTts _tts;
  final TtsFeedbackService fallback;
  Future<void>? _initializeFuture;
  Completer<void>? _activeSpeechCompleter;
  int _generation = 0;
  bool _isSpeechInProgress = false;
  bool _disposed = false;

  FlutterTtsFeedbackService({
    FlutterTts? tts,
    this.fallback = const LoggingTtsFeedbackService(),
  }) : _tts = tts ?? FlutterTts();

  @override
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _disposed) {
      return;
    }
    if (_isSpeechInProgress || _activeSpeechCompleter != null) {
      logger.i('Yoga TTS skipped because speech is still in progress.');
      return;
    }

    final generation = ++_generation;
    try {
      await _initialize();
      if (_disposed || generation != _generation) {
        return;
      }
      final speechCompleter = Completer<void>();
      _activeSpeechCompleter = speechCompleter;
      _isSpeechInProgress = true;
      final result = await _tts.speak(trimmed);
      if (result != 1) {
        _completeActiveSpeech();
        logger.w('Flutter TTS did not start playback. Result: $result');
        await fallback.speak(trimmed);
        return;
      }
      await speechCompleter.future.timeout(
        _speechTimeoutFor(trimmed),
        onTimeout: () {
          logger.w('Flutter TTS completion timed out.');
          _completeActiveSpeech();
        },
      );
    } catch (error, stackTrace) {
      _completeActiveSpeech();
      logger.w(
        'Flutter TTS playback failed.',
        error: error,
        stackTrace: stackTrace,
      );
      await fallback.speak(trimmed);
    }
  }

  @override
  Future<void> stop() async {
    _generation += 1;
    _completeActiveSpeech();
    await _stopPlatformTts();
    await fallback.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _completeActiveSpeech();
    await _stopPlatformTts();
    await fallback.dispose();
  }

  Future<void> _initialize() {
    final activeInitialization = _initializeFuture;
    if (activeInitialization != null) {
      return activeInitialization;
    }

    final initialization = _configureTts();
    _initializeFuture = initialization;
    return initialization.catchError((Object error, StackTrace stackTrace) {
      if (identical(_initializeFuture, initialization)) {
        _initializeFuture = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _configureTts() async {
    _tts.setStartHandler(() {
      _isSpeechInProgress = true;
      logger.i('Yoga TTS playback started.');
    });
    _tts.setCompletionHandler(() {
      _completeActiveSpeech();
      logger.i('Yoga TTS playback completed.');
    });
    _tts.setCancelHandler(() {
      _completeActiveSpeech();
      logger.i('Yoga TTS playback cancelled.');
    });
    _tts.setErrorHandler((message) {
      _completeActiveSpeech();
      logger.w('Yoga TTS playback error: $message');
    });

    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage(_language);
    await _tts.setSpeechRate(_speechRate.clamp(0.0, 1.0).toDouble());
    await _tts.setPitch(_pitch.clamp(0.5, 2.0).toDouble());
    await _tts.setVolume(_volume.clamp(0.0, 1.0).toDouble());

    final voice = <String, String>{
      if (_voiceName.trim().isNotEmpty) 'name': _voiceName.trim(),
      if (_voiceLocale.trim().isNotEmpty) 'locale': _voiceLocale.trim(),
    };
    if (voice.isNotEmpty) {
      await _tts.setVoice(voice);
    }
  }

  Future<void> _stopPlatformTts() async {
    try {
      await _tts.stop();
    } catch (error, stackTrace) {
      logger.w(
        'Flutter TTS stop failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _completeActiveSpeech() {
    _isSpeechInProgress = false;
    final completer = _activeSpeechCompleter;
    _activeSpeechCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Duration _speechTimeoutFor(String text) {
    final estimatedMilliseconds = 2500 + text.length * 90;
    return Duration(
      milliseconds: estimatedMilliseconds.clamp(4000, 15000).toInt(),
    );
  }
}

class LoggingTtsFeedbackService implements TtsFeedbackService {
  const LoggingTtsFeedbackService();

  @override
  Future<void> speak(String text) async {
    logger.i('Yoga TTS feedback: $text');
  }

  @override
  Future<void> stop() async {
    logger.i('Yoga TTS feedback stopped');
  }

  @override
  Future<void> dispose() async {}
}
