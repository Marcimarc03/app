import 'package:flutter/material.dart';
import 'package:open_wearable/apps/yoga_posture_tracker/model/yoga_models.dart';

class PoseSilhouetteFeedbackView extends StatelessWidget {
  final YogaPose pose;
  final List<PoseMarkerFeedback> markers;
  final bool showLegend;

  const PoseSilhouetteFeedbackView({
    super.key,
    required this.pose,
    required this.markers,
    this.showLegend = false,
  });

  @override
  Widget build(BuildContext context) {
    final markerByType = {
      for (final marker in markers) marker.type: marker,
    };
    final markerSpecs = _markerSpecsForPose(pose);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1.35,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final imageRect = _containedImageRect(
                Size(constraints.maxWidth, constraints.maxHeight),
                _imageAspectRatioForPose(pose),
              );

              return Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        pose.imageAsset,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        semanticLabel: '${pose.name} live feedback',
                      ),
                    ),
                  ),
                  for (final spec in markerSpecs)
                    _PositionedPoseMarker(
                      spec: spec,
                      marker: markerByType[spec.type],
                      imageRect: imageRect,
                    ),
                ],
              );
            },
          ),
        ),
        if (showLegend) ...[
          const SizedBox(height: 10),
          const _PoseMarkerLegend(),
        ],
      ],
    );
  }
}

class _PositionedPoseMarker extends StatelessWidget {
  final _PoseMarkerSpec spec;
  final PoseMarkerFeedback? marker;
  final Rect imageRect;

  const _PositionedPoseMarker({
    required this.spec,
    required this.marker,
    required this.imageRect,
  });

  @override
  Widget build(BuildContext context) {
    const markerSize = 26.0;
    final marker = this.marker ??
        PoseMarkerFeedback(
          type: spec.type,
          status: PoseMarkerStatus.noData,
          message: 'Waiting for live data.',
        );

    return Positioned(
      left:
          imageRect.left + imageRect.width * spec.position.dx - markerSize / 2,
      top: imageRect.top + imageRect.height * spec.position.dy - markerSize / 2,
      child: Tooltip(
        message: marker.message ?? _markerTypeLabel(marker.type),
        child: _PoseMarker(
          status: marker.status,
          size: markerSize,
        ),
      ),
    );
  }
}

class _PoseMarker extends StatelessWidget {
  final PoseMarkerStatus status;
  final double size;

  const _PoseMarker({
    required this.status,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status, Theme.of(context).colorScheme);
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.24),
        border: Border.all(
          color: color,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 7,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(
          _statusIcon(status),
          color: color,
          size: size * 0.58,
        ),
      ),
    );
  }
}

class _PoseMarkerLegend extends StatelessWidget {
  const _PoseMarkerLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: const [
        _LegendItem(status: PoseMarkerStatus.good, label: 'In range'),
        _LegendItem(status: PoseMarkerStatus.warning, label: 'Close'),
        _LegendItem(status: PoseMarkerStatus.bad, label: 'Adjust'),
        _LegendItem(status: PoseMarkerStatus.noData, label: 'No data'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final PoseMarkerStatus status;
  final String label;

  const _LegendItem({
    required this.status,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PoseMarker(status: status, size: 16),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _PoseMarkerSpec {
  final PoseMarkerType type;
  final Offset position;

  const _PoseMarkerSpec({
    required this.type,
    required this.position,
  });
}

List<_PoseMarkerSpec> _markerSpecsForPose(YogaPose pose) {
  return switch (pose.id) {
    'warrior_ii' => const [
        _PoseMarkerSpec(
          type: PoseMarkerType.head,
          position: Offset(0.49, 0.19),
        ),
        _PoseMarkerSpec(
          type: PoseMarkerType.leftHand,
          position: Offset(0.055, 0.286),
        ),
        _PoseMarkerSpec(
          type: PoseMarkerType.rightHand,
          position: Offset(0.945, 0.294),
        ),
      ],
    _ => const [
        _PoseMarkerSpec(
          type: PoseMarkerType.head,
          position: Offset(0.50, 0.20),
        ),
        _PoseMarkerSpec(
          type: PoseMarkerType.leftHand,
          position: Offset(0.08, 0.32),
        ),
        _PoseMarkerSpec(
          type: PoseMarkerType.rightHand,
          position: Offset(0.92, 0.32),
        ),
      ],
  };
}

double _imageAspectRatioForPose(YogaPose pose) {
  return switch (pose.id) {
    'warrior_ii' => 1086 / 1448,
    _ => 1,
  };
}

Rect _containedImageRect(Size containerSize, double imageAspectRatio) {
  final containerAspectRatio = containerSize.width / containerSize.height;

  if (containerAspectRatio > imageAspectRatio) {
    final imageHeight = containerSize.height;
    final imageWidth = imageHeight * imageAspectRatio;
    return Rect.fromLTWH(
      (containerSize.width - imageWidth) / 2,
      0,
      imageWidth,
      imageHeight,
    );
  }

  final imageWidth = containerSize.width;
  final imageHeight = imageWidth / imageAspectRatio;
  return Rect.fromLTWH(
    0,
    (containerSize.height - imageHeight) / 2,
    imageWidth,
    imageHeight,
  );
}

Color _statusColor(PoseMarkerStatus status, ColorScheme colors) {
  return switch (status) {
    PoseMarkerStatus.good => const Color(0xFF2E7D32),
    PoseMarkerStatus.warning => const Color(0xFFF9A825),
    PoseMarkerStatus.bad => colors.error,
    PoseMarkerStatus.noData => colors.outline,
  };
}

IconData _statusIcon(PoseMarkerStatus status) {
  return switch (status) {
    PoseMarkerStatus.good => Icons.check_rounded,
    PoseMarkerStatus.warning => Icons.priority_high_rounded,
    PoseMarkerStatus.bad => Icons.close_rounded,
    PoseMarkerStatus.noData => Icons.circle_outlined,
  };
}

String _markerTypeLabel(PoseMarkerType type) {
  return switch (type) {
    PoseMarkerType.head => 'Head / OpenEarable',
    PoseMarkerType.leftHand => 'Left hand / OpenRing',
    PoseMarkerType.rightHand => 'Right hand / OpenRing',
  };
}
