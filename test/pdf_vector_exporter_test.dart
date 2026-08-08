import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/pdf_vector_exporter.dart';
import 'package:ink_note/models.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PdfPageCoordinateMapper', () {
    const cropBox = pdf.PdfRect(10, 20, 210, 320);

    test('maps displayed page corners for every PDF rotation', () {
      final expected = <int, List<(double, double)>>{
        0: [(10, 320), (210, 20)],
        90: [(10, 20), (210, 320)],
        180: [(210, 20), (10, 320)],
        270: [(210, 320), (10, 20)],
      };

      for (final entry in expected.entries) {
        final mapper = PdfPageCoordinateMapper(
          cropBox: cropBox,
          rotation: entry.key,
        );
        _expectPoint(mapper.fromNormalized(0, 0), entry.value.first);
        _expectPoint(mapper.fromNormalized(1, 1), entry.value.last);
        _expectPoint(mapper.fromNormalized(.5, .5), (110, 170));
      }
    });

    test('swaps displayed dimensions on quarter turns', () {
      final upright = PdfPageCoordinateMapper(cropBox: cropBox, rotation: 0);
      final quarterTurn = PdfPageCoordinateMapper(
        cropBox: cropBox,
        rotation: 90,
      );

      expect(upright.displayWidth, 200);
      expect(upright.displayHeight, 300);
      expect(quarterTurn.displayWidth, 300);
      expect(quarterTurn.displayHeight, 200);
    });
  });

  group('PdfVectorExporter', () {
    test('keeps an unchanged PDF byte-for-byte when there are no objects', () {
      final source = pdf.PdfBlankDocument.create(
        pageSize: const pdf.PdfPageSize(600, 800),
      );

      final exported = PdfVectorExporter.export(
        sourcePdf: source,
        pages: const <List<InkObject>>[<InkObject>[]],
      );

      expect(exported, orderedEquals(source));
    });

    test('writes handwriting as printable vector Ink annotations', () {
      final source = pdf.PdfBlankDocument.create(
        pageSize: const pdf.PdfPageSize(600, 800),
        pageCount: 2,
      );
      final objects = <InkObject>[
        InkStroke(
          tool: InkTool.pen,
          color: const Color(0xFF17233C),
          width: 3,
          points: const [
            InkPoint(.1, .2, .25),
            InkPoint(.3, .35, .6),
            InkPoint(.5, .25, .9),
          ],
        ),
        InkStroke(
          tool: InkTool.brushPen,
          color: const Color(0xFF8E24AA),
          width: 7,
          points: const [
            InkPoint(.15, .55, .1),
            InkPoint(.3, .5, .35),
            InkPoint(.45, .6, .75),
            InkPoint(.6, .52, 1),
          ],
        ),
        InkStroke(
          tool: InkTool.highlighter,
          color: const Color(0xFFFFFF00),
          width: 16,
          points: const [InkPoint(.1, .72, .5), InkPoint(.72, .72, .5)],
        ),
        InkStroke(
          tool: InkTool.shape,
          color: const Color(0xFF1877F2),
          width: 2,
          dashed: true,
          points: const [InkPoint(.1, .82, .5), InkPoint(.9, .82, .5)],
        ),
        InkText(
          text: 'Vector note',
          x: .12,
          y: .08,
          width: .35,
          color: const Color(0xFF111111),
          fontSize: 22,
          bold: true,
        ),
      ];

      final exported = PdfVectorExporter.export(
        sourcePdf: source,
        pages: <List<InkObject>>[objects, <InkObject>[]],
      );
      final document = pdf.PdfDocument.open(exported);
      final annotations = document.page(0).annotations;

      expect(document.pageCount, 2);
      expect(document.page(1).annotations, isEmpty);
      expect(
        annotations.map((annotation) => annotation.subtype),
        orderedEquals(<String>['Ink', 'Ink', 'Ink', 'Ink', 'FreeText']),
      );
      expect(annotations.first.contents, 'Ink Note highlighter');
      expect(annotations.every((annotation) => annotation.isPrint), isTrue);

      final pen = annotations.singleWhere(
        (annotation) => annotation.contents == 'Ink Note pen',
      );
      final penPoints = pen.inkList!.single;
      _expectPoint(penPoints.first, (60, 640));
      _expectPoint(penPoints.last, (300, 600));
      final penAppearance = latin1.decode(
        document.cos.decodeStreamData(pen.normalAppearance!),
      );
      expect(penAppearance, contains(' c\n'));
      expect(penAppearance, isNot(contains(' Do')));

      final brush = annotations.singleWhere(
        (annotation) => annotation.contents == 'Ink Note brushPen',
      );
      final brushAppearance = latin1.decode(
        document.cos.decodeStreamData(brush.normalAppearance!),
      );
      final brushWidths = RegExp(
        r'([0-9.]+) w',
      ).allMatches(brushAppearance).map((match) => match.group(1)).toSet();
      expect(brushWidths.length, greaterThan(1));
      expect(brushAppearance, isNot(contains(' Do')));

      final highlighter = annotations.singleWhere(
        (annotation) => annotation.contents == 'Ink Note highlighter',
      );
      expect(highlighter.appearanceOpacity, closeTo(.28, .001));

      final dashedShape = annotations.singleWhere(
        (annotation) => annotation.contents == 'Ink Note shape',
      );
      expect(dashedShape.inkList!.length, greaterThan(2));
      expect(dashedShape.inkList!.every((dash) => dash.length == 2), isTrue);

      final freeText = annotations.singleWhere(
        (annotation) => annotation.subtype == 'FreeText',
      );
      expect(freeText.contents, 'Vector note');
      expect(freeText.normalAppearance, isNotNull);
    });

    test('embeds an inserted image as a printable PDF image stamp', () {
      const imagePath = 'inserted.png';
      final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lE'
        'QVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      );
      final source = pdf.PdfBlankDocument.create(
        pageSize: const pdf.PdfPageSize(600, 800),
      );

      final exported = PdfVectorExporter.export(
        sourcePdf: source,
        pages: <List<InkObject>>[
          <InkObject>[
            InkImage(
              path: imagePath,
              x: .2,
              y: .25,
              width: .4,
              height: .3,
            ),
          ],
        ],
        imageBytesByPath: <String, Uint8List>{imagePath: imageBytes},
      );
      final document = pdf.PdfDocument.open(exported);
      final stamp = document.page(0).annotations.single;

      expect(stamp.subtype, 'Stamp');
      expect(stamp.isImageStamp, isTrue);
      expect(stamp.isPrint, isTrue);
      expect(stamp.rect.left, closeTo(120, .001));
      expect(stamp.rect.bottom, closeTo(360, .001));
      expect(stamp.rect.right, closeTo(360, .001));
      expect(stamp.rect.top, closeTo(600, .001));
    });
  });
}

void _expectPoint((double, double) actual, (double, double) expected) {
  expect(actual.$1, closeTo(expected.$1, .0001));
  expect(actual.$2, closeTo(expected.$2, .0001));
}
