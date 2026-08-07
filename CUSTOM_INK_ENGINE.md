# Ink Note Custom iPad Ink Engine

The native iPad PDF editor no longer uses `PKCanvasView`/PencilKit as its drawing surface.

## Input pipeline

1. `InkInputGestureRecognizer` receives Apple Pencil touches directly from UIKit.
2. Real input uses `UIEvent.coalescedTouches(for:)` for high-frequency samples.
3. `UIEvent.predictedTouches(for:)` is rendered as a temporary tip prediction to reduce apparent latency.
4. Each sample records position, pressure, altitude, azimuth, and timestamp.

## Live rendering

- `NativeInkOverlayView` is a transparent PDF page overlay.
- The live stroke is a `CAShapeLayer` vector path from pencil-down.
- The live path is never backed by a PencilKit canvas.
- Render scale follows `Retina scale × PDFView.scaleFactor` with no artificial upper cap in this quality-first build.
- Predicted points are replaced as real coalesced samples arrive.

## Commit / persistence

- Pen strokes are committed as vector `.ink` PDF annotations.
- Highlighter strokes are committed as semantic `.highlight` PDF annotations.
- The temporary live vector path is cleared immediately after the PDF annotation is added.
- Edited PDF data is autosaved and is also saved when Flutter requests Save/Export.

## Editing

- Undo/Redo uses a native annotation edit stack and is bridged to the Flutter toolbar.
- Eraser removes Ink Note annotations and records removals in the same Undo/Redo history.
- Finger scrolling remains available while Pencil-only drawing is enabled.
- `Draw with finger` can opt direct touches into the ink recognizer.

## Current scope

This custom engine is the iPad/iOS native-PDF drawing path. Android remains on the Android native PDF implementation for now so the iPad engine can be validated independently first.
