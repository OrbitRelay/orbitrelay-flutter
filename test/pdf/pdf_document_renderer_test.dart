import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/asset/asset_downloader.dart';
import 'package:orbitrelay_client_flutter/pdf/pdf_document_renderer.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';

import 'pdfrx_test_initializer.dart';

const _fixture = 'test/fixtures/alignment_rotations.pdf';
final _assetId = AssetId.parse('11111111-1111-4111-8111-111111111111');

PdfrxPdfDocumentRenderer _renderer({
  int maxRenderPixels = defaultMaxRenderPixels,
}) => PdfrxPdfDocumentRenderer(
  maxRenderPixels: maxRenderPixels,
  initialize: initializePdfrxForTest,
);

Future<DownloadedAsset> _fixtureAsset() async {
  final data = await rootBundle.load(_fixture);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return DownloadedAsset(
    assetId: _assetId,
    bytes: bytes,
    contentHash: sha256.convert(bytes).toString(),
    mediaType: 'application/pdf',
  );
}

Matcher _rendererFailure(PdfRendererFailure expected) =>
    isA<PdfRendererException>().having(
      (error) => error.failure,
      'failure',
      expected,
    );

final class _Rgb {
  const _Rgb(this.red, this.green, this.blue);

  final int red;
  final int green;
  final int blue;

  @override
  String toString() => 'rgb($red, $green, $blue)';
}

Future<_Rgb> _pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('Rendered image did not expose RGBA bytes');
  }
  final index = (y * image.width + x) * 4;
  return _Rgb(
    data.getUint8(index),
    data.getUint8(index + 1),
    data.getUint8(index + 2),
  );
}

bool _closeTo(_Rgb actual, _Rgb expected) =>
    (actual.red - expected.red).abs() < 45 &&
    (actual.green - expected.green).abs() < 45 &&
    (actual.blue - expected.blue).abs() < 45;

const _red = _Rgb(217, 38, 26);
const _green = _Rgb(26, 140, 64);
const _blue = _Rgb(26, 77, 217);
const _yellow = _Rgb(217, 166, 13);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opens real PDF bytes and exposes rotated page geometry', () async {
    final document = await _renderer().open(
      asset: await _fixtureAsset(),
      expectedPageCount: 4,
    );
    addTearDown(document.dispose);

    expect(document.pageCount, 4);
    expect(
      <(double, double, int)>[
        for (var index = 0; index < document.pageCount; index += 1)
          (
            document.pageInfo(index).width,
            document.pageInfo(index).height,
            document.pageInfo(index).rotationDegrees,
          ),
      ],
      <(double, double, int)>[
        (400, 600, 0),
        (600, 400, 90),
        (400, 600, 180),
        (600, 400, 270),
      ],
    );
  });

  test('renders 0/90/180/270 with PDF rotation applied exactly once', () async {
    final document = await _renderer().open(
      asset: await _fixtureAsset(),
      expectedPageCount: 4,
    );
    addTearDown(document.dispose);
    final expectations = <List<(int, int, _Rgb)>>[
      <(int, int, _Rgb)>[
        (25, 25, _blue),
        (345, 25, _yellow),
        (25, 565, _red),
        (345, 565, _green),
      ],
      <(int, int, _Rgb)>[
        (35, 25, _red),
        (575, 25, _blue),
        (35, 345, _green),
        (575, 345, _yellow),
      ],
      <(int, int, _Rgb)>[
        (55, 35, _green),
        (375, 35, _red),
        (55, 575, _yellow),
        (375, 575, _blue),
      ],
      <(int, int, _Rgb)>[
        (25, 55, _yellow),
        (565, 55, _green),
        (25, 375, _blue),
        (565, 375, _red),
      ],
    ];

    for (var index = 0; index < 4; index += 1) {
      final page = await document.renderPage(
        pageIndex: index,
        targetPixelSize: index.isEven
            ? const ui.Size(400, 600)
            : const ui.Size(600, 400),
      );
      expect(page.pixelWidth, index.isEven ? 400 : 600);
      expect(page.pixelHeight, index.isEven ? 600 : 400);
      for (final sample in expectations[index]) {
        final actual = await _pixel(page.image, sample.$1, sample.$2);
        expect(
          _closeTo(actual, sample.$3),
          isTrue,
          reason:
              'page $index sample (${sample.$1}, ${sample.$2}) '
              'was $actual, expected ${sample.$3}',
        );
      }
      page.dispose();
      expect(page.isDisposed, isTrue);
    }
  });

  test('rejects invalid bytes and page-count mismatches', () async {
    final invalid = DownloadedAsset(
      assetId: _assetId,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      contentHash: 'invalid',
      mediaType: 'application/pdf',
    );
    await expectLater(
      _renderer().open(asset: invalid, expectedPageCount: 1),
      throwsA(_rendererFailure(PdfRendererFailure.invalidDocument)),
    );
    await expectLater(
      _renderer().open(asset: await _fixtureAsset(), expectedPageCount: 3),
      throwsA(_rendererFailure(PdfRendererFailure.pageCountMismatch)),
    );
  });

  test('centralizes zero-based indexing, pixel cap, and disposal', () async {
    final document = await _renderer(
      maxRenderPixels: 10000,
    ).open(asset: await _fixtureAsset(), expectedPageCount: 4);
    expect(document.pageInfo(0).pageIndex, 0);
    expect(
      () => document.pageInfo(4),
      throwsA(_rendererFailure(PdfRendererFailure.pageOutOfRange)),
    );
    final page = await document.renderPage(
      pageIndex: 0,
      targetPixelSize: const ui.Size(4000, 6000),
    );
    expect(page.pixelWidth * page.pixelHeight, lessThanOrEqualTo(10000));
    page.dispose();
    await document.dispose();
    expect(document.isDisposed, isTrue);
    expect(
      () => document.pageInfo(0),
      throwsA(_rendererFailure(PdfRendererFailure.disposed)),
    );
  });
}
