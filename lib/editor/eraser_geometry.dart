class EraserGeometry {
  factory EraserGeometry({
    required double screenDiameter,
    required double canvasToScreenScale,
    required bool hitTestInScreenSpace,
    double screenBorderWidth = 1.5,
  }) {
    final diameter = screenDiameter.isFinite && screenDiameter > 0
        ? screenDiameter
        : 0.0;
    final scale = canvasToScreenScale.isFinite && canvasToScreenScale > 0
        ? canvasToScreenScale
        : 1.0;
    final borderWidth = screenBorderWidth.isFinite && screenBorderWidth > 0
        ? screenBorderWidth
        : 0.0;

    return EraserGeometry._(
      canvasDiameter: diameter / scale,
      canvasBorderWidth: borderWidth / scale,
      hitRadius: hitTestInScreenSpace ? diameter / 2 : diameter / (2 * scale),
      hitTestStrokeScale: hitTestInScreenSpace ? scale : 1.0,
    );
  }

  const EraserGeometry._({
    required this.canvasDiameter,
    required this.canvasBorderWidth,
    required this.hitRadius,
    required this.hitTestStrokeScale,
  });

  /// Diameter used by the painter before the page transform is applied.
  final double canvasDiameter;

  /// Border width used by the painter before the page transform is applied.
  final double canvasBorderWidth;

  /// Radius expressed in the coordinate system used by eraser hit testing.
  final double hitRadius;

  /// Converts stored document stroke widths into hit-test coordinates.
  final double hitTestStrokeScale;
}
