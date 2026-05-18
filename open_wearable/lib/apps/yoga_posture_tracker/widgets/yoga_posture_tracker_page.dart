import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/services/yoga_sensor_service.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/view_model/yoga_session_controller.dart';
import 'package:open_wearable/models/device_name_formatter.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';
import 'package:open_wearable/widgets/sensors/sensor_page_spacing.dart';
import 'package:provider/provider.dart';

class YogaPostureTrackerPage extends StatefulWidget {
  const YogaPostureTrackerPage({super.key});

  @override
  State<YogaPostureTrackerPage> createState() => _YogaPostureTrackerPageState();
}

class _YogaPostureTrackerPageState extends State<YogaPostureTrackerPage> {
  late final YogaSessionController _controller;
  final YogaSensorService _sensorService = YogaSensorService();
  WearablesProvider? _wearablesProvider;

  @override
  void initState() {
    super.initState();
    _controller = YogaSessionController(sensorService: _sensorService);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wearablesProvider ??= context.read<WearablesProvider>();
  }

  @override
  void dispose() {
    final wearablesProvider = _wearablesProvider;
    if (wearablesProvider != null) {
      unawaited(_controller.shutdown(wearablesProvider));
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: Consumer2<YogaSessionController, WearablesProvider>(
        builder: (context, controller, wearablesProvider, _) {
          final devices = _sensorService.resolveDevices(wearablesProvider);
          return PlatformScaffold(
            appBar: PlatformAppBar(
              title: PlatformText('Yoga Posture Tracker'),
            ),
            body: _buildBody(
              context,
              controller: controller,
              wearablesProvider: wearablesProvider,
              devices: devices,
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required YogaSessionController controller,
    required WearablesProvider wearablesProvider,
    required YogaDeviceSet devices,
  }) {
    return switch (controller.phase) {
      YogaSessionPhase.idle || YogaSessionPhase.checkingDevices => _StartScreen(
          devices: devices,
          isBusy: controller.isBusy,
          onStart: () => unawaited(controller.startSession(wearablesProvider)),
        ),
      YogaSessionPhase.assigningRings => _RingAssignmentScreen(
          devices: controller.devices,
          assignment: controller.ringAssignment,
          onLeftChanged: (ringId) =>
              controller.updateRingAssignment(leftRingId: ringId),
          onRightChanged: (ringId) =>
              controller.updateRingAssignment(rightRingId: ringId),
          onContinue: controller.confirmRingAssignment,
        ),
      YogaSessionPhase.calibrationInstructions => _CalibrationInstructionScreen(
          devices: controller.devices,
          onBeginCalibration: () =>
              unawaited(controller.beginCalibration(wearablesProvider)),
        ),
      YogaSessionPhase.calibrating => _ProgressScreen(
          title: 'Calibrating',
          icon: Icons.center_focus_strong_rounded,
          instruction:
              'Stand upright, keep your head straight, place your arms next to your body with palms facing inward.',
          remainingSeconds: controller.remainingSeconds,
          totalSeconds: YogaSessionController.calibrationDuration.inSeconds,
          onStop: () => unawaited(controller.stopSession(wearablesProvider)),
        ),
      YogaSessionPhase.poseInstructions => _PoseInstructionScreen(
          pose: controller.pose,
          onBeginHold: () =>
              unawaited(controller.beginPoseHold(wearablesProvider)),
        ),
      YogaSessionPhase.holdingPose => _ProgressScreen(
          title: controller.pose.name,
          icon: Icons.self_improvement_rounded,
          instruction: controller.pose.instruction,
          remainingSeconds: controller.remainingSeconds,
          totalSeconds: YogaSessionController.holdDuration.inSeconds,
          liveFeedback: controller.feedback,
          signalQuality: controller.latestSignalQuality,
          onStop: () => unawaited(controller.stopSession(wearablesProvider)),
        ),
      YogaSessionPhase.evaluating ||
      YogaSessionPhase.feedback =>
        const _EvaluatingScreen(),
      YogaSessionPhase.result => _ResultScreen(
          result: controller.evaluationResult,
          feedback: controller.feedback,
          signalQuality: controller.latestSignalQuality,
          onRestart: () =>
              unawaited(controller.restartSession(wearablesProvider)),
          onDone: () => unawaited(controller.stopSession(wearablesProvider)),
        ),
    };
  }
}

class _StartScreen extends StatelessWidget {
  final YogaDeviceSet devices;
  final bool isBusy;
  final VoidCallback onStart;

  const _StartScreen({
    required this.devices,
    required this.isBusy,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: 'Yoga Posture Tracker',
          subtitle:
              'A first MVP for evaluating Warrior II with OpenEarable and ring IMU data.',
          icon: Icons.self_improvement_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _DeviceStatusCard(devices: devices),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'MVP flow',
          icon: Icons.route_rounded,
          child: const Text(
            'The session calibrates a neutral standing posture, then asks you to hold Warrior II for 30 seconds. A rule-based evaluator checks short windows during the hold and can generate live coaching feedback.',
          ),
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        SafeArea(
          top: false,
          child: SizedBox(
            width: double.infinity,
            child: PlatformElevatedButton(
              onPressed: isBusy || !devices.hasEarable || !devices.hasTwoRings
                  ? null
                  : onStart,
              child: PlatformText(isBusy ? 'Preparing...' : 'Start session'),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingAssignmentScreen extends StatelessWidget {
  final YogaDeviceSet devices;
  final RingAssignment assignment;
  final ValueChanged<String?> onLeftChanged;
  final ValueChanged<String?> onRightChanged;
  final VoidCallback onContinue;

  const _RingAssignmentScreen({
    required this.devices,
    required this.assignment,
    required this.onLeftChanged,
    required this.onRightChanged,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: 'Assign rings',
          subtitle:
              'Wear the ring labeled L on your left hand and the ring labeled R on your right hand. Then assign both rings below.',
          icon: Icons.back_hand_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'Ring assignment',
          icon: Icons.compare_arrows_rounded,
          child: Column(
            children: [
              _RingDropdown(
                label: 'Left hand',
                selectedRingId: assignment.leftRingId,
                rings: devices.rings,
                blockedRingId: assignment.rightRingId,
                onChanged: onLeftChanged,
              ),
              const SizedBox(height: 10),
              _RingDropdown(
                label: 'Right hand',
                selectedRingId: assignment.rightRingId,
                rings: devices.rings,
                blockedRingId: assignment.leftRingId,
                onChanged: onRightChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        SafeArea(
          top: false,
          child: SizedBox(
            width: double.infinity,
            child: PlatformElevatedButton(
              onPressed: assignment.isValid ? onContinue : null,
              child: PlatformText('Continue to calibration'),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingDropdown extends StatelessWidget {
  final String label;
  final String? selectedRingId;
  final List<Wearable> rings;
  final String? blockedRingId;
  final ValueChanged<String?> onChanged;

  const _RingDropdown({
    required this.label,
    required this.selectedRingId,
    required this.rings,
    required this.blockedRingId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selectedStillAvailable =
        rings.any((ring) => ring.deviceId == selectedRingId);
    return DropdownButtonFormField<String>(
      initialValue: selectedStillAvailable ? selectedRingId : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final ring in rings)
          DropdownMenuItem<String>(
            value: ring.deviceId,
            enabled: ring.deviceId != blockedRingId,
            child: Text(
              ring.deviceId == blockedRingId
                  ? '${formatWearableDisplayName(ring.name)} (already assigned)'
                  : formatWearableDisplayName(ring.name),
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class _CalibrationInstructionScreen extends StatelessWidget {
  final YogaDeviceSet devices;
  final VoidCallback onBeginCalibration;

  const _CalibrationInstructionScreen({
    required this.devices,
    required this.onBeginCalibration,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: 'Calibration',
          subtitle:
              'Stand upright, keep your head straight, place your arms next to your body with palms facing inward.',
          icon: Icons.accessibility_new_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _DeviceStatusCard(devices: devices),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'Why calibration matters',
          icon: Icons.tune_rounded,
          child: const Text(
            'The MVP stores this neutral sensor window as the reference. Warrior II is then evaluated as movement away from this baseline.',
          ),
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        SafeArea(
          top: false,
          child: SizedBox(
            width: double.infinity,
            child: PlatformElevatedButton(
              onPressed: onBeginCalibration,
              child: PlatformText('Begin 3-second calibration'),
            ),
          ),
        ),
      ],
    );
  }
}

class _PoseInstructionScreen extends StatelessWidget {
  final YogaPose pose;
  final VoidCallback onBeginHold;

  const _PoseInstructionScreen({
    required this.pose,
    required this.onBeginHold,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: pose.name,
          subtitle: pose.instruction,
          icon: Icons.sports_gymnastics_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'What is checked',
          icon: Icons.fact_check_rounded,
          child: const Text(
            'The current MVP checks whether ring orientation changes enough from neutral, whether arm/head motion is stable, and whether the head remains near the calibrated neutral.',
          ),
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        SafeArea(
          top: false,
          child: SizedBox(
            width: double.infinity,
            child: PlatformElevatedButton(
              onPressed: onBeginHold,
              child: PlatformText('Start 30-second hold'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProgressScreen extends StatelessWidget {
  final String title;
  final IconData icon;
  final String instruction;
  final int remainingSeconds;
  final int totalSeconds;
  final YogaFeedback? liveFeedback;
  final SensorWindowQuality? signalQuality;
  final VoidCallback? onStop;

  const _ProgressScreen({
    required this.title,
    required this.icon,
    required this.instruction,
    required this.remainingSeconds,
    required this.totalSeconds,
    this.liveFeedback,
    this.signalQuality,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final progress = totalSeconds <= 0
        ? 0.0
        : (totalSeconds - remainingSeconds).clamp(0, totalSeconds) /
            totalSeconds;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 42, color: colors.primary),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        instruction,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: 130,
                        height: 130,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox.expand(
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 9,
                              ),
                            ),
                            Text(
                              '$remainingSeconds',
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                      if (liveFeedback != null) ...[
                        const SizedBox(height: 18),
                        _LiveFeedbackCard(feedback: liveFeedback!),
                      ],
                      if (signalQuality != null) ...[
                        const SizedBox(height: 12),
                        _SignalQualityCard(signalQuality: signalQuality!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (onStop != null)
            SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: PlatformTextButton(
                  onPressed: onStop,
                  child: PlatformText('Stop session'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveFeedbackCard extends StatelessWidget {
  final YogaFeedback feedback;

  const _LiveFeedbackCard({
    required this.feedback,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              feedback.generatedByLlm
                  ? Icons.auto_awesome_rounded
                  : Icons.record_voice_over_rounded,
              color: colors.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                feedback.recommendation,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalQualityCard extends StatelessWidget {
  final SensorWindowQuality signalQuality;

  const _SignalQualityCard({
    required this.signalQuality,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor =
        signalQuality.hasIssues ? colors.error : const Color(0xFF2E7D32);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  signalQuality.hasIssues
                      ? Icons.signal_cellular_connected_no_internet_4_bar
                      : Icons.sensors_rounded,
                  color: statusColor,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  signalQuality.hasIssues
                      ? 'Sensor data needs attention'
                      : 'Sensor data live',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final stream in signalQuality.streams)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      stream.isOk
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color:
                          stream.isOk ? const Color(0xFF2E7D32) : colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(stream.label)),
                    Text(
                      '${stream.sampleCount} samples',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EvaluatingScreen extends StatelessWidget {
  const _EvaluatingScreen();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlatformCircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Evaluating pose and preparing feedback...'),
        ],
      ),
    );
  }
}

class _ResultScreen extends StatelessWidget {
  final PoseEvaluationResult? result;
  final YogaFeedback? feedback;
  final SensorWindowQuality? signalQuality;
  final VoidCallback onRestart;
  final VoidCallback onDone;

  const _ResultScreen({
    required this.result,
    required this.feedback,
    required this.signalQuality,
    required this.onRestart,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final feedback = this.feedback;

    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: result == null ? 'Session complete' : 'Score ${result.score}',
          subtitle: feedback?.recommendation ?? 'No feedback generated.',
          icon: Icons.insights_rounded,
        ),
        if (signalQuality != null) ...[
          const SizedBox(height: SensorPageSpacing.sectionGap),
          _SignalQualityCard(signalQuality: signalQuality!),
        ],
        const SizedBox(height: SensorPageSpacing.sectionGap),
        if (result == null || result.errors.isEmpty)
          _InfoCard(
            title: 'Detected issues',
            icon: Icons.report_problem_outlined,
            child: const Text('No posture issues detected for this MVP run.'),
          )
        else ...[
          _IssueGroupCard(
            title: 'Left arm issue(s)',
            errors: _errorsForPrefix(result.errors, 'left_'),
          ),
          const SizedBox(height: 8),
          _IssueGroupCard(
            title: 'Right arm issue(s)',
            errors: _errorsForPrefix(result.errors, 'right_'),
          ),
          const SizedBox(height: 8),
          _IssueGroupCard(
            title: 'Head/posture issue(s)',
            errors: result.errors
                .where(
                  (error) =>
                      !error.code.startsWith('left_') &&
                      !error.code.startsWith('right_'),
                )
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: SensorPageSpacing.sectionGap),
        SafeArea(
          top: false,
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: PlatformElevatedButton(
                  onPressed: onRestart,
                  child: PlatformText('Restart session'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: PlatformTextButton(
                  onPressed: onDone,
                  child: PlatformText('Done'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<PostureError> _errorsForPrefix(
    List<PostureError> errors,
    String prefix,
  ) {
    return errors
        .where((error) => error.code.startsWith(prefix))
        .toList(growable: false);
  }
}

class _IssueGroupCard extends StatelessWidget {
  final String title;
  final List<PostureError> errors;

  const _IssueGroupCard({
    required this.title,
    required this.errors,
  });

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      title: title,
      icon: Icons.report_problem_outlined,
      child: errors.isEmpty
          ? const Text('No issue detected.')
          : Column(
              children: [
                for (final error in errors)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.priority_high_rounded),
                    title: Text(error.message),
                    subtitle: Text(
                      _formatErrorDetail(error),
                    ),
                  ),
              ],
            ),
    );
  }

  String _formatErrorDetail(PostureError error) {
    final windowCount = error.evaluatedWindowCount;
    final occurrence = windowCount == null
        ? ''
        : 'Detected in ${error.occurrenceCount}/$windowCount windows. ';
    return '${occurrence}Measured ${error.measuredValue.toStringAsFixed(1)} / threshold ${error.threshold.toStringAsFixed(1)}';
  }
}

class _DeviceStatusCard extends StatelessWidget {
  final YogaDeviceSet devices;

  const _DeviceStatusCard({
    required this.devices,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = devices.hasEarable && devices.hasTwoRings
        ? const Color(0xFF2E7D32)
        : Theme.of(context).colorScheme.error;
    return _InfoCard(
      title: 'Connected devices',
      icon: Icons.sensors_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DeviceStatusRow(
            label: 'OpenEarable',
            value: devices.earable == null
                ? 'Not connected'
                : formatWearableDisplayName(devices.earable!.name),
            isOk: devices.hasEarable,
          ),
          _DeviceStatusRow(
            label: 'Rings',
            value: devices.rings.isEmpty
                ? 'Not connected'
                : devices.rings
                    .map((ring) => formatWearableDisplayName(ring.name))
                    .join(', '),
            isOk: devices.rings.length >= 2,
          ),
          const SizedBox(height: 8),
          Text(
            devices.hasEarable && devices.hasTwoRings
                ? 'Required setup detected. Assign the left and right rings before calibration.'
                : 'Please connect one OpenEarable and two rings to start the Yoga Posture Tracker.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _DeviceStatusRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isOk;

  const _DeviceStatusRow({
    required this.label,
    required this.value,
    required this.isOk,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        isOk ? const Color(0xFF2E7D32) : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            isOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const _HeroCard({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 32, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _InfoCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
