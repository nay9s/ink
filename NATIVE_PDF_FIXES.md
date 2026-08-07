# Native PDF fixes

## iPad / iOS 16+

- PDF pages stay native through PDFKit.
- PencilKit is used as the input sampler while the Pencil is touching the page, but its bitmap-backed live ink is nearly transparent. A CAShapeLayer vector preview is drawn from the first pencil-down event and kept synchronized to the PDF zoom, so the visible stroke is sharp immediately; after lift it is replaced seamlessly by a vector PDF annotation.
- Finished pen strokes are converted to vector `PDFAnnotation` ink paths, so they remain sharp while zooming.
- Finished highlighter strokes are converted to PDF highlight annotations using quadrilateral points. This uses the PDF highlight rendering instead of leaving a translucent bitmap overlay over the text.
- App Undo and Redo buttons are connected to the native PDF annotation history.
- Erasing an Ink Note annotation is recorded in the same Undo/Redo history.
- Annotation changes are saved atomically into the imported `source.pdf` and are included when the PDF is shared.
- The iOS deployment target is now 16.0 because editable PDF page overlays require iOS/iPadOS 16 or newer.

## Android tablet

- The native editable PDF viewer is used only on Android 12+ with SDK Extension 18+.
- AndroidX draft edits are written back into the imported PDF through `PdfWriteHandle` when the document is saved or shared.
- Older unsupported Android versions show a clear compatibility message instead of trying to construct an unsupported editable fragment.
- AndroidX currently owns its native toolbox. App-level Undo/Redo and direct pen selection are not exposed by the alpha19 public API, so those actions remain in the Android native toolbox.

## Device test checklist

1. Import a multi-page PDF.
2. Zoom in, write with Apple Pencil, and confirm the stroke is already sharp while the Pencil is still touching the screen; then lift the Pencil and confirm the vector result stays sharp.
3. Highlight across black PDF text and confirm the text remains dark/readable.
4. Draw three strokes, Undo three times, then Redo three times.
5. Erase one stroke, Undo, and confirm it returns.
6. Move to another page and return.
7. Close and reopen the note.
8. Share the PDF and open the exported file in Apple Files or Preview.
9. On Android 12+ Extension 18+, annotate with the native toolbox, close/reopen, and export.


## Quality-first rendering (latest)

- Removed the upper cap on iOS PDF overlay/PencilKit backing scale.
- Overlay render scale now follows `UIScreen.scale * PDFView.scaleFactor` without a RAM-saving ceiling.
- PDF zoom changes force an immediate backing-scale refresh.
- Removed the 100-entry native PDF undo-history cap for now.
- This intentionally prioritizes visual sharpness over memory usage while the rendering path is being validated on iPad.
