import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/trial_record.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
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
          final devices = _devicesForStartScreen(
            controller: controller,
            wearablesProvider: wearablesProvider,
          );
          final canNavigateBack = controller.canNavigateBack;
          return PlatformScaffold(
            appBar: PlatformAppBar(
              title: PlatformText('Yoga Posture Tracker'),
              leading: canNavigateBack
                  ? PlatformIconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => unawaited(
                        controller.navigateBack(wearablesProvider),
                      ),
                    )
                  : null,
            ),
            body: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final offsetAnimation = Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: offsetAnimation,
                    child: child,
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey('${controller.phase.name}-${controller.pose.id}'),
                child: _buildBody(
                  context,
                  controller: controller,
                  wearablesProvider: wearablesProvider,
                  devices: devices,
                ),
              ),
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
          assignment: devices.ringAssignment,
          capabilityIssues: _sensorService.capabilityIssues(devices),
          isBusy: controller.isBusy,
          isLlmCheckRunning: controller.isLlmCheckRunning,
          llmCheckMessage: controller.llmConnectionCheck?.message,
          llmCheckSucceeded: controller.llmConnectionCheck?.isReachable,
          onCheckLlm: () => unawaited(controller.checkLlmConnection()),
          onLeftChanged: (ringId) =>
              controller.updateRingAssignment(leftRingId: ringId),
          onRightChanged: (ringId) =>
              controller.updateRingAssignment(rightRingId: ringId),
          onStart: () => unawaited(
            controller.startSession(
              wearablesProvider,
              ringAssignment: devices.ringAssignment,
            ),
          ),
        ),
      YogaSessionPhase.poseSelection => _PoseSelectionScreen(
          poses: controller.availablePoses,
          onPoseSelected: (pose) => _openPoseCalibrationRoute(
            context,
            controller: controller,
            wearablesProvider: wearablesProvider,
            pose: pose,
          ),
        ),
      YogaSessionPhase.calibrationInstructions => _CalibrationInstructionScreen(
          devices: controller.devices,
          pose: controller.pose,
          poseHeroTag: _poseHeroTag(controller.pose),
          warning: controller.calibrationWarning,
          onBeginCalibration: () =>
              unawaited(controller.beginCalibration(wearablesProvider)),
        ),
      YogaSessionPhase.calibrationPreparing => _ProgressScreen(
          title: 'Get ready',
          icon: Icons.hourglass_top_rounded,
          instruction:
              'Move into the neutral position: stand upright, head straight, arms next to your body with palms facing inward. Recording has not started yet.',
          remainingSeconds: controller.remainingSeconds,
          totalSeconds:
              YogaSessionController.calibrationPreparationDuration.inSeconds,
          onStop: () =>
              unawaited(controller.cancelActivePhase(wearablesProvider)),
        ),
      YogaSessionPhase.calibrating => _ProgressScreen(
          title: 'Calibrating',
          icon: Icons.center_focus_strong_rounded,
          instruction:
              'Hold completely still. The neutral baseline is being recorded.',
          remainingSeconds: controller.remainingSeconds,
          totalSeconds: YogaSessionController.calibrationDuration.inSeconds,
          onStop: () =>
              unawaited(controller.cancelActivePhase(wearablesProvider)),
        ),
      YogaSessionPhase.poseInstructions => _PoseInstructionScreen(
          pose: controller.pose,
          setupInstruction: controller.poseSetupInstruction,
          onBeginHold: () =>
              unawaited(controller.beginPoseHold(wearablesProvider)),
        ),
      YogaSessionPhase.posePreparing => _ProgressScreen(
          title: 'Move into ${controller.pose.name}',
          icon: Icons.sports_gymnastics_rounded,
          instruction:
              '${controller.poseSetupInstruction} This time is not scored.',
          remainingSeconds: controller.remainingSeconds,
          totalSeconds: YogaSessionController.posePreparationDuration.inSeconds,
          referencePose: controller.pose,
          onStop: () =>
              unawaited(controller.cancelActivePhase(wearablesProvider)),
        ),
      YogaSessionPhase.holdingPose => _ProgressScreen(
          title: controller.pose.name,
          icon: Icons.self_improvement_rounded,
          instruction: controller.pose.instruction,
          remainingSeconds: controller.remainingSeconds,
          totalSeconds: YogaSessionController.holdDuration.inSeconds,
          liveFeedback: controller.feedback,
          signalQuality: controller.latestSignalQuality,
          onStop: () =>
              unawaited(controller.cancelActivePhase(wearablesProvider)),
        ),
      YogaSessionPhase.evaluating => const _EvaluatingScreen(),
      YogaSessionPhase.result => _ResultScreen(
          summary: controller.holdSummary,
          feedback: controller.feedback,
          signalQuality: controller.latestSignalQuality,
          trialRecords: controller.trialRecords,
          onRestart: () =>
              unawaited(controller.restartSession(wearablesProvider)),
          onDone: () => unawaited(controller.stopSession(wearablesProvider)),
        ),
    };
  }

  YogaDeviceSet _devicesForStartScreen({
    required YogaSessionController controller,
    required WearablesProvider wearablesProvider,
  }) {
    final devices = _sensorService.resolveDevices(wearablesProvider);
    final assignment = _ringAssignmentForStartScreen(
      assignment: controller.ringAssignment,
      devices: devices,
    );
    return devices.copyWith(ringAssignment: assignment);
  }

  RingAssignment _ringAssignmentForStartScreen({
    required RingAssignment assignment,
    required YogaDeviceSet devices,
  }) {
    final ringIds = devices.rings.map((ring) => ring.deviceId).toSet();
    final leftRingId =
        ringIds.contains(assignment.leftRingId) ? assignment.leftRingId : null;
    final rightRingId = ringIds.contains(assignment.rightRingId)
        ? assignment.rightRingId
        : null;

    if (leftRingId != null || rightRingId != null) {
      return RingAssignment(
        leftRingId: leftRingId,
        rightRingId: rightRingId,
      );
    }

    return _sensorService.defaultRingAssignment(devices);
  }

  Future<void> _openPoseCalibrationRoute(
    BuildContext context, {
    required YogaSessionController controller,
    required WearablesProvider wearablesProvider,
    required YogaPose pose,
  }) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 360),
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (routeContext, animation, secondaryAnimation) {
          return ChangeNotifierProvider.value(
            value: controller,
            child: Consumer<YogaSessionController>(
              builder: (context, routeController, _) {
                return PlatformScaffold(
                  appBar: PlatformAppBar(
                    title: PlatformText('Yoga Posture Tracker'),
                    leading: PlatformIconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  body: _CalibrationInstructionScreen(
                    devices: routeController.devices,
                    pose: pose,
                    poseHeroTag: _poseHeroTag(pose),
                    warning: routeController.calibrationWarning,
                    onBeginCalibration: () {
                      routeController.selectPose(pose);
                      Navigator.of(context).pop();
                      unawaited(
                        routeController.beginCalibration(wearablesProvider),
                      );
                    },
                  ),
                );
              },
            ),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _StartScreen extends StatelessWidget {
  final YogaDeviceSet devices;
  final RingAssignment assignment;
  final List<String> capabilityIssues;
  final bool isBusy;
  final bool isLlmCheckRunning;
  final String? llmCheckMessage;
  final bool? llmCheckSucceeded;
  final VoidCallback onCheckLlm;
  final ValueChanged<String?> onLeftChanged;
  final ValueChanged<String?> onRightChanged;
  final VoidCallback onStart;

  const _StartScreen({
    required this.devices,
    required this.assignment,
    required this.capabilityIssues,
    required this.isBusy,
    required this.isLlmCheckRunning,
    required this.llmCheckMessage,
    required this.llmCheckSucceeded,
    required this.onCheckLlm,
    required this.onLeftChanged,
    required this.onRightChanged,
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
              'Choose a pose, calibrate your neutral stance, and receive calm feedback from OpenEarable and ring IMU data.',
          icon: Icons.self_improvement_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _DeviceStatusCard(
          devices: devices,
          capabilityIssues: capabilityIssues,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        if (devices.hasTwoRings) ...[
          _InfoCard(
            title: 'Ring assignment',
            icon: Icons.compare_arrows_rounded,
            child: Column(
              children: [
                _RingDropdown(
                  label: 'Left hand',
                  selectedRingId: assignment.leftRingId,
                  rings: devices.rings,
                  otherAssignedRingId: assignment.rightRingId,
                  onChanged: onLeftChanged,
                ),
                const SizedBox(height: 10),
                _RingDropdown(
                  label: 'Right hand',
                  selectedRingId: assignment.rightRingId,
                  rings: devices.rings,
                  otherAssignedRingId: assignment.leftRingId,
                  onChanged: onRightChanged,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'LLM and audio check',
          icon: Icons.record_voice_over_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send a short request to the LLM and play its response through text-to-speech.',
              ),
              if (llmCheckMessage != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      llmCheckSucceeded == true
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: llmCheckSucceeded == true
                          ? const Color(0xFF2E7D32)
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(llmCheckMessage!)),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: isLlmCheckRunning ? null : onCheckLlm,
                icon: isLlmCheckRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_sync_rounded, size: 18),
                label: Text(
                  isLlmCheckRunning ? 'Checking...' : 'Check LLM connection',
                ),
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
              onPressed: isBusy ||
                      !devices.hasEarable ||
                      !devices.hasTwoRings ||
                      !assignment.isValid ||
                      capabilityIssues.isNotEmpty
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

class _PoseSelectionScreen extends StatelessWidget {
  final List<YogaPose> poses;
  final ValueChanged<YogaPose> onPoseSelected;

  const _PoseSelectionScreen({
    required this.poses,
    required this.onPoseSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: 'Choose your pose',
          subtitle:
              'Choose one of four poses. The app checks head posture, arm and hand position, and stability using calibrated IMU data.',
          icon: Icons.spa_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: poses.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemBuilder: (context, index) {
            final pose = poses[index];
            return _PoseGridCard(
              pose: pose,
              onTap: () => onPoseSelected(pose),
            );
          },
        ),
      ],
    );
  }
}

class _PoseGridCard extends StatelessWidget {
  final YogaPose pose;
  final VoidCallback onTap;

  const _PoseGridCard({
    required this.pose,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Hero(
                  tag: _poseHeroTag(pose),
                  child: _PoseImage(
                    pose: pose,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pose.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 6),
                  _PoseDifficultyPill(difficulty: pose.difficulty),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoseDifficultyPill extends StatelessWidget {
  final YogaPoseDifficulty difficulty;

  const _PoseDifficultyPill({
    required this.difficulty,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DifficultyDots(difficulty: difficulty),
            const SizedBox(width: 6),
            Text(
              difficulty.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSecondaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DifficultyDots extends StatelessWidget {
  final YogaPoseDifficulty difficulty;

  const _DifficultyDots({
    required this.difficulty,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = Theme.of(context).colorScheme.onSecondaryContainer;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < YogaPoseDifficulty.values.length; index++)
          Padding(
            padding: EdgeInsets.only(
              right: index == YogaPoseDifficulty.values.length - 1 ? 0 : 2,
            ),
            child: Icon(
              Icons.circle,
              size: 5,
              color: index < difficulty.indicatorCount
                  ? activeColor
                  : activeColor.withValues(alpha: 0.26),
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
  final String? otherAssignedRingId;
  final ValueChanged<String?> onChanged;

  const _RingDropdown({
    required this.label,
    required this.selectedRingId,
    required this.rings,
    required this.otherAssignedRingId,
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
            child: Text(
              ring.deviceId == otherAssignedRingId
                  ? '${formatWearableDisplayName(ring.name)} (swap)'
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
  final YogaPose pose;
  final String poseHeroTag;
  final String? warning;
  final VoidCallback onBeginCalibration;

  const _CalibrationInstructionScreen({
    required this.devices,
    required this.pose,
    required this.poseHeroTag,
    required this.warning,
    required this.onBeginCalibration,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: 'Calibrate for ${pose.name}',
          subtitle:
              'Stand upright, keep your head straight, place your arms next to your body with palms facing inward.',
          icon: Icons.accessibility_new_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _SelectedPosePreviewCard(
          pose: pose,
          heroTag: poseHeroTag,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        const _ReferenceImageCard(
          assetPath: yogaCalibrationPoseAsset,
          semanticLabel: yogaCalibrationPoseSemanticLabel,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        if (warning != null) ...[
          _CalibrationWarningCard(message: warning!),
          const SizedBox(height: SensorPageSpacing.sectionGap),
        ],
        _DeviceStatusCard(devices: devices),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'Why calibration matters',
          icon: Icons.tune_rounded,
          child: const Text(
            'The app stores this neutral sensor window as the reference. Each pose is then evaluated as movement away from this baseline.',
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

class _SelectedPosePreviewCard extends StatelessWidget {
  final YogaPose pose;
  final String heroTag;

  const _SelectedPosePreviewCard({
    required this.pose,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(
              width: 104,
              child: AspectRatio(
                aspectRatio: 1,
                child: Hero(
                  tag: heroTag,
                  child: _PoseImage(pose: pose),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pose.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Selected pose',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
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

class _PoseImage extends StatelessWidget {
  final YogaPose pose;
  final BoxFit fit;

  const _PoseImage({
    required this.pose,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          pose.imageAsset,
          fit: fit,
          filterQuality: FilterQuality.high,
          semanticLabel: pose.name,
        ),
      ),
    );
  }
}

String _poseHeroTag(YogaPose pose) {
  return 'yoga-posture-tracker-pose-${pose.id}';
}

String _measurableChecksForPose(YogaPose pose) {
  return switch (pose.id) {
    'warrior_ii' =>
      'The app checks arm elevation, left-right hand height, palm rotation, head pitch/roll, and stability. Head turn, legs, and shoulders cannot be measured directly with the current sensors.',
    'triangle' =>
      'The app checks whether one arm reaches upward, the other reaches downward, head control, and stability. Trunk angle, leg stance, and gaze direction cannot be measured directly.',
    'chair' =>
      'The app checks whether both arms lift overhead, left-right symmetry, head posture, and stability. Knees, hips, and squat depth cannot be measured directly.',
    'cobra' =>
      'The app checks head lift as an accelerometer-based proxy, head centering, hand symmetry, and stability. Chest lift, shoulders, elbows, and backbend depth cannot be measured directly.',
    _ =>
      'The app checks the measurable parts of this pose: head posture, hand and arm orientation, left-right symmetry, and stability. Some full-body details such as knees, hips, and trunk alignment cannot be measured directly with the current sensors.',
  };
}

class _CalibrationWarningCard extends StatelessWidget {
  final String message;

  const _CalibrationWarningCard({
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.motion_photos_pause_rounded,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoseInstructionScreen extends StatelessWidget {
  final YogaPose pose;
  final String setupInstruction;
  final VoidCallback onBeginHold;

  const _PoseInstructionScreen({
    required this.pose,
    required this.setupInstruction,
    required this.onBeginHold,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: pose.name,
          subtitle: setupInstruction,
          icon: Icons.sports_gymnastics_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _ReferenceImageCard(
          assetPath: pose.imageAsset,
          semanticLabel: pose.name,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _InfoCard(
          title: 'What is checked',
          icon: Icons.fact_check_rounded,
          child: Text(_measurableChecksForPose(pose)),
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

class _ReferenceImageCard extends StatelessWidget {
  final String assetPath;
  final String semanticLabel;

  const _ReferenceImageCard({
    required this.assetPath,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 1.35,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Image.asset(
            assetPath,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }
}

class _ProgressScreen extends StatelessWidget {
  final String title;
  final IconData icon;
  final String instruction;
  final int remainingSeconds;
  final int totalSeconds;
  final YogaPose? referencePose;
  final YogaFeedback? liveFeedback;
  final SensorWindowQuality? signalQuality;
  final VoidCallback? onStop;

  const _ProgressScreen({
    required this.title,
    required this.icon,
    required this.instruction,
    required this.remainingSeconds,
    required this.totalSeconds,
    this.referencePose,
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
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
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                instruction,
                                textAlign: TextAlign.center,
                              ),
                              if (referencePose != null) ...[
                                const SizedBox(height: 16),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 360,
                                  ),
                                  child: AspectRatio(
                                    aspectRatio: 1.5,
                                    child: Image.asset(
                                      referencePose!.imageAsset,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                      semanticLabel: referencePose!.name,
                                    ),
                                  ),
                                ),
                              ],
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
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
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
                                _SignalQualityCard(
                                  signalQuality: signalQuality!,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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

    return _ExpandableInfoCard(
      title: 'Advanced sensor data',
      subtitle: signalQuality.hasIssues
          ? 'Some sensor streams need attention'
          : 'Sensor streams are active',
      icon: signalQuality.hasIssues
          ? Icons.signal_cellular_connected_no_internet_4_bar
          : Icons.sensors_rounded,
      iconColor: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    color: stream.isOk ? const Color(0xFF2E7D32) : colors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(stream.label)),
                  Text(
                    stream.statusLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: stream.isOk
                              ? const Color(0xFF2E7D32)
                              : colors.error,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            Text(
              'Debug: ${signalQuality.totalSampleCount} total samples',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExpandableInfoCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? iconColor;
  final Widget child;

  const _ExpandableInfoCard({
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: Icon(
          icon,
          color: iconColor ?? Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        subtitle: subtitle == null ? null : Text(subtitle!),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [child],
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
  final YogaHoldSummary? summary;
  final YogaFeedback? feedback;
  final SensorWindowQuality? signalQuality;
  final List<TrialRecord> trialRecords;
  final VoidCallback onRestart;
  final VoidCallback onDone;

  const _ResultScreen({
    required this.summary,
    required this.feedback,
    required this.signalQuality,
    required this.trialRecords,
    required this.onRestart,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: SensorPageSpacing.pagePaddingWithBottomInset(context),
      children: [
        _HeroCard(
          title: switch (summary) {
            null => 'Session complete',
            final s when !s.isValid => 'Trial invalid',
            final s => 'Score ${s.evaluation!.score}',
          },
          subtitle: feedback?.recommendation ?? 'No feedback generated.',
          icon: Icons.insights_rounded,
        ),
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _ResultDetails(
          summary: summary,
          signalQuality: signalQuality,
          trialRecords: trialRecords,
        ),
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
}

class _ResultDetails extends StatelessWidget {
  final YogaHoldSummary? summary;
  final SensorWindowQuality? signalQuality;
  final List<TrialRecord> trialRecords;

  const _ResultDetails({
    required this.summary,
    required this.signalQuality,
    required this.trialRecords,
  });

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    final result = summary?.evaluation;
    final groupedErrors =
        result == null ? null : _GroupedPostureErrors.from(result.errors);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary != null) ...[
          _InfoCard(
            title: 'Trial validity',
            icon: summary.isValid
                ? Icons.verified_rounded
                : Icons.report_problem_outlined,
            child: Text(
              summary.isValid
                  ? '${summary.validWindowCount} of ${summary.windowCount} scoring windows were valid. Final score: ${result!.score}.'
                  : 'Only ${summary.validWindowCount} of ${summary.windowCount} scoring windows were valid, so no score was computed. ${summary.invalidReason ?? ''}',
            ),
          ),
          const SizedBox(height: SensorPageSpacing.sectionGap),
        ],
        if (signalQuality != null) ...[
          _SignalQualityCard(signalQuality: signalQuality!),
          const SizedBox(height: SensorPageSpacing.sectionGap),
        ],
        if (result == null || result.errors.isEmpty)
          _InfoCard(
            title: 'Detected issues',
            icon: Icons.report_problem_outlined,
            child: Text(
              result == null
                  ? 'No scored windows are available for this trial.'
                  : 'No posture issues detected.',
            ),
          )
        else ...[
          _IssueGroupCard(
            title: 'Left arm issue(s)',
            errors: groupedErrors!.leftArm,
          ),
          const SizedBox(height: 8),
          _IssueGroupCard(
            title: 'Right arm issue(s)',
            errors: groupedErrors.rightArm,
          ),
          if (groupedErrors.bothArmsAndHands.isNotEmpty) ...[
            const SizedBox(height: 8),
            _IssueGroupCard(
              title: 'Both arms / hands issue(s)',
              errors: groupedErrors.bothArmsAndHands,
            ),
          ],
          const SizedBox(height: 8),
          _IssueGroupCard(
            title: 'Head issue(s)',
            errors: groupedErrors.head,
          ),
          if (groupedErrors.other.isNotEmpty) ...[
            const SizedBox(height: 8),
            _IssueGroupCard(
              title: 'Other issue(s)',
              errors: groupedErrors.other,
            ),
          ],
        ],
        const SizedBox(height: SensorPageSpacing.sectionGap),
        _TrialExportCard(trialRecords: trialRecords),
      ],
    );
  }
}

class _TrialExportCard extends StatelessWidget {
  final List<TrialRecord> trialRecords;

  const _TrialExportCard({
    required this.trialRecords,
  });

  Future<void> _shareExport(String content, String fileName) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsString(content);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Yoga Posture Tracker session export',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return _InfoCard(
      title: 'Session data export',
      icon: Icons.file_download_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${trialRecords.length} completed or cancelled hold(s) in this session.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: trialRecords.isEmpty
                    ? null
                    : () => unawaited(
                          _shareExport(
                            '[${trialRecords.map((record) => record.toJsonString()).join(',\n')}]',
                            'yoga_trials_$timestamp.json',
                          ),
                        ),
                child: const Text('Export JSON'),
              ),
              OutlinedButton(
                onPressed: trialRecords.isEmpty
                    ? null
                    : () => unawaited(
                          _shareExport(
                            TrialRecord.toCsv(trialRecords),
                            'yoga_trials_$timestamp.csv',
                          ),
                        ),
                child: const Text('Export CSV'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupedPostureErrors {
  final List<PostureError> leftArm;
  final List<PostureError> rightArm;
  final List<PostureError> bothArmsAndHands;
  final List<PostureError> head;
  final List<PostureError> other;

  const _GroupedPostureErrors({
    required this.leftArm,
    required this.rightArm,
    required this.bothArmsAndHands,
    required this.head,
    required this.other,
  });

  factory _GroupedPostureErrors.from(List<PostureError> errors) {
    final leftArm = <PostureError>[];
    final rightArm = <PostureError>[];
    final bothArmsAndHands = <PostureError>[];
    final head = <PostureError>[];
    final other = <PostureError>[];

    for (final error in errors) {
      final area = _PostureIssueArea.fromCode(error.code);
      switch (area) {
        case _PostureIssueArea.leftArm:
          leftArm.add(error);
        case _PostureIssueArea.rightArm:
          rightArm.add(error);
        case _PostureIssueArea.bothArmsAndHands:
          bothArmsAndHands.add(error);
        case _PostureIssueArea.head:
          head.add(error);
        case _PostureIssueArea.other:
          other.add(error);
      }
    }

    return _GroupedPostureErrors(
      leftArm: leftArm,
      rightArm: rightArm,
      bothArmsAndHands: bothArmsAndHands,
      head: head,
      other: other,
    );
  }
}

enum _PostureIssueArea {
  leftArm,
  rightArm,
  bothArmsAndHands,
  head,
  other;

  static _PostureIssueArea fromCode(String code) {
    if (code.startsWith('left_') || code.contains('_left_')) {
      return _PostureIssueArea.leftArm;
    }
    if (code.startsWith('right_') || code.contains('_right_')) {
      return _PostureIssueArea.rightArm;
    }
    if (code.contains('head')) {
      return _PostureIssueArea.head;
    }
    if (code.contains('arm') ||
        code.contains('hand') ||
        code.contains('palm') ||
        code.contains('ring')) {
      return _PostureIssueArea.bothArmsAndHands;
    }
    // Pose-level codes such as '*_unstable' and 'no_sensor_data' land here
    // consistently for all poses.
    return _PostureIssueArea.other;
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
                    trailing: error.evaluatedWindowCount == null
                        ? null
                        : Text(
                            '${error.occurrenceCount}/${error.evaluatedWindowCount} windows',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                  ),
              ],
            ),
    );
  }
}

class _DeviceStatusCard extends StatelessWidget {
  final YogaDeviceSet devices;
  final List<String> capabilityIssues;

  const _DeviceStatusCard({
    required this.devices,
    this.capabilityIssues = const [],
  });

  @override
  Widget build(BuildContext context) {
    final hasRequiredDevices =
        devices.hasEarable && devices.hasTwoRings && capabilityIssues.isEmpty;
    final statusColor = hasRequiredDevices
        ? const Color(0xFF2E7D32)
        : Theme.of(context).colorScheme.error;
    return _ExpandableInfoCard(
      title: 'Connected devices',
      subtitle: hasRequiredDevices ? 'Setup detected' : 'Setup incomplete',
      icon: Icons.sensors_rounded,
      iconColor: statusColor,
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
          for (final issue in capabilityIssues)
            _DeviceStatusRow(
              label: 'Capability',
              value: issue,
              isOk: false,
            ),
          const SizedBox(height: 8),
          Text(
            hasRequiredDevices
                ? 'Required setup detected. Assign the left and right rings before calibration.'
                : 'Please connect one OpenEarable and two rings with accelerometer and gyroscope to start the Yoga Posture Tracker.',
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
