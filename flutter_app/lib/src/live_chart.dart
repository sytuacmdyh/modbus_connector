import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'session_controller.dart';

class LiveChart extends StatelessWidget {
  const LiveChart({super.key, required this.samples, required this.address});
  final List<Sample> samples;
  final int address;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final low = samples.isEmpty
        ? 0.0
        : samples.map((s) => s.value).reduce(math.min);
    final high = samples.isEmpty
        ? 0.0
        : samples.map((s) => s.value).reduce(math.max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Text('Live trend · @$address'),
                const Spacer(),
                Text(
                  samples.isEmpty ? '—' : samples.last.value.toStringAsFixed(0),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: samples.isEmpty
                  ? const Center(child: Text('Select a row, then read or poll'))
                  : Semantics(
                      label: 'Register $address, minimum $low, maximum $high',
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _ChartPainter(
                            samples,
                            colors.primary,
                            colors.outlineVariant,
                            low,
                            high,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              samples.isEmpty
                  ? 'Up to 300 samples · 10 Hz'
                  : '${low.toStringAsFixed(0)} – ${high.toStringAsFixed(0)}  ·  '
                        '${samples.length} samples  ·  ${samples.last.time.difference(samples.first.time).inSeconds} s',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.samples, this.color, this.grid, this.low, this.high);
  final List<Sample> samples;
  final Color color;
  final Color grid;
  final double low;
  final double high;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = grid
          ..strokeWidth = 0.6,
      );
    }
    final pad = math.max((high - low) * 0.15, 1.0);
    final min = low - pad;
    final span = high - low + pad * 2;
    final duration = math.max(
      1,
      samples.last.time.difference(samples.first.time).inMilliseconds,
    );
    final line = Path();
    Offset? last;
    for (var i = 0; i < samples.length; i++) {
      final point = Offset(
        samples[i].time.difference(samples.first.time).inMilliseconds /
            duration *
            size.width,
        size.height * (1 - (samples[i].value - min) / span),
      );
      if (i == 0) {
        line.moveTo(point.dx, point.dy);
      } else {
        line.lineTo(point.dx, point.dy);
      }
      last = point;
    }
    if (last != null) {
      final fill = Path.from(line)
        ..lineTo(last.dx, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.20),
              color.withValues(alpha: 0.01),
            ],
          ).createShader(rect),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      canvas.drawCircle(last, 3, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
