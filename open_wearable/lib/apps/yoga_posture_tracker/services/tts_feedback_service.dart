import 'package:open_wearable/models/logger.dart';

abstract class TtsFeedbackService {
  Future<void> speak(String text);
}

class LoggingTtsFeedbackService implements TtsFeedbackService {
  const LoggingTtsFeedbackService();

  @override
  Future<void> speak(String text) async {
    // TODO: Integrate platform TTS when the app adopts a TTS dependency or
    // exposes a shared spoken-feedback service. The MVP keeps this optional so
    // it works without API keys or additional packages.
    logger.i('Yoga TTS feedback: $text');
  }
}
