import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/stroke_writer.dart';
import 'package:orbitrelay_client_flutter/canvas/viewport_transform.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';

void main() {
  test('contain fit maps equal aspect ratios edge to edge', () {
    final transform = ViewportTransform(
      space: CanvasSpace(200, 100),
      viewportSize: const Size(800, 400),
    );
    expect(transform.offset, Offset.zero);
    expect(transform.canvasToViewport(CanvasPoint(0, 0)), Offset.zero);
    expect(
      transform.canvasToViewport(CanvasPoint(200, 100)),
      const Offset(800, 400),
    );
    expect(transform.containsViewportPoint(Offset.zero), isTrue);
    expect(transform.containsViewportPoint(const Offset(800, 400)), isTrue);
  });

  test('contain fit centers a landscape Canvas vertically', () {
    final transform = ViewportTransform(
      space: CanvasSpace(1920, 1080),
      viewportSize: const Size(900, 600),
    );
    expect(transform.scale, closeTo(900 / 1920, 0.00001));
    expect(transform.offset.dy, greaterThan(0));
    expect(transform.containsViewportPoint(const Offset(0, 0)), isFalse);
    final point = CanvasPoint(960, 540);
    final roundTrip = transform.viewportToCanvas(
      transform.canvasToViewport(point),
    );
    expect(roundTrip.x, closeTo(point.x, 0.00001));
    expect(roundTrip.y, closeTo(point.y, 0.00001));
  });

  test('contain fit centers a portrait Canvas horizontally', () {
    final transform = ViewportTransform(
      space: CanvasSpace(100, 200),
      viewportSize: const Size(600, 600),
    );
    expect(transform.scale, 3);
    expect(transform.offset, const Offset(150, 0));
    expect(transform.containsViewportPoint(const Offset(149.99, 300)), isFalse);
    expect(transform.containsViewportPoint(const Offset(150, 0)), isTrue);
    expect(transform.containsViewportPoint(const Offset(450, 600)), isTrue);
  });

  for (final testCase in <(int, Map<int, int>)>[
    (1, <int, int>{1: 1}),
    (255, <int, int>{1: 255}),
    (256, <int, int>{1: 256}),
    (257, <int, int>{1: 256, 2: 1}),
  ]) {
    test('StrokeWriter batches ${testCase.$1} points', () {
      final writer = StrokeWriter(strokeId: StrokeId.generate());
      for (var index = 0; index < testCase.$1; index += 1) {
        writer.addPoint(CanvasPoint(index.toDouble(), 1));
      }
      final chunks = <int, int>{};
      expect(
        writer.flush((index, points) {
          chunks[index] = points.length;
          return true;
        }),
        isTrue,
      );
      expect(chunks, testCase.$2);
      expect(writer.lastSubmittedChunkIndex, testCase.$2.length);
      expect(writer.pendingPoints, isEmpty);
    });
  }

  test('StrokeWriter does not advance after a rejected queue submission', () {
    final writer = StrokeWriter(strokeId: StrokeId.generate());
    writer.addPoint(CanvasPoint(1, 1));
    expect(writer.flush((_, _) => false), isFalse);
    expect(writer.nextChunkIndex, 1);
    expect(writer.pendingPoints, hasLength(1));
  });
}
